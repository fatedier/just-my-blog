---
categories:
    - "技术文章"
tags:
    - "kubernetes"
date: 2019-04-17
title: "kubernetes 自定义控制器的高可用"
url: "/2019/04/17/k8s-custom-controller-high-available"
---

自定义 controller 通常要求只能有一个实例在工作，但是为了保证高可用，就需要有一个选主的机制，保证在 leader 因为某个异常挂掉后，其他节点可以提升为 leader，然后正常工作。

<!--more-->

我们可以像 kube-controller-manager 一样，借助 client-go 的 leaderelection package 来实现高可用。

### 代码实现

client-go 中对选主的操作已经进行了封装，所以使用起来比较简单。

下面是一段简单的使用示例，编译完成后同时启动多个进程，只有一个进程会处于工作状态，当把处于工作状态的进程 kill 掉后，剩余的进程中的一个会变为 leader，开始工作。

```golang
package main

import (
    "context"
    "fmt"
    "log"
    "os"
    "time"

    "github.com/google/uuid"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
    "k8s.io/client-go/tools/leaderelection"
    "k8s.io/client-go/tools/leaderelection/resourcelock"
)

var enableLeaderElect bool

func main() {
    run := func(ctx context.Context) {
        // controller handler here
        for {
            log.Println("I'm working...")
            time.Sleep(5*time.Second)
        }
    }

    kubecli, err := newKubeClient()
    if err != nil {
        log.Fatalf("new kube client error: %v", err)
    }

    if enableLeaderElect {
        log.Println("run with leader-elect")

        id, err := os.Hostname()
        if err != nil {
            log.Fatalf("get hostname error: %v", err)
        }

        id = id + "_" + uuid.New().String()
        rl, err := resourcelock.New("endpoints", // support endpoints and configmaps
            "default",
            "test-controller",
            kubecli.CoreV1(),
            kubecli.CoordinationV1(),
            resourcelock.ResourceLockConfig{
                Identity: id,
            })
        if err != nil {
            log.Fatalf("create ResourceLock error: %v", err)
        }
        leaderelection.RunOrDie(context.TODO(), leaderelection.LeaderElectionConfig{
            Lock:          rl,
            LeaseDuration: 15 * time.Second,
            RenewDeadline: 10 * time.Second,
            RetryPeriod:   2 * time.Second,
            Callbacks: leaderelection.LeaderCallbacks{
                OnStartedLeading: func(ctx context.Context) {
                    log.Println("you are the leader")
                    run(ctx)
                },
                OnStoppedLeading: func() {
                    log.Fatalf("leaderelection lost")
                },
            },
            Name: "test-controller",
        })
    } else {
        log.Println("run without leader-elect")
        run(context.TODO())
    }
}

func newKubeClient() (kubernetes.Interface, error) {
    config, err := rest.InClusterConfig()
    if err != nil {
        return nil, fmt.Errorf("failed to create in-cluster kube cli configuration: %v", err)
    }

    cli, err := kubernetes.NewForConfig(config)
    if err != nil {
        return nil, fmt.Errorf("failed to create kube client: %v", err)
    }
    return cli, nil
}
```

注意我们这里如果失去 leader 后，会直接调用 `log.Fatalf` 退出进程。在 kubernetes 环境中通常采用 Deployment 等方式来部署，程序退出后，会重新启动一个 Pod 替代。

### 原理分析

leaderelection 的代码实现并不复杂。

主要的工作原理是，通过 kubernetes 的 endpoints 或 configmaps 实现一个分布式锁，抢到锁的节点成为 leader，并定期更新，而抢不到的节点会一直等待。当 leader 因为某些异常原因挂掉后，租约到期，其他节点会尝试抢锁，成为新的 leader。

```golang
rl, err := resourcelock.New("endpoints", // 实现锁的资源类型，支持 endpoints 或 configmaps
    "default", // 创建资源的 namespace
    "test-controller", // 锁的资源名称，这里会在 default namespace 下创建一个名为 test-controller 的 endpoint
    kubecli.CoreV1(),
    kubecli.CoordinationV1(),
    resourcelock.ResourceLockConfig{
        Identity: id, // 锁持有者的标志
    })
```

上面的代码可以看出 leaderelection 其实是利用 kubernetes 的 resource 来实现分布式锁。在对应 resource 的 annotations 中会更新 `control-plane.alpha.kubernetes.io/leader` 这个字段的值，更新成功的就是 leader。其中的内容是下面这个结构体的序列化结果:

```golang
type LeaderElectionRecord struct {
    // Holder 的 ID，如果为空，表示没有 Holder
    HolderIdentity       string      `json:"holderIdentity"`
    // 租约期限
    LeaseDurationSeconds int         `json:"leaseDurationSeconds"`
    // 获取租约的时间
    AcquireTime          metav1.Time `json:"acquireTime"`
    // 更新租约的时间
    RenewTime            metav1.Time `json:"renewTime"`
    LeaderTransitions    int         `json:"leaderTransitions"`
}
```

`leaderelection.RunOrDie` 函数会调用创建好的 LeaderElector 的 Run 函数。

```golang
func (le *LeaderElector) Run(ctx context.Context) {
    defer func() {
        runtime.HandleCrash()
        le.config.Callbacks.OnStoppedLeading()
    }()
    if !le.acquire(ctx) {
        return // ctx signalled done
    }
    ctx, cancel := context.WithCancel(ctx)
    defer cancel()
    go le.config.Callbacks.OnStartedLeading(ctx)
    le.renew(ctx)
}
```

通过 Run 函数看到在 `acquire` 成功后，会调用用户提供的 `le.config.Callbacks.OnStartedLeading` 函数。之后持续 `renew`。`acquire` 会阻塞，除非成功，或 context 被 cancel。

`le.acquire` 和 `le.renew` 内部都是调用了 `le.tryAcquireOrRenew` 函数，只是对于返回结果的处理不一样。

`le.acquire` 对于 `le.tryAcquireOrRenew` 返回成功则退出，失败则继续。

`le.renew` 则相反，成功则继续，失败则退出。

```golang
func (le *LeaderElector) tryAcquireOrRenew() bool {
    now := metav1.Now()
    // 这个结构体就是 endpoint 或 configmap 中 annotations `control-plane.alpha.kubernetes.io/leader` 的值
    leaderElectionRecord := rl.LeaderElectionRecord{
        HolderIdentity:       le.config.Lock.Identity(),
        LeaseDurationSeconds: int(le.config.LeaseDuration / time.Second),
        RenewTime:            now,
        AcquireTime:          now,
    }

    // 1. 获取或创建对应的 endpoint 或 configmap
    oldLeaderElectionRecord, err := le.config.Lock.Get()
    if err != nil {
        // 其他错误，返回 false，如果是不存在的错误，创建一个新的
        if !errors.IsNotFound(err) {
            klog.Errorf("error retrieving resource lock %v: %v", le.config.Lock.Describe(), err)
            return false
        }
        if err = le.config.Lock.Create(leaderElectionRecord); err != nil {
            klog.Errorf("error initially creating leader election record: %v", err)
            return false
        }
        le.observedRecord = leaderElectionRecord
        le.observedTime = le.clock.Now()
        return true
    }

    // 2. 获取到了锁的信息，检查锁的持有者和更新时间
    if !reflect.DeepEqual(le.observedRecord, *oldLeaderElectionRecord) {
        le.observedRecord = *oldLeaderElectionRecord
        le.observedTime = le.clock.Now()
    }
    // 当前持有锁的人不是自己且距上一次观察时间还没有超过租约的时间则认为当前锁被他人正常持有，直接返回 false
    if len(oldLeaderElectionRecord.HolderIdentity) > 0 &&
        le.observedTime.Add(le.config.LeaseDuration).After(now.Time) &&
        !le.IsLeader() {
        klog.V(4).Infof("lock is held by %v and has not yet expired", oldLeaderElectionRecord.HolderIdentity)
        return false
    }

    // 3. leaderElectionRecord 在函数开始的地方设置了默认值，这里根据自己是否是 leader 来更新相关的设置
    if le.IsLeader() {
        // Renew 操作，AcquireTime 使用旧的值，LeaderTransitions 保持不变
        leaderElectionRecord.AcquireTime = oldLeaderElectionRecord.AcquireTime
        leaderElectionRecord.LeaderTransitions = oldLeaderElectionRecord.LeaderTransitions
    } else {
        // 有 leader 切换，LeaderTransitions 值 + 1
        leaderElectionRecord.LeaderTransitions = oldLeaderElectionRecord.LeaderTransitions + 1
    }

    // 更新锁资源，这里如果在 Get 和 Update 之间有变化，将会更新失败
    if err = le.config.Lock.Update(leaderElectionRecord); err != nil {
        klog.Errorf("Failed to update lock: %v", err)
        return false
    }
    le.observedRecord = leaderElectionRecord
    le.observedTime = le.clock.Now()
    return true
}
```

这个步骤中很重要的一点是利用了 kubernetes API 操作的原子性。

在 `le.config.Lock.Get()` 中会获取到锁的对象，其中有一个 `resourceVersion` 字段用于标识一个资源对象的内部版本，每次更新操作都会更新其值。如果一个更新操作附加上了 `resourceVersion` 字段，那么 apiserver 就会通过验证当前 `resourceVersion` 的值与指定的值是否相匹配来确保在此次更新操作周期内没有其他的更新操作，从而保证了更新操作的原子性。
