---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-09-02
title: "Istio 1.9 升级 1.10 ExternalAuthorization 失效的问题"
url: "/2021/09/02/istio-upgrade-from-1-19-to-1-20-external-authorization-invalid"
---

近期在将 Istio 1.9.1 升级到 1.10.4。发现原来在 1.9 版本中生效的 ExternalAuthorization 的功能在控制面升级到 1.10，数据面保持在 1.9 版本时，会失效。所有的请求都不需要鉴权就能访问到后端服务。

<!--more-->

给社区提了 issue: https://github.com/istio/istio/issues/34988

但是因为此功能之前也说明了是在 experimental 阶段，各个阶段的功能说明见: [feature-stages](https://istio.io/latest/docs/releases/feature-stages/)。

控制面和数据面都更新到 1.10 后问题会恢复，但是中间阶段鉴权会失效，存在一段风险窗口。

### 复现步骤

参考官方文档 https://istio.io/latest/docs/tasks/security/authorization/authz-custom/

1. 通过 helm chart 安装 istio 1.9.1。
2. 按照上述 External Authorization 的文档部署相关的测试服务。
3. 发送测试请求，预期一切正常。
4. 通过 helm chart 将 istio 控制面升级到 1.10.4，数据面仍然保持在 1.9.1。
5. 发送测试请求，原来预期 403 的请求，现在变成 200 了。

### 问题排查

#### 服务 Pod istio-proxy 容器日志

通过 kubectl logs 查看问题的 pod 日志。

```
warning envoy config    Unknown field: type envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager with unknown field set {45}
warning envoy config    Unknown field: type envoy.extensions.filters.http.rbac.v3.RBAC with unknown field set {3}
warning envoy config    Unknown field: type envoy.extensions.filters.network.rbac.v3.RBAC with unknown field set {5}
```

通过查看 enovy 的 api 接口，发现

`envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager` 增加了一个字段 `PathWithEscapedSlashesAction path_with_escaped_slashes_action = 45`

`envoy.extensions.filters.http.rbac.v3.RBAC` 增加了一个字段 `string shadow_rules_stat_prefix = 3`

`envoy.extensions.filters.network.rbac.v3.RBAC` 增加了一个字段 `string shadow_rules_stat_prefix = 5`

说明 1.10 的控制面下发的配置中有新的字段，在旧版本的数据面里没有定义，不被识别，虽然不会导致出错，但是相当于默认值为空。

#### Envoy ConfigDump

执行 `kubectl -n foo exec  $(kubectl -n foo get pods -l app=httpbin -o jsonpath='{.items[0].metadata.name}') -c istio-proxy -- pilot-agent request GET config_dump > new.json`，将对应 envoy 的 config dump 到本地文件中。

将 proxy 1.10 版本的配置 dump 到 new.json，将 proxy 1.9 版本的配置 dump 到 old.json。

两个文件对 extAuthz 相关的部分做 Diff。

```
44,45c44
<       },
<       "shadow_rules_stat_prefix": "istio_ext_authz_"
---
>       }
```

发现 1.10 版本的配置确实只是在 envoy.filters.http.rbac filter 下多了一个 `shadow_rules_stat_prefix` 的配置，1.9 的版本中由于没有这个字段的定义，所以为空，也没问题。

再将控制面和数据面都还原回 1.9 版本，dump 一份新的配置文件。

发现了新的变化，`envoy.filters.network.ext_authz` filter 下的 `filter_enabled_metadata.path.key` 这个字段的值由 `shadow_effective_policy_id` 变成了 `istio_ext_authz_shadow_effective_policy_id`。

相当于是加了一个前缀，这个前缀的内容就是定义在 rbac filter 的 `shadow_rules_stat_prefix` 中。

控制面和数据面都升级到 1.10 版本后完整的配置信息:

```json
{
  "name": "envoy.filters.http.rbac",
  "typed_config": {
    "@type": "type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC",
    "shadow_rules": {
      "action": "DENY",
      "policies": {
        "istio-ext-authz-ns[foo]-policy[ext-authz]-rule[0]": {
          ...
        }
      }
    },
    "shadow_rules_stat_prefix": "istio_ext_authz_"
  }
},
{
  "name": "envoy.filters.network.ext_authz",
  "typed_config": {
    "@type": "type.googleapis.com/envoy.extensions.filters.network.ext_authz.v3.ExtAuthz",
    "stat_prefix": "tcp.",
    "grpc_service": {
      "envoy_grpc": {
        "cluster_name": "xxx",
        "authority": "xxx"
      },
      "timeout": "600s"
    },
    "transport_api_version": "V3",
    "filter_enabled_metadata": {
      "filter": "envoy.filters.network.rbac",
      "path": [
        {
          "key": "istio_ext_authz_shadow_effective_policy_id"
        }
      ],
      "value": {
        "string_match": {
          "prefix": "istio-ext-authz"
        }
      }
    }
  }
}
```

### 原因

从上面排查到的现象来分析，基本上猜测这个问题和 envoy api 中新增加的 `shadow_rules_stat_prefix` 字段非常相关。

这个字段的作用是什么？

通过 enovy 的官方文档可以发现，rbac filter 提供了一个 `shadow rule` 的功能，这个作用是 rbac 的 filter 并不实际生效去拦截请求，而是如果规则匹配成功，则写入动态的元数据，这个元数据的 key 原来就是 `shadow_effective_policy_id`，值是匹配的策略 ID，这个 ID 在 `shadow_rules.policies` 中定义。之后在日志记录和 metrics 数据生成时都可以使用这个元数据，方便用户排查问题。

新增的 `shadow_rules_stat_prefix` 字段，就是如果匹配成功了，这个元数据的 key 在 `shadow_effective_policy_id` 的基础上再加一个前缀。

Istio 外部鉴权的实现方式有点 tricky，会创建一个 rbac filter 的 shadow rule，不实际拦截请求，只匹配规则，之后在 extAuthz filter 中会判断动态元数据中是否存在 key 为 `shadow_effective_policy_id`(1.10 版本中变成了 `istio_ext_authz_shadow_effective_policy_id`) 的值是不是以 `istio-ext-authz` 开头，如果是，则匹配成功，会将请求转发给外部鉴权服务。

1.10 版本中，由于为了支持 extAuthz 的 dry-run 功能，这部分代码有所修改，引起问题的代码: https://github.com/istio/istio/pull/32011/files#diff-420b184ed85af159a2ec1ea8a74c300b272fe014bc45652c2f7a443fe11b558dL357 

正常的 AuthPolicy 的 key 被修改成了 `istio_ext_authz_shadow_effective_policy_id`，dryRun 的 AuthPolicy 的 key 前缀是 `istio_dry_run_allow_` 或 `istio_dry_run_deny_`。

所以问题就显而易见了，由于给这个元数据加前缀的代码在旧版本的 envoy 中还不支持，所以生成的元数据的 key 还是 `shadow_effective_policy_id`，但是匹配条件中的 key 已经被修改成了 `istio_ext_authz_shadow_effective_policy_id`，由于不匹配，所以请求就不会被转发给外部鉴权服务，从而导致所有请求都被房型。

### 解决方案

首先需要慎重使用 experimental 阶段的功能，试验阶段的功能官方也不会保证稳定性，可能随时会有不兼容的更新或者被直接移除。

1. 通过 EnvoyFilter 将相关的字段改回去。但由于过滤条件的地方是一个数组，使用 MERGE 的方式会导致两个值都保留，不符合预期。
2. 先升级数据面到 1.10，再升级控制面。因为 1.10 对应的 envoy 接口更全，所以不会存在上述问题。但是需要做好 1.9 控制面配上 1.10 数据面的兼容性测试。

我们选择方案二来升级，测试验证兼容性没有问题。
