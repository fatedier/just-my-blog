---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-06-01
title: "Istio 控制面配置推送分析与优化"
url: "/2022/06/01/istio-control-plane-config-push-optimization"
---

Istio 主要分为控制面和数据面，控制面负责从数据源（通常是 K8s）获取变更内容，渲染成 envoy 使用的配置文件，推送到各个 Sidecar 和 Gateway 节点。

如果对 K8s 比较熟悉的话，可以和 K8s controller 类比，只是需要计算的内容更多。

<!--more-->

### 基本架构

![architecture](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-architecture.jpg)

Istiod 中和配置生成和推送相关的功能是无状态的，可以支持水平扩展。（有一部分和证书相关的逻辑是通过 leader election 选主后由单个节点负责处理）

Istiod 会通过 List-Watch 从 kube-apiserver 获取到相关资源的变更。例如 Service, Endpoint, VirtualService, DestinationRule, ServiceEntry, Gateway。

Sidecar 是指和业务 Pod 部署在一起的 pilot-agent 加上 envoy 的容器。envoy 会通过 `istiod.istio-system` 这个 service 连接到 Istiod 的其中一个实例，创建一个 GRPC stream 请求。

Gateway 和 Sidecar 类似，区别就在于没有业务容器，只有单独的 envoy 容器，生成的配置会考虑到 Gateway 这个K8s 资源。

后面会将 Sidecar 和 Gateway 统称为 node，是 istiod 需要推送配置的节点。

每个 Istiod 会负责将计算后生成的配置通过 GRPC stream 实时推送给连接上来的 node。

### xDS 概念说明

Envoy 的配置更新协议被称作 xDS 协议。DS 表示 Discovery Service，意思就是各种资源的发现服务。

简而言之，就是 envoy 会按照固定的交互协议和 API 从其他数据源拉取各个资源的配置信息。具体的交互协议也没必要了解的特别深入，只需要关注有哪些重要的资源及其作用就可以了。

xDS 现在主要包含 LDS, RDS, CDS, EDS。

Istio 的推送还用到了一个 ADS(Aggregated Discovery Service) 的概念，主要目的是为了保证对各种 DS 推送的顺序。比如创建了一个路由规则，会将请求路由到一个指定的 cluster，那么如果先推送了 RDS，在这段时间内，请求会由于找不到对应的 Cluster，而失败。所以需要按照一定的顺序来进行更新，比如需要先更新 CDS，再更新 RDS。

下面主要用 istio-test-server 这个测试服务用于简单说明 istio 的配置是如何映射到 envoy 的配置以及如何生效的。

istio-test-server 的一些 K8s 资源:

```yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    app: istio-test-server
  name: istio-test-server
  namespace: infra
spec:
  ports:
  - name: http-8000
    port: 8000
    protocol: TCP
    targetPort: 8000
  selector:
    app: istio-test-server
  type: ClusterIP
  
---

apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  labels:
    app: istio-test-server
    type: internal
  name: istio-test-server
  namespace: infra
spec:
  hosts:
  - istio-test-server
  http:
  - match:
    - port: 8000
    route:
    - destination:
        host: istio-test-server
        port:
          number: 8000
```

#### LDS

Listener Discovery Service

监听器配置，在 envoy 中，需要为每一个端口创建一个对应的 listener。envoy 会根据连接的端口，进入到不同的 listener filter chain 进行处理。

例如 8000 端口的 listener 配置如下:

```yaml
- accessLog:
  ...
  address:
    socketAddress:
      address: 0.0.0.0
      portValue: 8000
  bindToPort: false
  continueOnListenerFiltersTimeout: true
  defaultFilterChain:
    filterChainMatch: {}
    filters:
    - name: istio.stats
      typedConfig:
        '@type': type.googleapis.com/udpa.type.v1.TypedStruct
        typeUrl: type.googleapis.com/envoy.extensions.filters.network.wasm.v3.Wasm
        ...
    - name: envoy.filters.network.tcp_proxy
      typedConfig:
        '@type': type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
        ...
        cluster: PassthroughCluster
        idleTimeout: 0s
        statPrefix: PassthroughCluster
    name: PassthroughFilterChain
  filterChains:
  - filterChainMatch:
      applicationProtocols:
      - http/1.0
      - http/1.1
      - h2c
      transportProtocol: raw_buffer
    filters:
    - name: envoy.filters.network.http_connection_manager
      typedConfig:
        '@type': type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
        accessLog:
        ...
        httpFilters:
        - name: istio.metadata_exchange
          ...
        - name: istio.alpn
          ...
        - name: envoy.filters.http.cors
          typedConfig:
            '@type': type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors
        - name: envoy.filters.http.fault
          typedConfig:
            '@type': type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault
        - name: istio.stats
          typedConfig:
            '@type': type.googleapis.com/udpa.type.v1.TypedStruct
            typeUrl: type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
            ......
        - name: envoy.filters.http.router
          typedConfig:
            '@type': type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
        normalizePath: true
        pathWithEscapedSlashesAction: KEEP_UNCHANGED
        rds:
          configSource:
            ads: {}
            initialFetchTimeout: 0s
            resourceApiVersion: V3
          routeConfigName: "8000"
        statPrefix: outbound_0.0.0.0_8000
        streamIdleTimeout: 0s
        tracing:
          clientSampling:
            value: 100
          customTags:
          ...
        upgradeConfigs:
        - upgradeType: websocket
        useRemoteAddress: false
  listenerFilters:
  - name: envoy.filters.listener.tls_inspector
    typedConfig:
      '@type': type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector
  - name: envoy.filters.listener.http_inspector
    typedConfig:
      '@type': type.googleapis.com/envoy.extensions.filters.listener.http_inspector.v3.HttpInspector
  listenerFiltersTimeout: 0s
  name: 0.0.0.0_8000
  trafficDirection: OUTBOUND
```

几个重要的点:

```yaml
address:
  socketAddress:
    address: 0.0.0.0
    portValue: 8000
name: 0.0.0.0_8000
trafficDirection: OUTBOUND
```

监听器的端口是 8000，流量方向是出方向，表示如果是连接外部服务的 8000 端口，则会匹配到这个 listener。

`listenerFilters` 有两个，`TlsInspector` 和 `HttpInspector`，这两个 Filter 是用于协议探测，如果探测是 TLS 或者 HTTP 协议，则会将解析到的一些元数据写入 context 中，可以被后面的 FilterChain 中的其他 Filter 以及在 FilterChainMatch 中使用。

`filterChains` 是一个数组，会按照顺序匹配每一个 `filterChainMatch`，如果匹配成功，则执行对应的 `filters`，否则匹配下一个，如果都不匹配，则进入到 `defaultFilterChain`。

```yaml
filterChainMatch:
  applicationProtocols:
  - http/1.0
  - http/1.1
  - h2c
  transportProtocol: raw_buffer
```

上面的配置只有一个 filterChainMatch 用于匹配 HTTP 协议。在 envoy 中 HTTP 是一等公民，`http_connection_manager` 也是一个非常特殊的 filter（基本可以认为很多逻辑都特殊对待了），可以继续指定 http filters。

http filters 则是一些处理 HTTP 请求的插件。

filters 并不一定会对请求做修改，有一些 filter 是专门用于解析请求，然后将解析后的数据写入 context 中，供后续的 filters 来使用。

`istio.metadata_exchange` 用于获取下游请求的元数据，在遥测中上报数据时之所以能知道是哪个服务请求哪个服务就是通过这个插件实现。

`istio.alpn` 会根据服务声明的协议设置 ALPN 信息。

`envoy.filters.http.cors` 用于 cors 的校验逻辑。

`envoy.filters.http.fault` 用于故障注入。

`istio.stats` 用于生成遥测数据。

`envoy.filters.http.router` 负责路由，根据路由规则将请求路由到对应的 cluster。router 的配置通过 RDS 获取。

```yaml
rds:
  configSource:
    ads: {}
    initialFetchTimeout: 0s
    resourceApiVersion: V3
  routeConfigName: "8000"
```

rds 的配置表示 `envoy.filters.http.router` 关联的配置名称为 `8000`。

`defaultFilterChain` 在 istio 中一般就配置一个 `TcpProxy` 的 filter，用于在四层透传流量。需要注意的是这里指定了目标 Cluster 是 `PassthroughCluster`，这个会在 CDS 中说明。

#### RDS

Route Discovery Service

路由配置，针对 HTTP 协议。负责将 HTTP 请求根据 host, path, header 等路由到指定的 Cluster。并且可以额外指定一些超时以及重试规则。

下面是 name 为 `8000` 的 route 配置。

```yaml
- name: "8000"
  validateClusters: false
  virtualHosts:
  - domains:
    - '*'
    includeRequestAttemptCount: true
    name: allow_any
    routes:
    - match:
        prefix: /
      name: allow_any
      route:
        cluster: PassthroughCluster
        maxGrpcTimeout: 0s
        timeout: 0s
  - domains:
    - istio-test-server.infra.svc.cluster.local
    - istio-test-server.infra.svc.cluster.local:8000
    - istio-test-server
    - istio-test-server:8000
    - istio-test-server.infra.svc
    - istio-test-server.infra.svc:8000
    - istio-test-server.infra
    - istio-test-server.infra:8000
    - 172.18.7.189
    - 172.18.7.189:8000
    includeRequestAttemptCount: true
    name: istio-test-server.infra.svc.cluster.local:8000
    routes:
    - decorator:
        operation: istio-test-server.infra.svc.cluster.local:8000/*
      match:
        caseSensitive: true
        prefix: /
      metadata:
        filterMetadata:
          istio:
            config: /apis/networking.istio.io/v1alpha3/namespaces/infra/virtual-service/istio-test-server
      route:
        cluster: outbound|8000||istio-test-server.infra.svc.cluster.local
        maxGrpcTimeout: 0s
        retryPolicy:
          hostSelectionRetryMaxAttempts: "5"
          numRetries: 2
          retryHostPredicate:
          - name: envoy.retry_host_predicates.previous_hosts
          retryOn: connect-failure,refused-stream
        timeout: 0s
  - domains:
    ...
```

`8000` 这个 route 配置中包括了所有声明了这个端口并且 protocol 是 HTTP 的 service/virtualservice 。

`virtualHosts` 是一个定义了不同的 domain 的路由规则的数组。

`domain` 的匹配比较特殊，应该是索引查找，不是顺序匹配。

先根据 HTTP 请求的 Host 匹配了 domain 了之后进入到对应的 virtualHost 的规则。像 `istio-test-server` 这个服务，istio 会把所有可能的 Host 都配置进去，`172.18.7.189` 是 service 的 ClusterIP。

后续的 `match-route` 对，会按照顺序匹配所有的 match 规则，匹配了之后进入对应的 route 逻辑。

route 中指定了要路由到的 Cluster，istio-test-server 对应的是 cluster 是 `outbound|8000||istio-test-server.infra.svc.cluster.local`。

对不同的 route 对象，可以指定不同的 timeout 和 retryPolicy。

注意到还有一个 `allow_any` 的 virtualHost，domains 是 `*`，用于兜底。如果和 8000 端口的连接，协议是 HTTP，但是目标 Host 又没有在 Mesh 内声明，则会转发到 `PassthroughCluster` 这个 Cluster。之前 `TCPProxy` filter 也是转发到这个 Cluster。

#### CDS

luster Discovery Service

Cluster 在 envoy 中类似于服务的概念，是一组 endpoint 的集合。

```yaml
- circuitBreakers:
    thresholds:
    - maxConnections: 4294967295
      maxPendingRequests: 4294967295
      maxRequests: 4294967295
      maxRetries: 4294967295
      trackRemaining: true
  commonLbConfig:
    localityWeightedLbConfig: {}
  connectTimeout: 2s
  edsClusterConfig:
    edsConfig:
      ads: {}
      initialFetchTimeout: 0s
      resourceApiVersion: V3
    serviceName: outbound|8000||istio-test-server.infra.svc.cluster.local
  filters:
  - name: istio.metadata_exchange
    typedConfig:
      '@type': type.googleapis.com/envoy.tcp.metadataexchange.config.MetadataExchange
      protocol: istio-peer-exchange
  lbPolicy: LEAST_REQUEST
  name: outbound|8000||istio-test-server.infra.svc.cluster.local
  transportSocketMatches:
  - match:
      tlsMode: istio
    name: tlsMode-istio
    transportSocket:
      name: envoy.transport_sockets.tls
      typedConfig:
        '@type': type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
        ...
        sni: outbound_.8000_._.istio-test-server.infra.svc.cluster.local
  - match: {}
    name: tlsMode-disabled
    transportSocket:
      name: envoy.transport_sockets.raw_buffer
  type: EDS
```

Cluster 的类型分为几种:

`EDS` 的 endpoint 由 EDS 动态推送。

`STATIC` 的 endpoint 由用户静态配置。

`STRICT_DNS`, `LOGICAL_DNS` 通过定期的 DNS 解析获取所有的 IP 地址。

`ORIGINAL_DST` 是比较特殊的类型，连接在四层的目标 IP 是什么，这里的 upstream endpoint 的 IP 就是什么。一般用于透传流量的场景。

`circuitBreakers` 用于配置一些限流功能。

`commonLbConfig` 和 `lbPolicy` 用于配置负载均衡相关的功能。

`edsClusterConfig` 指定要关联的 EDS 的 service name。

#### EDS


int Discovery Service

```yaml
- addedViaApi: true
  circuitBreakers:
    thresholds:
    ...
  hostStatuses:
  - address:
      socketAddress:
        address: 172.17.15.27
        portValue: 8000
    healthStatus:
      edsHealthStatus: HEALTHY
    locality:
      region: cn-shanghai
      zone: cn-shanghai-g
    stats:
    ...
    weight: 1
  name: outbound|8000||istio-test-server.infra.svc.cluster.local
  observabilityName: outbound|8000||istio-test-server.infra.svc.cluster.local
```

K8s 中就是每个 Pod 的一些信息，IP，端口等等，会在 CDS 中被使用。

### 推送流程

#### 流程图

![flow](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-flow.jpg)

#### 推送顺序

* 必须始终先推送 CDS 更新（如果有）。
* EDS 更新（如果有）必须在相应集群的 CDS 更新后到达。
* LDS 更新必须在相应的 CDS/EDS 更新后到达。
* 与新添加的监听器相关的 RDS 更新必须在最后到达。
* 最后，删除过期的 CDS 集群和相关的 EDS 端点（不再被引用的端点）。

所以 Istio 中推送的顺序是 CDS, EDS, LDS, RDS。

对我们来说，LDS 和 RDS 的变更推送及时性的要求一般，慢一点也影响不大，就是生效慢一些。但是 EDS 的推送涉及到服务实例的变更，会比较频繁，如果推送不及时，可能会导致请求发送到错误或者不存在的节点，导致请求出错。

### 优化点

#### pprof

![pprof](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof.jpg)

通过 pprof cpu 数据，可以看出核心的资源消耗都在 pushXds 上，主要就是各个资源的配置生成的计算。而其中接近 60% 是耗费在了 RDS 配置的计算上。

之所以这么耗费资源，主要还是 Istio 中这些配置的计算有大量的循环，例如很多地方会存在泛域名匹配，需要 N * N 的计算去查找匹配的资源。这个从 mapiternext 的 cpu 消耗占比可以看出来。

另外，在循环中，很多内容每一次循环都会重复的计算，代码中的一些额外增加耗时的写法也会被放大。

整个生成的 envoy 配置中也会创建大量的临时对象，导致在内存分配和 GC 上都会有较大的资源消耗。

#### Istio 配置生成的优化

从 pprof 的结果来看，大致上可以看出能优化的核心的几点:

1. 减少循环次数。
2. 由于循环次数很多，需要降低每一次循环内的开销。
3. 尽量复用对象。

下面举一些典型的例子作为示例说明:

##### 减少循环次数

![pprof-iterate](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof-iterate.jpg)

从图中可以看出来，mapiternext 占用了不少 cpu 资源，说明 selectVirtualServices 这个函数的循环次数可能非常多。

对应的代码

```go
// selectVirtualServices 会遍历出匹配 service 的所有的 vs
// 例如 service host 是 istio-test-server.infra，那么 vs host 也是 istio-test-server.infra 就匹配
// 需要考虑到泛域名的情况
func selectVirtualServices(virtualServices []config.Config, servicesByName map[host.Name]*model.Service) []config.Config {
    out := make([]config.Config, 0)
    for _, c := range virtualServices {
        rule := c.Spec.(*networking.VirtualService)
        var match bool

        // Selection algorithm:
        // virtualservices have a list of hosts in the API spec
        // if any host in the list matches one service hostname, select the virtual service
        // and break out of the loop.
        for _, h := range rule.Hosts {
            // TODO: This is a bug. VirtualServices can have many hosts
            // while the user might be importing only a single host
            // We need to generate a new VirtualService with just the matched host
            if servicesByName[host.Name(h)] != nil {
                match = true
                break
            }

            for svcHost := range servicesByName {
                if host.Name(h).Matches(svcHost) {
                    match = true
                    break
                }
            }

            if match {
                break
            }
        }

        if match {
            out = append(out, c)
        }
    }

    return out
}
```

整体逻辑其实非常简单，两层循环，遍历 vs host，找到其他与 service host 匹配的 vs 添加到数组中返回。

如果都是 FQDN host，直接 map 查找，一层循环就解决了。但是由于 host 中可以含有泛域名。导致需要两层遍历。

注意，这里传入的 service 是监听在指定端口上的 service，而 vs 是全量的 vs。所以每一个端口上的 service 都要和所有的 vs 循环计算一遍。另外，推送给每一个节点的时候需要再重复计算一遍。

但是真实的场景中，使用泛域名的 service 和 vs 并不多，大部分都是 FQDN host，所以其实大量的循环计算是在浪费。

优化后，事先把泛域名的 service host 保存下来，在之后的循环中，如果 vs 的 host 也是 FQDN host，则只需要去匹配泛域名的 service host。由于这个 case 才是主要的使用场景，所以实际优化的效果会非常好，可以减少掉大部分的循环次数。

```go
func selectVirtualServices(virtualServices []config.Config, servicesByName map[host.Name]*model.Service) []config.Config {
    out := make([]config.Config, 0)
    // Pre-compute wildcarded service hosts to reduce loop count.
    wildCardedSvcHosts := []host.Name{}
    for svcHost := range servicesByName {
        if svcHost.IsWildCarded() {
            wildCardedSvcHosts = append(wildCardedSvcHosts, svcHost)
        }
    }

    for i := range virtualServices {
        rule := virtualServices[i].Spec.(*networking.VirtualService)
        var match bool

        // Selection algorithm:
        // virtualservices have a list of hosts in the API spec
        // if any host in the list matches one service hostname, select the virtual service
        // and break out of the loop.
        for _, h := range rule.Hosts {
            // TODO: This is a bug. VirtualServices can have many hosts
            // while the user might be importing only a single host
            // We need to generate a new VirtualService with just the matched host
            if servicesByName[host.Name(h)] != nil {
                match = true
                break
            }

            if host.Name(h).IsWildCarded() {
                for svcHost := range servicesByName {
                    if host.Name(h).Matches(svcHost) {
                        match = true
                        break
                    }
                }
            } else {
                for _, svcHost := range wildCardedSvcHosts {
                    if host.Name(h).Matches(svcHost) {
                        match = true
                        break
                    }
                }
            }

            if match {
                break
            }
        }

        if match {
            out = append(out, virtualServices[i])
        }
    }

    return out
}
```

在我们当前的场景下，这个函数的资源消耗只有原来的 1/9 左右。

![pprof-iterate-after](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof-iterate-after.jpg)

##### 降低每一次循环内的开销

![pprof-convert](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof-convert.jpg)

retry.CovertPolicy 也耗费了不少的资源，看上去让人比较费解，大部分的消耗还在 retry.parseRetryOn 上。

代码:

```go
// 给所有没有对应 VirtualService 的 service 创建默认的 VirtualHosts
func buildSidecarVirtualHostsForService(
    serviceRegistry map[host.Name]*model.Service,
    hashByService map[host.Name]map[int]*networking.LoadBalancerSettings_ConsistentHashLB,
    mesh *meshconfig.MeshConfig,
) []VirtualHostWrapper {
    out := make([]VirtualHostWrapper, 0)
    for _, svc := range serviceRegistry {
        for _, port := range svc.Ports {
            if port.Protocol.IsHTTP() || util.IsProtocolSniffingEnabledForPort(port) {
                cluster := model.BuildSubsetKey(model.TrafficDirectionOutbound, "", svc.Hostname, port.Port)
                traceOperation := util.TraceOperation(string(svc.Hostname), port.Port)
                // 创建默认的 outbound 的 Route
                httpRoute := BuildDefaultHTTPOutboundRoute(cluster, traceOperation, mesh)

                // if this host has no virtualservice, the consistentHash on its destinationRule will be useless
                if hashByPort, ok := hashByService[svc.Hostname]; ok {
                    hashPolicy := consistentHashToHashPolicy(hashByPort[port.Port])
                    if hashPolicy != nil {
                        httpRoute.GetRoute().HashPolicy = []*route.RouteAction_HashPolicy{hashPolicy}
                    }
                }
                out = append(out, VirtualHostWrapper{
                    Port:     port.Port,
                    Services: []*model.Service{svc},
                    Routes:   []*route.Route{httpRoute},
                })
            }
        }
    }
    return out
}

// BuildDefaultHTTPOutboundRoute builds a default outbound route, including a retry policy.
func BuildDefaultHTTPOutboundRoute(clusterName string, operation string, mesh *meshconfig.MeshConfig) *route.Route {
    // Start with the same configuration as for inbound.
    out := BuildDefaultHTTPInboundRoute(clusterName, operation)

    // Add a default retry policy for outbound routes.
    // 由于是默认的 Route，直接用全局的 mesh 级别的 retry policy
    out.GetRoute().RetryPolicy = retry.ConvertPolicy(mesh.GetDefaultHttpRetryPolicy())
    return out
}

// 将 istio 中的 HTTPRetry 转化为对应的 envoy 中使用的 RetryPolicy
func ConvertPolicy(in *networking.HTTPRetry) *route.RetryPolicy {
    out := DefaultPolicy()
    out.NumRetries = &wrappers.UInt32Value{Value: uint32(in.Attempts)}

    if in.RetryOn != "" {
        // Allow the incoming configuration to specify both Envoy RetryOn and RetriableStatusCodes. Any integers are
        // assumed to be status codes.
        out.RetryOn, out.RetriableStatusCodes = parseRetryOn(in.RetryOn)
        // If user has just specified HTTP status codes in retryOn but have not specified "retriable-status-codes", let us add it.
        if len(out.RetriableStatusCodes) > 0 && !strings.Contains(out.RetryOn, "retriable-status-codes") {
            out.RetryOn += ",retriable-status-codes"
        }
    }
    
    ......
    return out
}

// 解析 Istio VirtualService 中的 retryOn 字段为 envoy 中的 retryOn 和重试 code 列表
// 主要是字符串相关的操作，由于循环次数较多，实际占用的资源也不少
func parseRetryOn(retryOn string) (string, []uint32) {
    codes := make([]uint32, 0)
    tojoin := make([]string, 0)

    parts := strings.Split(retryOn, ",")
    for _, part := range parts {
        part = strings.TrimSpace(part)
        if part == "" {
            continue
        }

        // Try converting it to an integer to see if it's a valid HTTP status code.
        i, err := strconv.Atoi(part)

        if err == nil && http.StatusText(i) != "" {
            codes = append(codes, uint32(i))
        } else {
            tojoin = append(tojoin, part)
        }
    }

    return strings.Join(tojoin, ","), codes
}
```

这里核心的问题是，在每一次循环中 `out.GetRoute().RetryPolicy = retry.ConvertPolicy(mesh.GetDefaultHttpRetryPolicy())`，这行代码的执行结果其实并不会变化，每一次调用 retry.ConvertPolicy 去做计算比较多余，只需要在循环开始前计算一次，后面直接赋值即可。

但是由于不能复用同一个对象的指针，每一次还是要创建一个新的对象，所以只需要复用解析 retryOn 的结果即可，可以在 ConvertPolicy 函数入参增加 override 参数，如果 override 参数存在，则不需要重复计算，直接赋值。 (优化后的消耗降为原来的 1/5 左右)

实际上用 DeepCopy 更合适，但是由于这个类型没有 auto generate 的 DeepCopy 代码，用 reflect 的方式做 DeepCopy 性能并不好，在 retryOn 为空时，反而性能更差。

##### 尽量复用对象

![pprof-mallocgc](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof-mallocgc.jpg)

可以看出创建新对象和 GC 产生的开销其实占比很大。

在能够复用对象的前提下，需要尽量避免创建新的对象。由于支持 EnvoyFilter 的动态修改 config 的功能，不太确定这部分的代码实现逻辑，如果 EnvoyFilter 的 Patch 会改动原来的对象，不会 DeepCopy，那么很多对象也没法直接复用。否则，例如前面的 defaultRetryPolicy 的对象，没必要每一个 route 都创建一个。

也可以使用 sync.Pool 以及其他的对象池的方式来优化，但是成本较高，会影响到代码结构，增加心智负担。

#### Golang 常见的优化点

很多时候也不必过度优化，优先功能开发，在遇到瓶颈时再对出现瓶颈的部分有针对性的优化，可能综合成本更低。

##### 避免值拷贝

![pprof-duffcopy](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof-duffcopy.jpg)

```go
for _, vs := range r.VirtualServices {
        params = append(params, vs.Name+"/"+vs.Namespace)
}
```

这个函数里，r.VirtualService 并不是指针类型，而是 `[]config.Config`，每一次循环涉及到一次值拷贝，当这个结构体本身比较大时，影响会比较大。

建议修改为

```go
for index := range r.VirtualServices {
        params = append(params, r.VirtualServices[index].Name+"/"+r.VirtualServices[index].Namespace)
}
```

##### 避免 slice grow

![pprof-growslice](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof-growslice.jpg)

最基础的，当已知数组要插入的元素个数时，可以在 make slice 时通过指定 cap 来一次性分配好内存，避免后续 append 时再去不停的翻倍申请内存。不仅性能差，而且会有额外的内存消耗以及影响 GC。

```go
func BenchmarkTest1(b *testing.B) {
    arrs := make([]int64, 10000)
    for i := 0; i < b.N; i++ {
        out := make([]int64, 0)
        for _, v := range arrs {
            out = append(out, v)
        }
    }
}

func BenchmarkTest2(b *testing.B) {
    arrs := make([]int64, 10000)
    for i := 0; i < b.N; i++ {
        out := make([]int64, 0, len(arrs))
        for _, v := range arrs {
            out = append(out, v)
        }
    }
}
```

```
BenchmarkTest1-16          23138             52313 ns/op          357629 B/op         19 allocs/op
BenchmarkTest2-16          88789             13487 ns/op           81921 B/op          1 allocs/op
```

上面的例子很多人都会注意，但是在实际开发中，如果要插入的元素个数不确定，但是由于业务场景的原因，大部分情况下都接近固定的值时，也可以通过空间换时间，浪费一点内存，换取更高的效率。

例如要从所有 Endpoint 节点中过滤出所有健康的节点，大多数情况下，不健康的节点是少数，所以即使不能事先知道的元素个数，也可以先预分配和所有节点数量相当的内存空间。

```go
func FilterHealthyEndpoints(in []*Endpoint) []*Endpoint {
    out := make([]*Endpoint, 0)
    for _, v := range in {
        if !v.Healthy {
            continue
        }
        out = append(out, v)
    }
    return out
}

func FilterHealthyEndpoints2(in []*Endpoint) []*Endpoint {
    out := make([]*Endpoint, 0, len(in))
    for _, v := range in {
        if !v.Healthy {
            continue
        }
        out = append(out, v)
    }
    return out
}

func BenchmarkFilterHealthyEndpoints(b *testing.B) {
    arrs := make([]*Endpoint, 10000)
    for i := range arrs {
        healthy := true
        if i >= 100 && i < 200 {
            healthy = false
        }
        arrs[i] = &Endpoint{IP: "127.0.0.1", Healthy: healthy}
    }

    for i := 0; i < b.N; i++ {
        FilterHealthyEndpoints(arrs)
    }
}
```

```
BenchmarkFilterHealthyEndpoints-16          8967            121711 ns/op          357666 B/op         20 allocs/op
BenchmarkFilterHealthyEndpoints2-16        36163             33013 ns/op           81928 B/op          1 allocs/op
```

##### 字符串拼接

在有大量字符串拼接的场景下，可以用 strings.Builder 取代 string 之间的直接相加。

string 直接相加，每一次都需要分配一块新的内存空间然后将两个 string 的内存 copy 过去。

strings.Builder 内部维护了一个 []byte，在容量不足时会翻倍扩容。也可以通过 Grow(n int) 预分配内存。

```
func StringsAdd(str string, n int) string {
    out := ""
    for i := 0; i < n; i++ {
        out += str
    }
    return out
}

func StringsAdd2(str string, n int) string {
    var b strings.Builder
    for i := 0; i < n; i++ {
        b.WriteString(str)
    }
    return b.String()
}

func StringsAdd3(str string, n int) string {
    var b strings.Builder
    b.Grow(len(str) * n)
    for i := 0; i < n; i++ {
        b.WriteString(str)
    }
    return b.String()
}

func BenchmarkStringsAdd(b *testing.B) {
    for i := 0; i < b.N; i++ {
        StringsAdd("hello world", 1000)
    }
}
```

```
BenchmarkStringsAdd-16              1345            907935 ns/op         5829004 B/op        999 allocs/op
BenchmarkStringsAdd2-16           144880              8348 ns/op           46576 B/op         15 allocs/op
BenchmarkStringsAdd3-16           229389              5289 ns/op           12288 B/op          1 allocs/op
```

##### 避免 string 和 []byte 转换

![pprof-stringtoslicebyte](https://image.fatedier.com/pic/2022/2022-06-01-istio-control-plane-config-push-optimization-pprof-stringtoslicebyte.jpg)

尽量避免 `[]byte(str)` 这样的转换，会存在内存分配和拷贝。例如如果变量是 string 类型，在调用一些库函数的时候，如果有提供 WriteString 方法，优先调用，而不是调用 `Write([]byte(str))`。

在转换无法避免，且对性能有较高要求的场景下，可以用 unsafe.Pointer 避免内存分配。但是这个方法不安全，调用的runtime 的函数、结构体随时都有可能被修改。且由于新建的 []byte 和 string 共用了内存，新建的 []byte 的内容只能只读使用，不能被修改。

```go
func doNothing(in []byte) {
}

func s2b(s string) (b []byte) {
    bh := (*reflect.SliceHeader)(unsafe.Pointer(&b))
    sh := (*reflect.StringHeader)(unsafe.Pointer(&s))
    bh.Data = sh.Data
    bh.Cap = sh.Len
    bh.Len = sh.Len
    return b
}

func String2Slice(strs []string) {
    for _, str := range strs {
        doNothing([]byte(str))
    }
}

func String2Slice2(strs []string) {
    for _, str := range strs {
        doNothing(s2b(str))
    }
}

func BenchmarkString2Slice(b *testing.B) {
    strs := make([]string, 0, 1000)
    for i := 0; i < 1000; i++ {
        strs = append(strs, "hello")
    }
    for i := 0; i < b.N; i++ {
        String2Slice(strs)
    }
}
```

```
BenchmarkString2Slice-16          300843              4240 ns/op               0 B/op          0 allocs/op
BenchmarkString2Slice2-16        4706086               255.0 ns/op             0 B/op          0 allocs/op
```

Go 的函数形参不能声明为 const，所以无法在编译阶段保证变量不被修改，只能依靠人工检查确认，存在风险。

换言之，如果有这样的方式的话，那么其实编译器在编译阶段就可以把这一块优化掉，因为可以确保在函数中这个变量不会被修改，可以共享其中的内存。
