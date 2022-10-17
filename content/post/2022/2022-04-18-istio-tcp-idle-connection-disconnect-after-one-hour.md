---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-04-18
title: "Istio sidecar TCP 空闲连接 1 小时自动断开"
url: "/2022/04/18/istio-tcp-idle-connection-disconnect-after-one-hour"
---

部分服务连接 redis 会经常出现连接被断开，导致从连接池中取出连接发送请求时会失败。

从 istio accesslog 中观测到到 redis 的连接，断开时间通常是 3600s 即一个小时。

<!--more-->

### 原因

登录容器通过 telnet 测试，发现未接入 istio 时，连接不会被断开，接入 istio 后，连接建立一个小时后会被断开，如果中间发送过数据，则会往后顺延一小时。

说明是接入 istio 导致的问题，就看是 envoy 的原因还是 iptables NAT 转发的原因。

搜到相关的 [Issue](https://github.com/istio/istio/issues/24387)

Envoy 的 TCPProxy 的 NetworkFilter 的 `idle_timeout` 参数，默认是 1h，和观测到的现象对的上。

> idle_timeout
>
> (Duration) The idle timeout for connections. The idle timeout is defined as the period in which there are no active requests. When the idle timeout is reached the connection will be closed. If the connection is an HTTP/2 downstream connection a drain sequence will occur prior to closing the connection, see drain_timeout. Note that request based timeouts mean that HTTP/2 PINGs will not keep the connection alive. If not specified, this defaults to 1 hour. To disable idle timeouts explicitly set this to 0.
> Warning
> 
> Disabling this timeout has a highly likelihood of yielding connection leaks due to lost TCP FIN packets, etc.

从文档说明中来看，目的应该是，解决一些由于底层网络原因可能会导致的连接泄露的问题。对我们来说理论上应该影响不大，可以设置成 0s，关闭这个功能。

**更新: 看起来可能因为 envoy 实现的问题，即使不是底层网络原因，也存在连接泄露的可能，所以建议不要修改为 0，可以按需将这个值调整为 2 天之类的。**

### 解决方案

#### Pod Annotation

```yaml
proxy.istio.io/config: |-
  proxyMetadata:
    ISTIO_META_IDLE_TIMEOUT: "0s"
```

proxyMetadata 中的内容会作为环境变量注入到 istio-proxy 容器中。

`ISTIO_META_IDLE_TIMEOUT` 目前只作用于内部服务，对 PassthroughCluster 无效，我们当前的访问外部数据库的就是 PassthroughCluster 的场景。

https://github.com/istio/istio/issues/38413 已经提了 issue，社区在跟进。

Annotation 的方式只作用在 Pod 上，不能全局生效。

如果要全局生效的话，可以修改 inject template，直接在 sidecar env 中配置这个参数。

#### EnvoyFilter

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: listener-timeout-tcp
  namespace: istio-system
spec:
  configPatches:
  - applyTo: NETWORK_FILTER
    match:
      context: SIDECAR_OUTBOUND
      listener:
        filterChain:
          filter:
            name: envoy.filters.network.tcp_proxy
    patch:
      operation: MERGE
      value:
        name: envoy.filters.network.tcp_proxy
        typed_config:
          '@type': type.googleapis.com/envoy.config.filter.network.tcp_proxy.v2.TcpProxy
          idle_timeout: 0s
```

通过 EnvoyFilter 去修改 TcpProxy 的 `idle_timeout` 参数。

这个方式可以全局生效，但是 EnvoyFilter 的维护难度更高，需要注意和其他功能是否有冲突。且以后更新 istio 时也需要注意兼容性问题，及时跟进。

### 结论

先通过 EnvoyFilter 的方式生效，持续跟进社区的修复进展，当 https://github.com/istio/istio/issues/38413 被解决后，更新到对应的 istio 版本，再通过配置环境变量 `ISTIO_META_IDLE_TIMEOUT` 解决此问题。

**更新: PassthroughCluster 生效的问题已经被解决了。但是因为 `ISTIO_META_IDLE_TIMEOUT` 会同时修改 TCP 和 HTTP 的 idle timeout，HTTP 的 idle timeout 修改的太大也不是很合适，所以可能还是通过 EnvoyFilter 修改会好一些。**
