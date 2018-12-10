---
categories:
    - "技术文章"
tags:
    - "kubernetes"
date: 2018-12-10
title: "kubernetes 中删除 pod 导致客户端连接不存在的 IP 超时问题"
url: "/2018/12/10/a-connect-timeout-problem-caused-by-k8s-pod-deleting"
---

在 k8s 平台测试自研 Service Mesh 方案时，发现更新服务时，会有少量请求耗时剧增。跟踪排查后确认是由于 Pod 被删除后，原先的 Pod 的 IP 不存在，客户端建立连接超时引起。

<!--more-->

### 现象

正常升级某个服务的 Deployment。

升级策略，先起一个新实例，再停一个旧实例：

```
type: RollingUpdate
rollingUpdate:
  maxSurge: 1
  maxUnavailable: 0
```

实例停止前如果没有请求会立即退出，如果有请求则等待最多 60 秒，仍然没有结束时会被强制杀掉。

```
terminationGracePeriodSeconds: 60
```

升级过程中，发现服务响应时间的 98 值增长很多，95 值没有太大变化，看起来有少量请求被升级操作影响到了。

### 原因

排查后，确认部分请求变慢的原因是因为和后端实例建立连接超时，由于使用的是 Go 的 DefaultTransport，所以连接超时时间为 30s，部分请求在超时 30s 后才被重试，从而导致响应时间的 98 值变慢。

为什么建立连接会超时？

原来在升级实例的过程中，实例被杀掉，对应的容器的虚拟 IP 就不存在了，而客户端建立连接时发送的 SYNC 包收不到回应，会一直重发，直到超时。

之所以客户端仍然会给该 IP 发送请求，是因为我们自研的 Service Mesh 方案的服务发现没有采用 k8s 默认的 DNS 轮询方式，而是自己开发的服务发现组件，为了能够更好地配合负载均衡的能力。网关是采用轮询的方式，每隔 10s 从 Discovery 组件同步一次数据，所以被杀掉的实例没有及时被同步到各网关。

### kubernetes Pod 停止流程

为了更好解决问题，我们需要理解 k8s 中单个 Pod 停止的流程。

1. 用户发送请求删除 Pod，默认终止等待时间为 30s
2. 在 Pod 超过该等待时间后 API server 就会更新 Pod 的状态为 **dead**
3. 在客户端命令行上显示 Pod 状态为 **terminating**
4. 与步骤三同时，当 Kubelet 观察到一个 Pod 在步骤2被标记为 **terminating**，开始终止工作
    1. 如果在pod中定义了 **preStop hook**，在停止 pod 前会被调用。如果在等待期过后，**preStop hook** 依然在运行，第二步会再增加2秒的等待期
    2. 向 Pod 中的进程发送 **SIGTERM** 信号
5. 跟第三步同时，该 Pod 将从该 service 的地址列表中删除，不再是 replication controllers 中处于运行状态的实例之一。关闭的慢的 Pod 将不会再处理流量，因为负载均衡器（像是 service proxy）会将它们移除
6. 过了等待期后，将向 Pod 中依然运行的进程发送 SIGKILL 信号而杀掉进程
7. Kublete 会在 API server 中通过将优雅周期设置为0（立即删除）来完成 Pod 的删除。Pod 将会从 API 中消失，并且在客户端也不可见

### 解决方案

#### 优化超时时间

使用自定义的 Transport，内网的话超时时间可以减少为 1s，让请求尽快被重试，虽然不能解决问题，但是可以有效缓解问题。

#### 确保实例被服务发现摘除后再停止

思考了问题发生的原因，首先想到的就是能不能让实例先从服务发现中摘除，确认服务发现数据被同步到了各网关后，再杀实例。搜索了 k8s 的相关文档，发现通过 **preStop** 的 hook 机制，可以实现该功能。

示例配置如下：

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      terminationGracePeriodSeconds: 90
      containers:
      - name: nginx
        image: my-nginx:xxx
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 30"]
        ports:
        - containerPort: 80
```

重点就在于 **lifecycle** 的配置。对应实例停止时，会先将该实例的服务发现地址从 **service** 中移除，之后会调用我们给定的命令 `sleep 30`，等待 30s 后，再给实例发送 SIGTERM 信号，如果实例超过 **terminationGracePeriodSeconds** 配置的时间后，会再给实例发送 SIGKILL 信号，强行杀掉实例。

我们服务发现数据同步间隔是 10s，留出 30s 的时间，所有网关的服务发现数据正常情况下已经全部同步完成，不会再有新的流量被路由到该实例上，也就不会出现新建连接超时的问题。

需要注意的是，由于我们延迟了 30s 停止实例，所以保险起见 **terminationGracePeriodSeconds** 也可以相应的增加 30s。
              
### 猜想其他的解决方法

#### k8s 自身提供延迟停止实例的能力

如果 k8s 自身就能通过 Deployment 参数配置实现上文中我们通过 **preStop** 实现的功能会更好一些，毕竟是一个比较取巧的方案，不一定完善。

#### IP 被摘除后建立连接可以直接返回错误

涉及到 k8s 集群的网络解决方案，不一定所有的架构都能支持，需要进一步调研。
