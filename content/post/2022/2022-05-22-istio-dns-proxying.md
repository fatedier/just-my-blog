---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-05-22
title: "Istio DNS Proxying"
url: "/2022/05/22/istio-dns-proxying"
---

原理就是通过 iptables 劫持 DNS 查询请求到 sidecar ，由 sidecar 提供 DNS 请求的响应和转发。

对于 K8s 内部的 service 名称解析，会直接返回结果。

对于外部的域名，会转发给上游的 DNS Server 查询。

<!--more-->

官方文档: https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/

### 启用方式

通过 Pod annotation 启用

```yaml
template:
  metadata:
    annotations:
      proxy.istio.io/config: |
        proxyMetadata:
          ISTIO_META_DNS_CAPTURE: "true"
```

另外，还有一个参数 `ISTIO_META_DNS_AUTO_ALLOCATE: "true"`，开启了之后会给 ServiceEntry 中定义的 host 自动分配一个 istio 内部的虚拟 IP，主要用于解决 TCP 类型的连接没有域名信息等的问题，无法实现端口复用的路由规则。但是一般来说不建议开启，因为会影响到 ServiceEntry 中声明的域名，如果业务应用访问没有定义的端口，会连接失败。

### 优点

* 解决跨集群服务访问的 DNS 解析问题。如果一个服务只在 A 集群创建 Service，B 集群没有，B 集群的 DNS 无法解析到这个服务，会导致无法访问。（另一种做法是两边创建相同的 Service，管理起来麻烦，增加了管理成本）
* K8s 集群内的 service 解析直接由 sidecar 响应，不转发到 coredns，减轻 coredns 的压力，理论上这一类请求响应会更快。

### 未解决的问题

由于 DNS Proxying 没有 cache 的能力，没有事先声明的外部域名每次请求时仍然会转发给上游的 DNS Server。仍然可能会遇到故障。

另一种可选的方案是对所有需要 cache 的外部域名事先通过 ServiceEntry 声明，Envoy 会去做定期的 DNS 解析，但是目前这个方案会导致所有 Pod 无差别的定期解析这个域名，依赖 [On-demand DNS resolution](https://github.com/envoyproxy/envoy/issues/20562) 这个 Issue 可能可以有效缓解这个问题
