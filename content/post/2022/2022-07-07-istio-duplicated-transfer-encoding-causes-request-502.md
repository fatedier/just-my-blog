---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2022-07-07
title: "应用侧返回 Duplicated Transfer-Encoding 导致接入 Istio 后请求 502"
url: "/2022/07/07/istio-duplicated-transfer-encoding-causes-request-502"
---

有用户反馈新增的接口调用后返回 upstream connect error or disconnect/reset before headers. reset reason: protocol error。

但是同一个接口，在未登录时，返回未认证的 json 是正常的。只有在登录后，返回接口才不正常。

<!--more-->

### 排查

这个返回内容明显是 envoy 返回的，从错误提示看，大概率是协议问题。但是同一个接口，登录和未登录时不一致，比较奇怪。

查看 trace 信息，java 服务返回的 http status code 是 200。而 envoy sidecar 返回的是 502。

怀疑是 java 服务返回的 http response 是不是有什么不规范的地方。

尝试对容器进行抓包。

```
HTTP/1.1 200
date: Thu, 07 Jul 2022 03:27:40 GMT
server: envoy
transfer-encoding: chunked
vary: Accept-Encoding
x-envoy-upstream-service-time: 88
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Cache-Control: no-cache, no-store, max-age=0, must-revalidate
Pragma: no-cache
Expires: 0
Strict-Transport-Security: max-age=31536000 ; includeSubDomains
X-Frame-Options: SAMEORIGIN
Content-Type: application/json
Transfer-Encoding: chunked
```

发现 java 服务返回的响应中存在两个重复的 `Transfer-Encoding: chunked`。

搜索 istio issue，发现有类似的问题，[istio#36711](https://github.com/istio/istio/issues/36711)，社区的说法是这种返回是不符合规范的，导致 envoy 无法正常解析，所以报 protocol error，推荐是应用层解决这个问题。

经过定位，是 java 服务将上游请求返回的 response header 直接 copy 之后，返回给了下游服务，然后框架可能又加上了一个 Transfer-Encoding header，导致同时存在两个。

### Hop-by-hop headers

一般来说，这一类 header 只在单个 HTTP 连接的两端起作用，如果中间接入的是代理，不应该透传给上游或下游。

```
- Connection
- Keep-Alive
- Proxy-Authenticate
- Proxy-Authorization
- TE
- Trailers
- Transfer-Encoding
- Upgrade
```

通常，不管是将 request 转发给上游服务，还是将上游服务的请求 header 透传给下游服务，都应该移除其中的这些 header，避免将这些 header 透传。

### 解决

目前接入 Istio 的服务除了这一个之外，还没有观测到类似的问题，后续接入过程中如果再有这样的报错，可以用同样的方法排查。

提醒对应的应用开发者修改代码。

Ingress-Nginx 并没有观测到类似的错误，大概率是 nginx 进行了兼容。
