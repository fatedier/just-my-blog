---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-12-24
title: "减少 Istio 控制面下发的配置"
url: "/2021/12/24/reduce-istio-control-panel-push-config"
---

默认情况下，istiod 会 watch 集群中所有的 namespace，生成对应的配置，实时的通过 xDS 协议，推送给所有实例的 sidecar 容器。

业务实例会被分发到大量不相关的配置，根本用不到，不仅增加 istiod 分发配置的时效性，也增加了 sidecar 的资源消耗。

<!--more-->

### 背景知识

xDS 协议 是数据平面的 API，我们目前主要接触到的是 CDS、LDS、EDS、RDS。

* CDS: Cluster，集群发现服务，envoy 中的 Cluster 其实就是服务的概念，Cluster 是一组 Endpoint 的集合，也包含了请求要以何种 lb 的方式路由到不同的 Endpoint。
* LDS: Listener， 监听器发现服务，比较核心的概念，每一个 service 的一个端口，都会有与之对应的 listener，每一个 listener 又可以配置一些 Filter Chain。比如 HTTP 七层的插件配置也会放在这里。
* EDS: Endpoint，集群成员发现服务，在 K8s 集群中通常对应 Endpoints 的概念。
* RDS: Route，路由发现服务，提供给 HTTP Filter 使用，是一些路由规则和重试之类的配置。匹配的请求会被发送到指定的 Cluster。
* ADS 聚合发现服务，主要是解决上述其他类型配置的顺序更新问题。

即使没有创建 istio 的 VirtualService 之类的资源，K8s 原生的 Service 也会被 istio 转换为内部的资源，这样的好处是即使对端服务没有接入 istio，只要客户端接入了，也可以拥有部分的能力。

### 减少配置的方式

目前 Istio 提供了多种方式来解决这个问题，但是并不完美，因为不能提前知道一个服务会访问其他哪些服务，所以仍然需要推送很多并不会被用到的配置。

#### DiscoverySelectors

在 MeshConfig 中配置，MeshConfig 通常配置在 istio-system namespace 下名为 istio 的 configmap 中。

可以通过 DiscoverySelectors 让 istiod 只处理满足匹配条件的指定 namespace 下的资源，包括 Services，Pods，Endpoints。

Istiod 不会去 watch 和处理不匹配的 namespace 的资源。和后面的几种方式相比较，这种方式不仅不会生成 xDS 配置推送给 sidecar，也不会去 watch 相关资源的变更。

例如，kube-system 下会创建一个 kubelet 的 headless Service，istio 会给 headless Service 的所有 IP Port 创建一个对应的 Listener，导致 LDS 会多下发很多无用的配置。我们想要让 istio 不去管理 kube-system 下的资源。

```yaml
discoverySelectors:
  - matchExpressions:
    - key: istio-discovery
      operator: NotIn
      values:
        - disabled
```

之后再给 kube-system 加上 `istio-discovery: disabled` 的 annotation。

这样，istiod 就不会去 watch kube-system 下的资源，也不会将这部分配置推送给 sidecar。

#### Sidecar

Istio 提供了一个 Sidecar 的 CRD 可以用于限制指定 namespace 下可访问到的资源。

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Sidecar
metadata:
  name: default
  namespace: istio-system
spec:
  egress:
  - hosts:
    - "./*"
    - "istio-system/*"
```

Sidecar 创建在 istio-system namespace 下，则表示是全局的默认配置，对所有 namespace 生效。如果在其他业务 namespace 下，则只在对应的 namespace 下生效。

`.` 表示当前 namespace，`*` 表示匹配所有。`./*`，表示匹配当前 namespace 下的所有服务。

`istio-system/*` 表示，可以访问 istio-system 下的所有服务。

通过合理的配置 Sidecar，可以在 namespace 级别，控制不下发一些无效的配置。前提是对端的资源要对自身 namespace 可见，如果对端已经通过 `exportTo` 限制了其他 ns 的访问，则即使在 Sidecar 中声明也没有用。

缺点是必须持续维护服务在 namespace 之间的访问规则，对运维来说有心智负担。

#### Istio Resource 的 ExportTo

Istio 的原生 Resource 一般都会有一个 `exportTo` 的字段，用于标识。

像 VirtualService 和 DestinationRule 都有对应的字段。

`exportTo` 的值是一个 string 数组，可以是 `.`，`*` 以及指定的 namespace。

例如如果 `exportTo = ["."]`，则只会将当前配置分发给同 namespace 下的其他 sidecar。

#### K8s Resource 的 ExportTo

由于 K8s 的 Resource 不受 istio 控制，没有提供 exportTo 的语义，所以需要通过添加 annotation 的方式来使用。

目前支持在 K8s Service 上通过加 `networking.istio.io/exportTo` annotation 来声明当前 Service 的暴露范围。

目前的值应该仅支持 `.` 和 `*` 和 `~`。默认是 `*`，通过配置成 `.` ，可以避免将该 Service 的配置分发到其他 namespace 下的 sidecar。如果配置成 `~`，则会完全被 istio 忽略掉。
