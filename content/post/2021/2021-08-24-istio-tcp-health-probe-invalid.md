---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-08-24
title: "Istio TCP 健康检查无效的问题"
url: "/2021/08/24/istio-tcp-health-probe-invalid"
---

1.9，1.10 的官方文档对这个问题的表述不是很清楚，都没有提到 TCP 的健康检查无效的问题。

<!--more-->

### 背景

K8s 的健康检查是由 kubelet 发起，kubelet 会通过 Pod IP 向指定的端口建立连接，如果连接建立成功，则认为服务健康，反之则认为不健康。

服务接入 Istio 后，istio 会通过 iptables 规则劫持流量到 enovy，当 kubelet 建立连接时，连接被转给 enovy，此时连接建立成功，kubelet 认为服务健康，但是实际上可能该端口根本没有被绑定。

像 HTTP 类型的健康检查，istio 会在 webhook 中就把原来 container 的健康检查配置修改掉，改成像 envoy 的特定接口发送 HTTP 请求，然后由 envoy 去转发给业务服务。

### 解决方案

目前只能要求接入的服务提供 HTTP 类型的健康检查接口。

社区有一个解决方案目前已经被合入，但是在 1.11 中还没有发布，看起来有可能在 1.11 的小版本或者 1.12 版本中发布。[https://github.com/istio/istio/pull/33734](https://github.com/istio/istio/pull/33734)

原理是，pilot-agent 提供一个类似 `/check/{port}` 的接口，通过 http 请求发起对 tcp 端口的探测。之后 istio webhook 在注入 sidecar 时，将用户配置的健康检查接口进行替换，转换成 HTTP 类型的 `/check/{port}` 接口，从而实现对 TCP 端口的探测。

**更新: istio 1.12 中已修复 https://istio.io/latest/news/releases/1.12.x/announcing-1.12/change-notes/**
