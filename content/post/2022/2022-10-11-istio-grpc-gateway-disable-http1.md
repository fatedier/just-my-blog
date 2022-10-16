---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-10-11
title: "Istio GRPC Gateway 禁用 HTTP1.1 请求"
url: "/2022/10/11/istio-grpc-gateway-disable-http1"
---

有一组专门用于 grpc 请求的 istio-gateway 网关，但是会被通过 HTTP1.1 的请求做漏洞扫描，istio gateway 仍然能够处理，并且会将这个请求转发给后端的服务，后端服务由于协议不匹配，会直接断开连接，istio gateway 就会返回 503。

这样会误触发告警，并且也会影响观测正常的监控。

<!--more-->

### 通过 EnvoyFilter 禁用 HTTP1

GRPC 网关的 Gateway，明确声明了端口的 protocol 为 grpc。

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: istio-ingressgateway-grpc
  namespace: istio-system
spec:
  selector:
    app: istio-ingressgateway-grpc
    istio: ingressgateway-grpc
  servers:
  - hosts:
    - '*'
    port:
      name: grpc
      number: 80
      protocol: GRPC
```

通过 EnvoyFilter 将 httpconnection manager 的 codec type 修改为只支持 HTTP2。

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: disable-grpc-ingress-h1
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      app: istio-ingressgateway-grpc
  configPatches:
  - applyTo: NETWORK_FILTER
    match:
      context: GATEWAY
      listener:
        portNumber: 8080
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
    patch:
      operation: MERGE
      value:
        typed_config:
          '@type': type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          codec_type: HTTP2
```

### 测试

没有修改之前:

```
curl http://192.168.1.1/test -v -H 'Host: example.com'
* About to connect() to 192.168.1.1 port 80 (#0)
*   Trying 192.168.1.1...
* Connected to 192.168.1.1 (192.168.1.1) port 80 (#0)
> GET /test HTTP/1.1
> User-Agent: curl/7.29.0
> Accept: */*
> Host: example.com
>
< HTTP/1.1 503 Service Unavailable
< content-length: 85
< content-type: text/plain
< date: Tue, 11 Oct 2022 14:07:29 GMT
< server: istio-envoy
< x-envoy-upstream-service-time: 19
<
* Connection #0 to host 192.168.1.1 left intact
```

修改之后:

```
curl http://192.168.1.1/test -v -H 'Host: example.com'
* About to connect() to 192.168.1.1 port 80 (#0)
*   Trying 192.168.1.1...
* Connected to 192.168.1.1 (192.168.1.1) port 80 (#0)
> GET /test HTTP/1.1
> User-Agent: curl/7.29.0
> Accept: */*
> Host: exxample.com
>
* Empty reply from server
* Connection #0 to host 192.168.1.1 left intact
```

istio-gateway 的日志:

```
[2022-10-11T14:07:30.560Z] "- - HTTP/1.1" 400 DPE http1.codec_error - "-" 0 11 0 - "-" "-" "-" "-" "-" - - 192.168.1.2:8080 192.168.10.1:40934 - - "Internal"
[2022-10-11T14:07:31.572Z] "- - HTTP/1.1" 400 DPE http1.codec_error - "-" 0 11 0 - "-" "-" "-" "-" "-" - - 192.168.1.2:8080 192.168.10.1:40954 - - "Internal"
[2022-10-11T14:07:50.622Z] "- - HTTP/1.1" 400 DPE http1.codec_error - "-" 0 11 0 - "-" "-" "-" "-" "-" - - 192.168.1.2:8080 192.168.10.1:41316 - - "Internal"
```

可能由于 codec 阶段就拒掉了，并没有在 http filter 的 metrics 中体现，也就不会影响到监控告警。
