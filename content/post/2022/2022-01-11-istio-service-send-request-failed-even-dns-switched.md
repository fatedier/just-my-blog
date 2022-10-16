---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-01-11
title: "Istio 服务请求外部域名持续出错，切换 DNS 后也无法恢复"
url: "/2022/01/11/istio-service-send-request-failed-even-dns-switched"
---

假设 K8s 集群内的服务会以串行的方式不断请求一个外部域名的 80 端口。这个域名通过 DNS 解析到一个固定 IP。当某个时间段，这个 IP 上绑定的服务突然不可用，端口无法访问。内部服务会持续的得到 HTTP 503 的响应。

此时即使将这个域名的 DNS 切到一个正常的 IP，服务仍然会得到持续的 503 错误，一直无法恢复。

<!--more-->

在社区提了 issue: https://github.com/istio/istio/issues/36768

### 原因分析

#### 本地模拟

在 K8s 中启动一个测试的 Go 服务并接入 istio，会以串行的方式持续的向 `test.com` 发送 HTTP 请求，使用默认的 Go HTTP Transport。

在容器中执行 `echo '4.4.4.4 test.com' > /etc/hosts` 修改 `test.com` 的解析到 4.4.4.4，由于该 IP 网络不通，所以永远都是连接超时。

在 istio 容器中通过 `ss -antp|grep 4.4.4.4` 观察连接状态。

```
ESTAB     0       0                 172.17.0.3:35900              4.4.4.4:80
SYN-SENT  0       1                 172.17.0.3:38418              4.4.4.4:80     users:(("envoy",pid=16,fd=44))
```

172.17.0.3:38418 是 envoy 到对端的连接，处于 SYN-SENT 状态，因为 sync 包无法到达 4.4.4.4，所以永远不会有回应。

172.17.0.3:35900 是 go 应用到 envoy 的连接，由于是通过 iptables 劫持，这里的 destination 地址还是 4.4.4.4。状态是 ESTAB，说明 go 到 envoy 的连接仍然保持着。

1s 后

```
ESTAB     0       0                 172.17.0.3:35900              4.4.4.4:80
```

由于本地设置的 envoy 连接超时是 1s，所以 envoy 对外的连接断开了，但是 go 应用到 envoy 的连接仍然保持着。

之后 envoy 会发起一个到 4.4.4.4 的新的连接，但是仍然失败，一直循环。

期间，go 应用每隔 1s 会收到 HTTP 503 的响应。

执行 `echo '5.5.5.5 test.com' > /etc/hosts`，切换 DNS。

通过 `ss -antp|grep 5.5.5.5` 观察连接状态，发现连接并没有切换到新的 IP，而是仍然在不停的往 4.4.4.4 建立连接。

#### 初步分析

从本地模拟的结果来看，基本上可以看出问题的主要原因是，envoy 在将应用请求外部 80 端口域名的流量看做了 HTTP 协议来处理，自身是一个代理，所以当连接 Upstream 失败后，并没有断开和 go 应用的连接，而是返回了 503。

Go 应用收到 503 后，并不会断开连接，由于连接复用，如果在 IdleConnTimeout 时间段内，一直有请求的话，和 envoy 之间的连接就一直不会断开。

对 istio 来说，请求内部服务和外部域名是有区别的。内部服务会有一套内部的服务发现机制，请求内部服务，其 DNS 解析得到的 IP 并不会影响到 envoy 对外请求的 IP。但是对外部域名来说，envoy 并不会做服务发现，而是通过 iptables 劫持后，拿到原先的目标地址去建立连接。那么只要 go 应用和 envoy 之间的连接不断开，后续在这个连接上有新的请求的话，仍然会发送到原来 go 应用解析到的那个 IP。

#### 深入分析

通过 istio 的调试工具进行进一步的分析。

这里先说明一下几个 envoy 相关的概念:

* Listener: 监听器，绑定在指定的端口上接收连接，并且通过 Listener Filter Chain，支持一些协议探测等的 Filter 处理。
* HTTP Connection Manager: 一个特殊的 Listener Filter，用于处理 HTTP 请求，并且支持多种 HTTP Filter。
* TCPProxy: 一个 Listener Filter，处理 TCP 流量。
* Route: 一个特殊的 HTTP Filter，根据配置的路由规则，将请求路由到对应的 Cluster。
* Cluster: 对应 Upstream 服务，Endpoint 集合。

##### Listener

通过命令查看 Listener 信息 `istioctl proxy-config listeners istio-test-client-f7c785975-qst9q`

```
0.0.0.0        80    Trans: raw_buffer; App: HTTP                                                                    Route: 80
0.0.0.0        80    ALL                                                                                             PassthroughCluster
```

可以看出，80 端口上有两个 Listener，HTTP 协议的会被 Route `80` 处理，其他协议则会被路由到 `PassthroughCluster` 这个 cluster。

通过 `istioctl proxy-config listeners istio-test-client-f7c785975-qst9q -o json` 查看更详细一些的信息。

```
{
    "name": "0.0.0.0_80",
    "address": {
        ...
    },
    "filterChains": [
        {
            "filterChainMatch": {
                "transportProtocol": "raw_buffer",
                "applicationProtocols": [
                    "http/1.0",
                    "http/1.1",
                    "h2c"
                ]
            },
            "filters": [
                {
                    "name": "envoy.filters.network.http_connection_manager",
                    "typedConfig": {
                        "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                        "statPrefix": "outbound_0.0.0.0_80",
                        "rds": {
                            ...
                            "routeConfigName": "80"
                        },
                        "httpFilters": ...
                    }
                }
            ]
        }
    ],
    "defaultFilterChain": {
        "filterChainMatch": {},
        "filters": [
            ...
            {
                "name": "envoy.filters.network.tcp_proxy",
                "typedConfig": {
                    "@type": "type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy",
                    "statPrefix": "PassthroughCluster",
                    "cluster": "PassthroughCluster"
                    ...
                }
            }  
        ]
    },
    ...
}
```

省略了其中大部分不重要的配置。

可以看出，80 端口的 listener，有一个 defaultFilterChain，filterChainMatch 为空，说明匹配所有流量，并且 filters 中包括一个 `tcp_proxy` 的 filter，用于代理 TCP 连接。可见这个 defaultFilterChain 就是用于兜底的，如果没有匹配其他的 FilterChain，则默认都以 TCP 流量来处理。

再看 filterChains 中的内容，filterChainMatch 中指定了 applicationProtocols，包含了 HTTP 的各种协议，说明这个 FilterChains 是用于处理 HTTP 请求的。`http_connection_manager` 这个特殊的 Filter 会将 HTTP 请求路由到 `routeConfigName: 80`。

##### Route

通过命令 `istioctl proxy-config route istio-test-client-f7c785975-qst9q -o json` 查找 route name 80 的详细信息。

```
{
    "name": "80",
    "virtualHosts": [
        {
            "name": "allow_any",
            "domains": [
                "*"
            ],
            "routes": [
                {
                    "name": "allow_any",
                    "match": {
                        "prefix": "/"
                    },
                    "route": {
                        "cluster": "PassthroughCluster",
                        "timeout": "0s",
                        "maxGrpcTimeout": "0s"
                    }
                }
            ]
        },
        {
            "name": "ingress-nginx-controller.ingress-nginx.svc.cluster.local:80",
            "domains": [
                "ingress-nginx-controller.ingress-nginx.svc.cluster.local",
                ...
            ],
            "routes": [
                {
                    "name": "default",
                    "match": {
                        "prefix": "/"
                    },
                    "route": {
                        "cluster": "outbound|80||ingress-nginx-controller.ingress-nginx.svc.cluster.local",
                        "timeout": "0s"
                        ...
                    },
                    ...
                }
            ]
        }
    }
}
```

可以看出 name 80 的 Route 中的 virtualHosts 是一个数组，进入这个 route 的请求，会根据请求的 host 匹配对应的规则，然后路由到对应的 cluster。例如，如果 host 是 `ingress-nginx-controller.ingress-nginx.svc.cluster.local`，则会被路由到 cluster `outbound|80||ingress-nginx-controller.ingress-nginx.svc.cluster.local`。这个 cluster 中的 endpoint 会通过 eds 从 istiod 动态获取。

那么 allow_any 这个特殊的规则，可以认为是一个兜底的规则，如果请求的 host 和其他所有 route 的 domain 都不匹配，则会匹配到 allow_any 的规则，会被路由到 PassthroughCluster 这个 cluster。

##### Cluster

通过命令 `istioctl proxy-config cluster istio-test-client-f7c785975-qst9q -o json` 查找 PassthroughCluster 的详细信息。

```
{
    "name": "PassthroughCluster",
    "type": "ORIGINAL_DST",
    "connectTimeout": "1s",
    "lbPolicy": "CLUSTER_PROVIDED",
    "circuitBreakers": {
        ...
    },
    "typedExtensionProtocolOptions": {
        ...
    },
    "filters": [
        {
            "name": "istio.metadata_exchange",
            "typedConfig": {
                ...
            }
        }
    ]
}
```

可以看到这个 Cluster 比较简单，核心的配置就在于 type 为 `ORIGINAL_DST`，表示使用 TCP 连接原来的目的地址作为 upstream 地址。

##### 结论

从上述配置中，可以发现，核心的问题是， 80 端口的 listener 配置了 HTTP 的协议探测，并且访问外部域名的 80 端口会匹配 HTTP 协议的 FilterChain 之后交由 HTTP Connection Manager 处理，从而并没有完全遵循 TCP 代理的逻辑，当 Upstream 连接断开后，仍然保持了和 Downstream 的连接。

尝试访问外部域名的 8080 端口，则不会出现同样的问题。因为内部服务并没有监听 8080 端口，所以 istio 并不会为 8080 端口创建 listener。所以到 8080 端口的流量会直接被当做 TCP 流量走 TCP Proxy 的 Filter 来处理。

但是内部服务通常都有暴露 HTTP 协议的 80 端口，所以 istio 会创建 80 端口的 listener ，探测到是 HTTP 协议之后，根据 host 来做内部服务的路由。因为要通过 host 来判断是否是内部服务，所以必须要经过 HTTP Connection Manager，就没办法走 TCP Proxy，从而导致了这个问题。

### 解决方案

#### ServiceEntry

通过创建 ServiceEntry，将外部域名声明为一个服务，通过 DNS 来做服务发现，从而让 envoy 重新连接时，不使用 `ORIGINAL_DST`，而是连接通过 DNS 获取到的 IP。

```
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: external-svc
spec:
  hosts:
  - test.com
  location: MESH_EXTERNAL
  ports:
  - number: 80
    name: http
    protocol: HTTP
  resolution: DNS
```

问题:

* DNS 解析的方式，不支持将 hosts 设置为泛域名，需要预先配置好所有的外部域名，非常麻烦和难以维护。
* istio 会让所有下发了此配置的 envoy 进行频繁的 DNS 解析来更新服务发现的结果，默认为 5s，可以调整。但是如果 host 很多，且 Pod 也很多，仍然可能给 coredns 造成一定的压力。当域名解析不存在时，这个问题会放大，https://github.com/istio/istio/issues/35603 。
* 对于请求的 url host 和 HTTP header Host 不同的请求来说，将会出错，因为 envoy 不再使用 connect 的目的 IP 来进行连接。
* 这样的 ServiceEntry，会增加 cluster，route，endpoint 的配置，对配置下发也会产生压力。

#### 限制需要劫持的 IP

通过 `values.global.proxy.includeIPRanges` 配置需要劫持的 IP 段，只对内部 IP 段进行劫持，这样外部请求就不经过 envoy，就不会有类似的问题。

`traffic.sidecar.istio.io/includeOutboundIPRanges` 或 `traffic.sidecar.istio.io/excludeOutboundIPRanges` pod annotation 可以只针对部分 pod 进行灰度。

但是这个方案，维护起来比较复杂，因为在云厂商的网络架构下，集群 Pod 网段可能和其他云资源有冲突。如果划分的太细，维护成本又很高，而且以后都需要记得根据网段来及时做调整。一旦出现误差，可能导致集群流量的不稳定。

且这样做也丧失了对于外部 HTTP 请求的监控和管理。

#### Envoy 优化(TODO)

这个问题比较难在 istio 层面完美解决，必须要 envoy 支持。

对于经过 HTTP Connection Manager 路由到 PassthroughCluster 的连接，能够将 Downstream connection 和 Upstream connection 完全关联，当 Downstream connection 断开后，Upstream connection 会断开，反之亦然。

待 envoy 社区解决，相关的一些 issue，周期可能较长。

https://github.com/envoyproxy/envoy/issues/19458

https://github.com/envoyproxy/envoy/issues/12370

### 总结

ServiceEntry 的方案短期内更具有可实施性，对部分重要的域名可以采用这种方式来避免发生故障。

限制劫持 IP 段的方案风险较高，因为涉及到 iptables，指定过多的 IP 段也不是很合适，但是如果要将某一个明确的 IP 段排除的话也是可以考虑的。只是会丧失对外部 HTTP 请求的管控和监控告警的能力。

Envoy 优化可能是更完美的解决方式，但是感觉难度较大，不确定社区能否解决。
