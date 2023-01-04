---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-09-07
title: "Istio Gateway 支持 gzip"
url: "/2021/09/07/istio-gateway-support-gzip"
---

目前使用的 Ingress Nginx 中开启了 gzip 压缩。在将服务网关从 Ingress Nginx 迁移到 Istio Gateway 后，也需要相应支持这个能力。

<!--more-->

### Nginx

Nginx 中和压缩有关的一些配置:

* use-gzip: 是否启用 gzip 压缩。
* gzip-types: 哪些 content-type 会被启用压缩。
* gzip-min-length: response 大小达到多少才启用压缩。
* gzip-level: 压缩级别。

其中一些参数的默认值为:

```
gzip-types: application/atom+xml application/javascript application/x-javascript application/json application/rss+xml application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/svg+xml image/x-icon text/css text/javascript text/plain text/x-component

gzip-min-length: 256

gzip-level: 1
```

### Isito Gateway

Istio 中目前没有正式支持在网关通过配置的方式开启压缩的功能，需要通过 EnvoyFilter 主动注入相关的 Envoy 配置。（需要关注 EnovyFilter API 的变更，在做版本升级时尤其需要注意）

#### EnvoyFilter

compressor filter [文档](https://www.envoyproxy.io/docs/envoy/v1.18.4/configuration/http/http_filters/compressor_filter#config-http-filters-compressor)

Istio EnvoyFilter [说明文档](https://istio.io/latest/docs/reference/config/networking/envoy-filter)

Istio 1.10 用到的 envoy 版本是 1.18.4。目前支持 gzip 和 brotli 两种压缩算法。

参考 IngressNginx 的一些配置，我们需要创建的 EnvoyFilter:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: istio-ingressgateway-compression-gzip
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      app: istio-ingressgateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: "envoy.http_connection_manager"
              subFilter:
                name: 'envoy.filters.http.router'
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.compressor
          typed_config:
            '@type': type.googleapis.com/envoy.extensions.filters.http.compressor.v3.Compressor
            response_direction_config:
              common_config:
                min_content_length: 256
                content_type:
                  - application/atom+xml
                  - application/javascript
                  - application/x-javascript
                  - application/json
                  - application/rss+xml
                  - application/vnd.ms-fontobject
                  - application/x-font-ttf
                  - application/x-web-app-manifest+json
                  - application/xhtml+xml
                  - application/xml
                  - font/opentype
                  - image/svg+xml
                  - image/x-icon
                  - text/css
                  - text/javascript
                  - text/plain
                  - text/x-component
            compressor_library:
              name: text_optimized
              typed_config:
                '@type': type.googleapis.com/envoy.extensions.compression.gzip.compressor.v3.Gzip
                memory_level: 3
                compression_level: COMPRESSION_LEVEL_1
```

* workloadSelector: 需要选中对应的 ingress gateway 的 pod。
* applyTo: 注入到 envoy 配置的什么地方。
* match: 匹配到什么地方，这里是 gateway 的 `envoy.http_connection_manager.envoy.filters.http.router`。
* patch.operation: patch 的操作，这里是 `INSERT_BEFORE`，表示在 `envoy.http_connection_manager.envoy.filters.http.router` 之前(match 的内容之前)插入一个 http filter。
* patch.value: 注入的 http filter 的内容，这里是 gzip 压缩的具体配置。

### Benchmark

测试环境，约 400 QPS，响应体内容为 10240 字节的重复内容。由于测试环境不是很稳定，所以测试结果仅供参考。

istio-ingressgateway 为 2C1G

开启 gzip 前: 0.15C 166MB

开启 gzip 后: 0.17C 166MB

可以看出内存上基本上没有什么影响，CPU 使用率提高了大约 13%，不是非常明显。
