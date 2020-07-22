---
categories:
    - "技术文章"
tags:
    - "kubernetes"
date: 2020-07-22
title: "Kubernetes 中支持 Pod 定向迁移"
url: "/2020/07/22/k8s-pod-directional-migration"
---

原生的 K8s 并不支持将指定的 Pod 从当前节点迁移到另外一个指定的节点上。但是我们可以基于 K8s 提供的扩展能力来实现对这一功能的支持。

<!--more-->

### 背景

在 K8s 中，kube-scheduler 负责将需要调度的 Pod 调度到一个合适的节点上。

它通过各种算法计算运行当前 Pod 的最佳节点。当出现新的 Pod 需要调度时，调度程序会根据其当时对 Kubernetes 集群的资源描述做出最佳的调度决定。但是，由于集群整体上是动态变化的，例如服务实例的弹性伸缩，节点的上下线，都会导致这个集群的状态逐渐呈现碎片化，从而产生资源的浪费。

#### 资源碎片

![fragment](https://image.fatedier.com/pic/2020/2020-07-22-k8s-pod-directional-migration-fragment.jpg)

如上图所示， 随时间推移后，当前集群的状态可能呈现一种碎片化，宿主机 D 和 E 各分配了 2 核的容器。此时如果我们需要再创建一个 4 核的容器 C，会由于资源不足而无法调度。

如果我们能将容器 B 从 主机 E 迁移到 主机 D，就可以将主机 E 腾空出来，节省了一台整机的成本。或者在需要创建一个新的 4 核的容器时，不会由于资源不足而无法调度。

#### K8s 背景知识

##### kube-scheduler

kube-scheduler 是 K8s 中负责 Pod 调度的组件，采用 Master-Slave 的架构模式，只有一个 master 节点负责调度。

整个调度器执行调度的过程大致分为两个阶段：过滤 和 打分。

* 过滤：找到所有可以满足 Pod 要求的节点集合，该阶段属于强制性规则，满足邀请的节点集合会输入给第二阶段，如果过滤处理的节点集合为空，则 Pod 将会处于 Pending 状态，期间调度器会不断尝试重试，直到有节点满足条件。
* 打分：该阶段对上一阶段输入的节点集合根据优先级进行排名，最后选择优先级最高的节点来绑定 Pod。一旦 kube-scheduler 确定了最优的节点，它就会通过ç»定通知 APIServer。

为了提高调度器的扩展性，社区重构了 kube-scheduler 的代码，抽象出了调度框架，以便于在调度器的各个处理过程中通过插件的方式注入自定义的逻辑（需要实现 Golang interface，编译进二进制文件）。

##### NodeAffinity

节点亲和概念上类似于 nodeSelector，它使你可以根据节点上的标签来约束 pod 可以调度到哪些节点。

目前有两种类型的节点亲和，分别为`requiredDuringSchedulingIgnoredDuringExecution` 和 `preferredDuringSchedulingIgnoredDuringExecution`。你可以视它们为`硬限制`和`软限制`，意思是，前者指定了将 pod 调度到一个节点上必须满足的规则（就像 nodeSelector 但使用更具表现力的语法），后者指定调度器将尝试执行但不能保证的偏好。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: with-node-affinity
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/e2e-az-name
            operator: In
            values:
            - e2e-az1
            - e2e-az2
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 1
        preference:
          matchExpressions:
          - key: another-node-label-key
            operator: In
            values:
            - another-node-label-value
  containers:
  - name: with-node-affinity
    image: k8s.gcr.io/pause:2.0
```

此节点亲和规则表示，pod 只能放置在具有 Label Key 为 kubernetes.io/e2e-az-name 且值为 e2e-az1 或 e2e-az2 的节点上。另外，在满足这些标准的节点中，具有 Label Key 为 another-node-label-key 且值为 another-node-label-value 的节点应该优先使用。

##### Admission webhook

Admission webhook 是一种用于接收准入请求并对其进行处理的 HTTP 回调机制。 可以定义两种类型的 admission webhook，即 validating admission webhook 和 mutating admission webhook。 Mutating admission webhook 会先被调用。它们可以更改发送到 API 服务器的对象以执行自定义的设置默认值操作。

在完成了所有对象修改并且 API 服务器也验证了所传入的对象之后，validating admission webhook 会被调用，并通过拒绝请求的方式来强制实施自定义的策略。

### 方案

#### descheduler

解决这一类问题的一种方案是类似社区目前的 [descheduler](https://github.com/kubernetes-sigs/descheduler) 项目。

该项目本身就是属于 kubernetes sigs 的项目，Descheduler 可以根据一些规则和配置策略来帮助我们重新平衡集群状态，当前项目实现了一些策略：RemoveDuplicates、LowNodeUtilization、RemovePodsViolatingInterPodAntiAffinity、RemovePodsViolatingNodeAffinity、RemovePodsViolatingNodeTaints、RemovePodsHavingTooManyRestarts、PodLifeTime，这些策略都是可以启用或者禁用的，作为策略的一部分，也可以配置与策略相关的一些参数，默认情况下，所有策略都是启用的。

另外，如果 Pod 上有 `descheduler.alpha.kubernetes.io/evict` annotation，也会被 descheduler 驱逐。利用这个能力，用户可以按照自己的策略去选择驱逐哪一个 Pod。

descheduler 的工作方式非常简单，根据策略找到符合要求的 Pod，通过调用 evict 接口驱逐该 Pod。此时该 Pod 会在原节点上被删除，之后再依赖上层的控制器（例如 Deployment）去创建新的 Pod，新的 Pod 会重新经过调度器选择一个更优的节点运行。

这个方案的优点是兼容目前的 K8s 的整体架构，不需要改动现有的代码。缺点是无法做到精确的 Pod 迁移。

**由于 kube-scheduler 的调度是串行的，在调度当前的 Pod 时并没有考虑到之后需要调度的 Pod，而我们在做集群碎片整理时，通常会根据当前的集群布局生成一连串的迁移操作，从单个 Pod 的调度角度来说可能不是最优解，但是多个操作的集合却是一个最优解。**

#### SchedPatch Webhook

[openkruise](https://github.com/openkruise/kruise) 项目中有类似的 Roadmap 规划，但尚未实现。

SchedPatch Webhook 实现一套 mutating webhook 接口，接收 kube-apiserver 中创建 Pod 的请求。通过匹配用户自定义的规则，注入新的调度需求，例如 `affinity`, `tolerations` 或者 `node selector`，从而实现精确调度的需求。

通过这一方法，我们可以先创建一个 SchedPatch 对象，指明某个 Deployment 的下一个 Pod 倾向于调度到某一个指定的节点上，之后驱逐想要迁移的 Pod。Deployment 观测到有一个 Pod 被驱逐，会创建一个新的 Pod 补充，此时 kube-apiserver 会将 Pod Create 请求转发给 SchedPatch webhook，在这个 webhook 中我们将会修改 Pod 的调度需求，从而让 kube-scheduler 会倾向于将这个 Pod 调度到某一个指定的节点。

##### CRD

下面是一个简单的 SchedPatch CRD 定义。

```go
type SchedPatch struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`
 
    Spec   SchedPatchSpec   `json:"spec,omitempty"`
    Status SchedPatchStatus `json:"status,omitempty"`
}

type SchedPatchSpec struct {
    // 匹配哪些 Pod
    Selector *metav1.LabelSelector `json:"selector"`
    // 最大会 Patch 的符合匹配条件的 Pod 数量，超过后不再注入新的调度规则
    MaxCount int64 `json:"maxCount"`
    
    Affinity *Affinity `json:"affinity,omitempty"`
    Tolerations []Toleration `json:"tolerations,omitempty"`
    NodeSelector map[string]string `json:"nodeSelector,omitempty"`
}

type SchedPatchStatus struct {
    ObservedGeneration int64 `json:"observedGeneration"`
    
    // 记录哪些 Pod 被 Patch 了新的调度规则
    PatchedPods []string `json:"patchedPods,omitempty"`
}
```

##### Webhook 逻辑

1. 接收 kube-apiserver 发送过来的 Pod Create 请求。
2. 从 Informer Cache 中获取所有的 SchedPatch 对象，过滤出和创建的 Pod 匹配的所有对象。如果 PatchedPods 的数量已经达到 MaxCount，也需要过滤掉。
3. 更新 PatchedPods。
4. 修改 Pod Spec，注入 SchedPatchSpec 中的调度规则，返回给 kube-apiserver。

##### 迁移示例步骤

假设我们有一个 test 的 Deployment，Pod Label 中含有 `service: test`。当前有一个 Pod 在 node-1 上，我们期望将这个 Pod 迁移到 node-2 上。

创建一个 SchedPatch 对象，匹配后续创建的一个含有 `service: test` Label 的 Pod，注入 NodeAffinity，表示倾向于将这个 Pod 调度到节点 node-2 上。

```yaml
kind: SchedPatch
spec:
  selector:
  matchLabels:
    service: "test"
  maxCount: 1
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 1
          preference:
            matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
              - node-2
```

直接通过 kubectl 删除 node-1 上的 Pod。

此时 Deployment Controller 会创建一个新的 Pod，观察这个 Pod 会被调度到 node-2 上。

### 备注

上述方案只是初步阐述了一下实现这个功能的思想，实际使用过程中，仍然需要解决很多细节问题。
