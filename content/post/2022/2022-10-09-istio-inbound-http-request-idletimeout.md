---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-10-09
title: "Istio Inbound HTTP 请求的 IdleTimeout 问题"
url: "/2022/10/09/istio-inbound-http-request-idletimeout"
---

istio sidecar inbound HTTP 请求的 idle timeout 配置默认为 1h。

<!--more-->

之前以为 [cleanup_interval](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/cluster.proto#envoy-v3-api-field-config-cluster-v3-cluster-cleanup-interval) 是 istio sidecar 的 envoy 清理 inbound 空闲连接的配置，测试下来发现并不完全是。

在 envoy 的一个 cluster 中，cleanup 的逻辑应该是清理 host 级别的整个连接池，每一个 host 应该是独立的 connection pool，整个 host 级别如果持续了 `cleanup_interval` 的时间后都没有任何请求，则会将这个 connection pool 中的连接都清理了。

如果需要配置 HTTP 的 idle timeout，envoy 的文档中有说明，分别介绍了 downstream 和 upstream 的这个值要如何配置: https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/timeouts#faq-configuration-connection-timeouts。

对应到 istio 中，目前研究下来，没有一个正式的配置可以用来配置一个全局的默认值。Istio 没有主动配置，则 envoy 默认的配置是 1 小时。

有两个方法来实现修改 Inbound 请求的 idle timeout。

1. 通过 DestinationRule 显示为特定的服务配置 http idle timeout:

    ```yaml
    apiVersion: networking.istio.io/v1beta1
    kind: DestinationRule
    metadata:
      name: istio-test
      namespace: infra
    spec:
      host: istio-test-server
      trafficPolicy:
        connectionPool:
          http:
            idleTimeout: 10s
    ```
    
    上面的配置会将 istio-test-server 的实例的 Inbound Cluster HTTP IdleTimeout 值修改为 10s。也就是 istio-test-server pod 内的 envoy 处理入请求时使用的配置。
    
    同时会将其他服务访问 istio-test-server 的 HTTP IdleTimeout 也设置为 10s。假设 istio-test-client 访问 istio-test-server，则 istio-test-client 所在的 envoy 访问 istio-test-server 的 envoy 的时候，也遵循这个 idle timeout 的配置。
    
2. 通过 EnvoyFilter 全局修改 InboundCluster 的配置。

    ```yaml
    apiVersion: networking.istio.io/v1alpha3
    kind: EnvoyFilter
    metadata:
      name: test-http-idle-timeout
      namespace: istio-system
    spec:
      configPatches:
        - applyTo: CLUSTER
          match:
            context: SIDECAR_INBOUND
          patch:
            operation: MERGE
            value:
              typedExtensionProtocolOptions:
                envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
                  '@type': type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
                  commonHttpProtocolOptions:
                    idleTimeout: 10s
                  explicitHttpConfig:
                    httpProtocolOptions: {}
    ```
    
    上面的配置会修改所有实例的 Inbound Cluster 的 HTTP idleTimeout。
    
    需要额外注意的是，这个 EnvoyFilter 会同时修改 `InboundPassthroughClusterIpv4` 这个特殊 Cluster。这个 Cluster 主要是用于转发没有在 Service 中声明的端口。给这个 Cluster 加上这个配置的影响不是非常确定，至少和 DestinationRule 中的实现不完全一致。
