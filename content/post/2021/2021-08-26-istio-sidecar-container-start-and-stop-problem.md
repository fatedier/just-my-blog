---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-08-26
title: "Istio sidecar 容器启动停止问题"
url: "/2021/08/26/istio-sidecar-container-start-and-stop-problem"
---

由于引入了 sidecar，会通过 iptables 规则将流量劫持到 sidecar 中的进程。但是 K8s 上并没有精确控制 sidecar 的能力，导致由于 sidecar 与主容器的启停顺序问题会引起一些非预期的行为。

<!--more-->

### 概述

目前由于 sidecar 会引起的一些问题场景:

1. 主容器启动前 sidecar 还没有启动完成，导致主容器的进程在这段时间无法访问外部网络，比如从远端拉取配置信息。有的应用可能失败后就直接退出，重新拉起后仍然会循环出现此问题。
2. 在 Pod 被停止时，sidecar 先于主容器退出。这个会面临两类问题，一个是当前正在进行的请求会被异常中断，另外就是主容器将无法再和外部网络通信。
3. K8s 中 Job 类型的 Pod 注入 sidecar 后无法正常结束。因为 Job 类型的 Pod 主容器退出后，sidecar 并没有退出，导致 Job 永远无法结束。
4. 接入 istio 后，在 istio init containter 之后启动的其他 init container 中的进程将无法访问外部网络。这个取决于修改 iptables 的 init containter 的注入顺序。即使顺序正常，init containter 的流量也无法被劫持，将不能按照预期的行为来工作。

社区的一些问题追踪:

Envoy shutting down before the thing it's wrapping can cause failed requests
https://github.com/istio/istio/issues/7136

Using Istio with CronJobs
https://github.com/istio/istio/issues/11659

目前 istio sidecar 的 graceful shutdown 做的也相当不好，有待完善。

istio sidecar 目前会在收到 SIGTERM 信号后，停止接收新的连接，然后 sleep 5 秒(可配置)，之后退出，并不会等到所有进行中的请求结束。

### 理想的状态

* 当 Pod 被启动时，sidecar 先于主容器启动，启动完成后，kubelet 再拉起主容器。
* 当 Pod 被主动结束时，sidecar 停止接收外部连接，处于 shutdown 状态，当前正在进行的请求不受影响，等待主容器结束。当主容器退出后，sidecar 再退出。
* 当 Job 类型的 Pod 启动时，sidecar 先于主容器启动。当 Job 类型的 Pod 主容器退出后，sidecar 能感知到，并且正常退出。

如果能实现上述能力，则可以解决问题一，二，三。问题四目前还没有想到很好的解决方案，只能限制用户不在 init containter 中做一些需要依赖 istio 的服务访问。

### sidecar 启动顺序问题

启动顺序的问题，目前已经有了比较简单的解决方案。主要是借助 K8s 提供的 postStart hook 的能力。

![sidecar](https://image.fatedier.com/pic/2021/2021-08-26-istio-sidecar-container-start-and-stop-problem-sidecar.jpg)

目前这个能力需要依赖 kubelet 的具体实现逻辑，这个逻辑看上去并非官方正式的定义，不一定完全可靠，也许在之后的版本中会被修改:
1. kubelet 会按照 containter 的定义顺序来依次启动每个容器。
2. kubelet 在创建容器后，会执行 postStart hook，只有在 hook 调用返回后才会继续创建下一个容器。

借助这两个逻辑，我们需要:
1. 注入 sidecar containter 时，将其放到 containter 数组的第一个。
2. sidecar container 的 lifecycle postStart hook 中增加一个等待 envoy 进程 ready 的逻辑。

istio 目前会加上

```yaml
lifecycle:
  postStart:
    exec:
      command:
      - pilot-agent
      - wait
```

### sidecar 停止顺序问题

sidecar 停止顺序目前还没有很好的解决方案，各个依赖 sidecar 能力的开源项目基本上都在等着 K8s 官方社区来推动这个问题的解决。

2019 年的时候已经有 Proposal 提议增加 sidecar 类型的 containter
https://github.com/kubernetes/enhancements/issues/753

该提案的目的是可以声明指定的 containter 为 sidecar 类型，则这样的容器会先于主容器启动，并在主容器停止后才退出。本来预计是在 K8s 1.18 版本中发布，代码也已经合入，但是后来由于某些大佬觉得此方案并不完善，没有覆盖到所有的场景(上述问题三和四就没有解决)，就将这部分代码 revert 了。

目前社区的进度还是在收集场景，没有继续推进，中短期来看，并不会有很好的官方解决方案。

在官方没有彻底解决此问题前，我们只能在 K8s 之外尝试解决这个问题，目前收集到的解决方案大致有以下三种:

#### preStop 等待其他容器结束

K8s pod lifecycle 提供了一种 preStop hook 的能力，可以在 Pod 被删除时，先执行容器的 preStop hook，执行完成后再给容器发送 SIGTERM 信号，如果超过 terminationGracePeriodSeconds 配置的时间后用户进程仍然没有结束，则发送 SIGKILL 信号强制退出。

我们可以参考解决容器启动顺序时的方法，在 envoy sidecar 的 preStop hook 中，等待其他容器退出后，自己再退出。和 postStart 不同的是，kubelet 停止容器并不是顺序执行的，而是同时给所有的容器发送信号，和顺序无关。

那么怎么判断除自己之外的其他容器都已经退出了呢？

目前主要可以根据网络连接和进程信息来判断，同时需要确保 istio-proxy 使用的镜像里包含了相关的命令行工具，此外，通过 grep 过滤有可能会有一些误判，比如用户进程的命名有冲突。

网络连接过滤的命令:

`netstat -plunt | grep tcp | grep -v envoy | grep -v pilot-agent | wc -l | xargs`

优点: 改动较小，现有服务的运行环境没有变化。
缺点: 不能覆盖所有的场景，例如 Job 类型的服务，如果一段时间内不会对外保持连接的话，则会判断失误。

进程信息过滤的命令:

`ps -e -o uid,pid,comm | grep -v '1337' | grep -v '1 pause' | grep -v 'UID' | wc -l | xargs`

使用进程信息过滤的话，需要设置 `pod.spec.shareProcessNamespace: true`，使所有容器共享进程命名空间。这里过滤了 1337 是因为 istio-proxy 容器的用户 UID 是 1337，另外启用 shareProcessNamespace 后，1 号进程会是 pause。

优点: 能覆盖绝大多数场景。
缺点: 由于需要共享进程命名空间，改变了原先服务的运行环境，需要确保服务对这一变化没有依赖。

我们可以在 sidecar inject 模版中配置 lifecycle。

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "curl -X POST localhost:15000/drain_listeners?inboundonly; while [ $(ps -e -o uid,pid,comm | grep -v '1337' | grep -v '1 pause' | grep -v 'UID' | wc -l | xargs) -ne 0 ]; do sleep 1; done"]
```

这里增加了一个 `curl -X POST localhost:15000/drain_listeners?inboundonly`，是向 envoy 发送信号，停止接收新建连接，`inboundonly` 表示停止接收入方向的连接，但是出方向不受影响，因为用户进程可能仍然需要主动向外部服务发送请求。

这个方案并不能解决 Job 类型的 Pod 无法接入 istio 的问题，因为当用户进程退出后，没有其他方式通知 envoy sidecar 去退出。

#### 改造 pilot-agent，依赖外部 Pod 信息等待其他容器结束

此方案可以通过改造 pilot-agent 和 istiod 来实现。

istiod 拥有所有 Pod 的 status 信息。pilot-agent 可以通过 istiod 提供的接口查询自身 Pod 的容器状态信息，等所有容器的状态信息被更新为退出后，自己再退出。

这个方案的缺点是仅能解决 istio 自身的问题，并不是一个 sidecar 问题的通用解决方案，如果使用了其他项目，则仍然需要改造其他项目的代码。

另外，由于依赖 istiod 提供的外部信息，可能会有某些没有考虑到的边界场景，例如网络异常等情况，导致 sidecar 没有按照预期的行为来退出。

#### 由自定义启动程序接管用户进程的生命周期

此方案的目的是提供一套通用的解决方法，构造一个通用的容器生命周期管理机制。

可参考项目: https://github.com/karlkfi/kubexit

类似于 tini 这样的工具，我们可以编写一个自定义的 exec 应用，作为容器的启动入口，由 exec 应用去启动用户的进程。

这个 exec 应用可以在执行用户进程前以及用户进程结束后注入自定义的处理逻辑。

例如，在容器启动前，将容器名写入一个指定的共享目录，在容器结束后，再将之前创建的文件删除。则其他容器可以根据该目录下的文件来判断哪些容器还没有退出。

我们还可以通过环境变量去编排容器的退出规则，例如使 A 在 B 退出之后才能退出，B 在 C 退出之后才能退出。

通过 webhook 机制可以将注入共享目录，替换容器启动参数等工作自动化，做到用户无感知。

这个方案的缺点是，需要用户显式的指定容器启动的 command 和 args，如果用户使用的是 Dockerfiles 中 EntryPoint，则无法使用。
