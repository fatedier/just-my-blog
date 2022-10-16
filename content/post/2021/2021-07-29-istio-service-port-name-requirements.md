---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-07-29
title: "Istio 对 Service port name 的要求"
url: "/2021/07/29/istio-service-port-name-requirements"
---

由于 Istio 需要在七层解析流量，所以劫持服务流量后需要知道协议类型才能用合适的协议规则来解析。

<!--more-->

在 Istio 中，目前有两种方式:

* 自动协议探测。
* 明确指定端口协议类型。

如果用户没有明确指定端口协议类型，则 istio 会自动探测流量协议，（一般是根据连接开始的少量字节信息来判断）。自动协议探测可以通过 `PILOT_ENABLE_PROTOCOL_SNIFFING_FOR_INBOUND` 和 `PILOT_ENABLE_PROTOCOL_SNIFFING_FOR_OUTBOUND` 来配置，为 True 则启用，否则禁用，默认值为 true。

自动探测可能会有一些潜在的风险，例如某个协议包头和 HTTP 类似，但是实际上并不是 HTTP，另外，判断协议类型一般需要至少读取多少字节的内容，假如连接建立后发送的数据量不满足这个数量，istio 只能等到超时后再以 TCP 的方式来直接转发流量。

一般推荐明确指定端口协议类型，[Explicit protocol selection](https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/#explicit-protocol-selection)。

K8s Service 的端口定义时，port name 需要以协议开头，格式为 `<protocol>[-<suffix>]`

例如:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: test
  namespace: default
spec:
  ports:
  - name: http-xxx
    port: 80
    protocol: TCP
    targetPort: 12000
  selector:
    app: test
  sessionAffinity: None
  type: ClusterIP
```

如果 port name 配置成错误的协议，会导致 istio 解析失败，从而断开连接。

在 K8s 1.18 之后，Service 定义中增加了一个 appProtocol 字段可以用于指定端口协议，就不再需要通过 port name 定义这种不优雅的方式来实现了。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: test
  namespace: default
spec:
  ports:
  - name: xxx
    port: 80
    protocol: TCP
    appProtocol: http
    targetPort: 12000
  selector:
    app: test
  sessionAffinity: None
  type: ClusterIP
```

另外，一旦 Service port name 被指定，之后再去修改的话，会导致 IngressNginxController 报错，会临时将后端所有节点摘掉，所以对于有持续流量的服务，需要谨慎修改。

相关 issue: https://github.com/kubernetes/ingress-nginx/issues/7390
