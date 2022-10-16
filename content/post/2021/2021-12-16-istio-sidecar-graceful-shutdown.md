---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-12-16
title: "让 Istio sidecar 优雅终止"
url: "/2021/12/16/istio-sidecar-graceful-shutdown"
---

在 [Istio sidecar 容器启动停止问题](/2021/08/26/istio-sidecar-container-start-and-stop-problem/) 这篇文章中，描述了 Istio sidecar 的启动停止顺序的问题，但是实际接入服务的过程中，仍然发现存在一些异常的情况发生，需要进一步的优化。

<!--more-->

### 方案更新过程

我们主要通过在 sidecar container 增加 prestop command 来控制 envoy 的退出逻辑。在生产环境不断遇到了新的问题，也不断优化了这个脚本的逻辑，记录过程如下。

#### 初始脚本

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "curl -X POST localhost:15000/drain_listeners?inboundonly; while [ $(ps -e -o uid,pid,comm | grep -v '1337' | grep -v '1 pause' | grep -v 'UID' | wc -l | xargs) -ne 0 ]; do sleep 1; done"]
```

当 Pod 被删除时，kubelet 会并发地给所有容器发送 SIGTERM 的信号，当达到 terminationGracePeriodSeconds 后，如果容器还没有退出，会发送 SIGKILL 信号强制退出。

增加了 preStop 后，kubelet 在发送 SIGTERM 信号之前，会先执行 preStop 的逻辑，也就是上述 command。执行完成后才会继续发送信号。

`curl -X POST localhost:15000/drain_listeners?inboundonly` 是向 enovy 的 admin port 发送请求，将入方向的 listener 结束。enovy 收到请求后，会取消所有入方向的端口监听，不再接收新的连接和请求。注意，这里特别设置了 inboundonly，不关闭出方向的 listeners，因为即使处于终止阶段，用于进程可能仍然需要向外发送请求。

后续的 while 循环通过 ps 等待所有用户进程退出，间隔 1s。之所以在 sidecar 容器中通过 ps 可以看到所有的进程，依赖于我们让所有的 Pod 开启 ShareProcessNamespace 以共享进程命名空间。开启后，1 号进程就是 pause 进程。

再之后会进入到 pilot-agent(go 写的用于和 enovy 交互的 agent) 的退出信号处理逻辑。

pilot-agent 会先调用 `localhost:15000/drain_listeners?inboundonly&graceful`。

再 sleep 一段时间 (目前默认全局配置为 5s，可修改)，之后强行结束 envoy。

#### 移除开始的 drain_listeners

上述配置实际应用后，发现在容器停止过程中有少量 503 的请求，如果是 ingress-nginx 过来的请求可能会返回 502。

原因就是当 Pod 被删除时，马上调用 drain_listeners 会导致 enovy 不再监听端口，不再接收新的连接，新连接过来会是 connection refused。

所以我们决定将 drain_listeners 的操作移除，让 enovy 继续接收请求，直到用户进程完全退出之后，再进入到 pilot-agent 的退出流程。

#### 用户进程退出后立即结束 envoy

上述配置实际应用后，遇到新的问题。

某个服务对外提供 grpc 服务，grpc 客户端是长连接。此时的退出流程变为:

1. Pod 被终止。
2. 用户容器开始 sleep 5s。(app 模版中会给所有的容器加上 sleep 5s 的 prestop 逻辑，以避免因为服务发现更新的延迟，导致请求仍然发给旧的实例，旧实例不存在会有问题)
3. sidecar 容器持续等待用户进程退出。
4. 用户进程退出，关闭监听端口。
5. sidecar 容器 pilot-agent sleep 5s。
6. sidecar 容器退出。

上述流程在第 5 步时，由于 grpc 客户端是长连接，所以即使服务发现/kube-proxy 已经将旧的 pod ip 摘除，请求仍然会发到旧的实例上去。此时 envoy 处于正常状态，但是用户进程已经退出，所以 envoy 向客户端返回了 503。

在没有接入 sidecar 前，用户进程退出后，客户端的 grpc 长连接就会立刻断开，顶多影响到当前正在进程中的少量请求，影响比较小。而接入 sidecar 后，会有 5s 的时间，所有进来的请求都会返回 503。

为了解决这个问题，我们需要让 envoy 在用户进程退出后就立即退出，避免 hold 住 grpc 的长连接继续接收请求。

prestop command 被修改为

```
while [ $(ps -e -o uid,pid,comm | grep -v '1337' | grep -v '1 pause' | grep -v 'UID' | wc -l | xargs) -ne 0 ]; do sleep 0.1; done; curl -XPOST http://127.0.0.1:15000/quitquitquit"
```

ps 判断间隔缩短为 0.1s，尽量减少 envoy 退出的延迟时间。

通过 `quitquitquit` 接口，强制退出 envoy。

#### 避免僵尸进程的影响

上述配置实际应用后，遇到新的问题。

由于有的 K8s 集群版本比较旧，使用的 pause 镜像也是旧版本，pause 进程并不会回收挂到自己下面的僵尸进程。

某些容器启动命令会通过 shell 去启动应用程序，应用程序的进程是 shell 进程的子进程。当容器接收到退出信号后，shell 进程可能会先退出，之后应用程序会被挂到 1 号进程(pause)下，当应用程序退出后，成为僵尸进程，旧版本的 pause 进程没有通过 wait 回收。

之前没有考虑到僵尸进程的问题，导致 envoy 一直不能退出，直到达到容器的 terminationGracePeriodSeconds 时间后才被强制结束。

修改 prestop command 加入对僵尸进程的过滤:

```
while [ $(ps -e -o uid,pid,comm | grep -v '1337' | grep -v '1 pause' | grep -v 'UID' | grep -v 'defunct' | wc -l | xargs) -ne 0 ]; do sleep 0.1; done; curl -XPOST http://127.0.0.1:15000/quitquitquit"
```

#### 加回 drain_listeners

上述配置实际应用后，遇到新的问题。

有的用户容器，在退出前，会先停止监听端口，过一段时间才会退出。

退出流程为:
1. Pod 被终止。
2. 用户容器开始 sleep 5s。
3. sidecar 容器持续等待用户进程退出。
4. 用户进程关闭端口监听，但是进程并不退出。
5. sidecar 容器继续等待。
6. 用户进程退出。
7. sidecar 容器 envoy 立即退出。

上述步骤 5 中，如果客户端是 grpc 或 http 的长连接，请求就有可能继续发到这个实例，此时用户进程已经没有监听端口，所以 envoy 只能返回 503。

在没有接入 sidecar 前，用户进程通过断开连接的方式，让客户端重连到其他新的节点。但是引入 sidecar 后，envoy 会维持和客户端的长连接，导致出错。

为了解决上述问题，我们将 preStop command 修改为:

```
sleep 4.8; curl -XPOST 'http://127.0.0.1:15000/drain_listeners?inboundonly&graceful'; while [ $(ps -e -o uid,pid,comm | grep -v '1337' | grep -v '1 pause' | grep -v 'UID' | grep -v 'defunct' | wc -l | xargs) -ne 0 ]; do sleep 0.1; done; curl -XPOST http://127.0.0.1:15000/quitquitquit
```

增加了 `curl -XPOST 'http://127.0.0.1:15000/drain_listeners?inboundonly&graceful`

这里需要说明一下 envoy 关于这个接口逻辑，参考 https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/draining

* 如果没有 graceful 参数，则 drain_listeners 会立即关闭 listeners，停止端口监听。
* 如果加上 graceful 参数，drain_listeners 会先进入一段 graceful 的时间段，在这个时间段内，如果当前没有正在进行中的请求，则立即停止端口监听; 如果有正在进行中的请求，则继续接收新的连接，处理新的请求，但是，对于 HTTP1 请求，会在 Response 中增加 `Connection: close` header，对于 HTTP2(grpc) 请求，会发送 GOAWAY 帧，意图都是提醒客户端断开当前连接。
* 上面的 graceful 时间由 drain-time-s 参数指定，istio 中全局配置为 45s。当达到这个时间后，即使有当前进行中的请求，也会立即关闭端口监听。
* 可以通过 envoy 的 drain_strategy 参数指定 graceful 阶段 drain 的策略，可选 default 和 immediate。istio 全局硬编码为 immediate。default 会在 45s 的持续时间内，从 0 到 100% 给响应加上断开连接的标志，有一个逐渐增加的过程。immediate 表示进入 graceful 阶段后立即给所有请求的响应增加断开连接的标志。

增加了 `sleep 4.8`。

这里之所以 sleep 4.8s，比用户容器的 sleep 时间短了 200ms。因为当 kubelet 并发的给所有容器执行 sleep 命令时，很难保证大家同时完成，很有可能会有一个间隔的时间窗口。如果用户进程在 envoy 之前结束并退出，那么就仍然有可能出现一个非常短暂的时间窗口， envoy 接收请求，用户进程没有监听，只能返回 503。当 envoy 先进入 drain 的流程后，如果用户进程退出，envoy 也会立即关闭监听，不再接收新的连接和请求，将影响降低到最低。

优化后的退出流程:

1. Pod 被终止。
2. 用户容器开始 sleep 5s。
3. sidecar 容器开始 sleep 4.8s。
4. sidecar 通常会先 sleep 结束，调用 drain_listeners 接口，使 envoy 进入 graceful drain 的阶段。并持续等待用户进程结束。
5. 如果当前没有正在进行中的请求，envoy 会立即关闭监听。
6. 如果当前有正在进程中的请求，envoy 会继续接收新的请求，并给每一个请求的响应中添加上断开连接的标志，以使客户端能够主动断开连接，重连到其他节点。
7. 用户进程关闭端口监听，断开连接，但是进程不退出。
8. sidecar 中 envoy 感知到当前没有进行中的请求，立即关闭端口监听。
9. 客户端理论上应该都已经重连到其他节点，不会再有新的请求进入。如果有新连接，会得到 connection refused 的响应。
10. 用户进程退出。
11. sidecar 强制退出 envoy，之后容器退出。

#### 降低 terminationDrainDuration

`terminationDrainDuration` 默认为全局 5s。也就是 envoy 收到退出信号后，会固定 sleep 的时间。

由于我们通过 prestop hook 来实现优雅终止，就不需要依赖 `terminationDrainDuration` 了。

由于并发问题，envoy 处理 `curl -XPOST http://127.0.0.1:15000/quitquitquit` 的请求有一定几率 在收到 SIGTERM 信号之后，这样导致 istio sidecar 毫无意义地 sleep 了一段时间。

如果服务发现的数据出现了延迟，那么过来请求会得到 503 的结果，而不是 connection refused，有可能就会影响到客户端的重试。

我们可以通过修改 `meshConfig.defaultConfig.terminationDrainDuration` 来调整全局的默认值，将这个值改成尽可能的小，比如 100ms。但是由于 Bug，某些版本中可能无法修改为小于 1s 的值，具体见 issue: https://github.com/istio/istio/issues/41046。该问题在最新的 1.14 和 1.15 版本中已修复。

### 社区的进展

istio 1.12 之前的退出逻辑基本上不可用，pilot-agent 会在调用 drain_listeners 之后 sleep 一段固定的时间就立即结束 envoy。这个时间默认是全局配置为 5s。配置太短，会导致 envoy 退出了，用户进程还没退出，用户进程也没法访问外部网络。配置的太长，会导致 Pod 停止时间过长，影响发版效率。

https://github.com/istio/istio/pull/35059

istio 1.12 中做了一个优化，将原来 sleep 的逻辑更改为先 sleep 一个 MINIMUM_DRAIN_DURATION 的时间段，再通过 envoy 的 stats 接口获取当前 active 的连接数，当 active 连接数为 0 时，立即退出 envoy。会比之前好很多，解决了部分问题。但是，envoy 的生命周期也没有完全和用户进程关联，有可能退出阶段短暂的没有请求，之后用户进程可能仍然需要向外部通信，如果此时 envoy 退出了的话，外部通信就失败了。

而且在收到 SIGTERM 信号后就立即调用 drain_listeners，如果用户服务请求较少，当前恰好没有进行中的请求，端口监听就被立即关闭了。此时服务发现的节点还没有摘掉，刚好有新的请求进来，就会出现 connection refused。

此功能默认没有开启，需要将 EXIT_ON_ZERO_ACTIVE_CONNECTIONS 环境变量设置为 true 来启用。

总的来说，要想让 envoy sidecar 的终止逻辑能够完美的 cover 住各个边界场景，可能还需要更多的实践经验。
