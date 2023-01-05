---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-07-17
title: "通过自定义 metrics tag 忽略 prometheus 抓取错误"
url: "/2022/07/17/ignore-prometheus-scrape-error-by-custom-metrics-tag"
---


由于接入 istio 后，所有的入请求会被 istio sidecar 劫持，并在 accesslog 和 metrics 中记录请求的状态。

<!--more-->

业务服务的 Pod 在启动后，prometheus 会立即去抓取 metrics，但此时应用可能还没有初始化完成，没有监听端口，所以抓取请求必然会失败，返回 503。prometheus 不会等到 Pod Ready 之后才去采集，而是只要 Pod 调度完成，有 PodIP 了之后就会按照指定的频率去采集。

当应用数量较多，发版步长比较长时，在监控页面会显示有不少 503 的 QPS，也会误触发告警，影响告警的有效性。

### 解决方案

考虑一个可行的方案是通过识别请求的特征，将具有某些特征的请求识别为可以忽略错误，并在 metrics 中新增一个 tag `ignore_error` 用于表示是否需要忽略错误。

比如当前 prometheus 和 vm-agent 去采集时，都会带上 `x-prometheus-scrape-timeout-seconds` 这个 header。可以通过 istio 提供的自定义 metrics 来实现只要带有这个 header 的请求，附加的 tag 的值为 true，否则为 false。之后在监控和告警中可以忽略这个 tag 为 true 的 metrics。

官方文档: https://istio.io/latest/docs/tasks/observability/metrics/customize-metrics/

### 配置

#### extraStatTags

需要特别注意: 必须先配置 `extraStatTags`，再修改后面的 EnvoyFilter，否则可能会导致 Pod 产生很多脏数据的 metrics。应该是 envoy 的机制的问题，会把新加的 tag 加到 metrics name 前面。

只增加 extraStatTags，不定义 tag 的值，就没有影响，所以可以先更新。

`extraStatTags` 有两种方式配置，一种是 Pod annotation，不是很建议，因为更新这个字段并不影响 metrics 采集，所以测试环境验证没问题后，可以直接全量更新。

```
apiVersion: apps/v1
kind: Deployment
spec:
  template: # pod template
    metadata:
      annotations:
        sidecar.istio.io/extraStatTags: ignore_error
```

meshConfig.defaultConfig 可以定义全局配置，但是需要注意，所有的 Pod 都需要重启后才能生效。因为这个配置是 envoy 的 bootstrap 配置。

```
mesh:
  defaultConfig:
    extraStatTags:
    - ignore_error
```

#### 在 EnvoyFilter 中开启自定义 metrics 配置

在 `extraStatTags` 中配置了 `ignore_error` 之后，确保所有的 Pod 都重启，应用了这个配置后，才能通过修改 stats filter 的配置来定义 metrics 配置。

istio 的 helm chart 中封装了这个 EnvoyFilter 的配置，可以在 values.yaml 中的 `telemetry.v2.prometheus` 配置。我们只需要修改 inboundSidecar 的配置。

```
telemetry:
  enabled: true
  v2:
    enabled: true
    metadataExchange:
      wasmEnabled: false
    # Indicate if prometheus stats filter is enabled or not
    prometheus:
      enabled: true
      # Indicates whether to enable WebAssembly runtime for stats filter.
      wasmEnabled: false
      # overrides stats EnvoyFilter configuration.
      configOverride:
        inboundSidecar:
          debug: "false"
          stat_prefix: "istio"
          disable_host_header_fallback: true
          metrics:
          - dimensions:
              destination_cluster: "node.metadata['CLUSTER_ID']"
              source_cluster: "downstream_peer.cluster_id"
          - name: requests_total
            dimensions:
              ignore_error: "('x-prometheus-scrape-timeout-seconds' in request.headers) ? 'true' : 'false'"
```

除了 `ignore_error` 之外，其他的是目前 chart 里的默认配置，由于 chart 的实现问题，这个配置会覆盖掉默认配置，所以这里把默认配置也一起加过来。以后同步配置的时候需要注意下官方的默认配置会不会更改，如果改了，要记得同步下。

values.yaml 中的修改会影响到的是 `templates/telemetryv2_1.12.yaml` 这个文件。注意，文件名后缀是 istio 版本，这个配置由于 istio 版本不同，要考虑兼容性的问题，由于 Istio 的 Release 规则会兼容最近三个版本，所以会同时存在三个版本的文件，创建三套不同的 EnvoyFilter，而每一个 EnvoyFilter 会通过 Match 规则，只匹配对应版本的 sidecar。

注: 社区在推一个新的 Telemetry CRD，可以用于配置 metrics, trace, accesslog，相比于 EnvoyFilter 会更标准化一些。之后可以考虑通过 TelemetryAPI 来配置。
