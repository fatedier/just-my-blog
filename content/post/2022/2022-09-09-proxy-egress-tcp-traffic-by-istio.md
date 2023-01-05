---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-09-09
title: "通过 Istio 代理出方向的 TCP 流量"
url: "/2022/09/09/proxy-egress-tcp-traffic-by-istio"
---

通过 Istio 可以劫持出方向的 HTTP/HTTPS 流量到特定的 Egress Gateway。通过固定 Egress Gateway 的节点可以实现线路优化，固定出口 IP，安全审计等等功能。

<!--more-->

但是如果需要代理 TCP 的流量，会麻烦一点，由于 TCP 不像 HTTP 那样可以通过 Host header 拿到目的服务的地址。转发 TCP 流量会丢失目的地址信息。

我们需要结合 Istio 的 DNS Proxying 功能，给 TCP 连接的域名固定一个 IP 地址。Istio 劫持到这个 IP 地址的出连接后，转发时通过 TLS 带上 SNI 信息转发给一个 SNI Proxy，SNI Proxy 会根据 server name 去代理连接目标地址。

### 配置方式

示例假设我们希望劫持 example.com:9444 端口的流量，到我们指定的 SNI Proxy 去。

为了便于验证，9444 端口的协议还是用 HTTP 来进行测试。

#### 启用 DNS Proxying 功能

通过给 Pod 加上 annotation 启用 DNS 代理功能，以及启用自动分配 IP 地址的能力。

```yaml
  template:
    metadata:
      annotations:
        proxy.istio.io/config: |
          proxyMetadata:
            ISTIO_META_DNS_CAPTURE: "true"
            ISTIO_META_DNS_AUTO_ALLOCATE: "true"
```

#### 创建 ServiceEntry 声明要劫持的域名和端口

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-auto
spec:
  hosts:
  - example.com
  ports:
  - name: tcp
    number: 9444
    protocol: TCP
  resolution: DNS
```

#### 给 SNI Proxy 配置 DestinationRule，启用 TLS

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: tls-sni-proxy
spec:
  host: sni-proxy
  subsets:
  - name: example-com-9444
    trafficPolicy:
      tls:
        mode: SIMPLE
        sni: example.com:9443
```

#### 创建 VirtualService 将 `example.com:9444` 的流量路由到上面创建的 DestinationRule

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: auto-tls
spec:
  hosts:
  - "example.com"
  gateways:
  - mesh
  tcp:
  - match:
    - port: 9444
    route:
    - destination:
        host: sni-proxy
        subset: example-com-9444
        port:
          number: 443
```

#### 测试

`curl example.com:9444` 会被路由到 SNI Proxy 代理请求出去。

### 问题

#### 同一域名未定义的其他端口无法正常访问

[HTTP request failed after ISTIO_META_DNS_AUTO_ALLOCATE enabled](https://github.com/istio/istio/issues/39080)

当前如果开启了 `ISTIO_META_DNS_AUTO_ALLOCATE` ，由 Istio 给 ServiceEntry 的域名分配了 IP，会导致所有没有在 ServiceEntry 中定义的端口都无法访问。

因为这些连接会被路由到 PassthroughCluster，然后 upstream 会是 Istio 分配的虚拟 IP，无法正常连接。

目前只能通过在 ServiceEntry 中给该域名所有需要访问的端口都预先定义好才能避免。

但是如果是严格限制对外访问的环境，要求所有外部请求的端口都事先定义也很合理。

注: 可以不使用 `ISTIO_META_DNS_AUTO_ALLOCATE` 自动分配 IP，而是通过 ServiceEntry.addresses 手动给需要的 ServiceEntry 分配 IP，这样可以尽量减小对其他 ServiceEntry 中定义域名的影响。

#### SNI Proxy 的端口问题

由于我们通过 SNI 设置的 server name 格式为 `example.com:9443`，SNI Proxy 需要能够解析出 host 和端口号然后去访问。
