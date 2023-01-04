---
categories:
    - "技术文章"
tags:
    - "istio"
    - "service mesh"
date: 2021-09-17
title: "通过 WebAssembly 扩展 Istio 和 Envoy"
url: "/2021/09/17/extend-istio-and-envoy-by-wasm"
---

Istio 在 1.5 版本(2020年5月)中宣布支持 WebAssembly 扩展，通过定制化的 envoy 实现。

<!--more-->

Enovy 对 WASM 支持相关的修改在 2020年10月 被合入到上游社区。

Istio 在 1.9，1.10 中都对 WASM 模块的分发做了优化。

### 背景

WebAssembly 给 Istio 这样的项目带来了非常大的可扩展性，且没有增加太多的性能损失。

目前一些主流的方向，包括 Mesh(典型的例如 [Dapr](https://github.com/dapr/dapr))，以及 Serverless，对可扩展性和性能的需求都比较强烈。WebAssembly 可以做到高性能，跨平台，多语言，易于分发，非常适合这些场景。相比于 Docker，WebAssembly 拥有更快的启动速度。

#### WASM/WASI

WebAssembly 是一种新的字节码格式，旨在成为高级语言的编译目标，目前可以使用 C、C++、Rust、Go、Java 等语言来创建 wasm 模块。该模块以二进制的格式发送到浏览器，并在专有虚拟机上执行，与 JavaScript 虚拟机共享内存和线程等资源。

WASM 的初衷应该是解决 JS 在前端执行效率低的问题。并且，也附带着，可以让前端开发使用更多的其他语言的现成的库。

[WASI](https://github.com/WebAssembly/WASI) 全称是 WebAssembly System Interface，这个标准从 2019 年开始建立，可以简单的理解成是一套操作系统接口。原先 WebAssembly 在前端只需要和浏览器（JS）交互，但是 WASI 提供了一种可能性，可以使 WASM 模块运行于浏览器之外的环境，应用到后端服务上。这套接口定义了诸如文件存取，网络访问等等需要操作系统提供的能力，之后在不同的平台上，或者不同的语言里，去实现这些 ABI 接口。

目前 WASI 仍然处于迭代阶段，特性也不稳定，可能随时会有调整，整个社区都处于摸索，试验的过程中。

#### proxy-wasm

WebAssembly for Proxies，是 Istio/Envoy 社区针对网络代理设计的一套 ABI 接口，用于定义代理和 WASM 扩展之间的通信协议。

proxy-wasm ABI 定义主要分为两部分，Host Environment 函数和 Wasm 模块函数。

Host Environment 函数是代理需要暴露给 Wasm 模块调用的。比如通过暴露 `proxy_log` 函数，在用户编写的 Wasm 模块中就可以调用这个函数来在 enovy 的标准输出中打印日志信息。这部分函数由代理实现。

Wasm 模块函数是用户需要自己编写的实际处理函数，比如在有请求到来时，需要增加一个 header 字段，就需要实现 `proxy_on_http_request_headers` 函数。

另外，由于 runtime 和 wasm 之间的交互性能问题，通常会采用传递字符串内存地址，而不是在函数入参中传递字符串的方式来进行函数调用。比如 proxy_log 的入参是 `i32 (proxy_log_level_t) log_level i32 (const char*) message_data i32 (size_t) message_size`。

Map 类型也是一个特例，由于内存模型的问题，也不能直接传递 map 的指针来使用。拿 `proxy_on_http_request_headers` 举例，它的入参是 `i32 (uint32_t) context_id i32 (size_t) num_headers i32 (bool) end_of_stream`。并没有传入 map 类型的 header 信息。用户实现该函数时，需要调用 `proxy_get_map` 或者 `proxy_get_map_value` 这两个 Host Environment 函数来获取 header 信息。`proxy_get_map_value` 获取到的是一个字符串，比较好理解，直接传字符串指针就可以了。`proxy_get_map` 比较特殊，需要传递整个 map，又不能直接传指针，所以就需要做一次转换，重新序列化成字符串来传递。格式为 `key-size,value-size,key-size,value-size... key,value,key,value...`。在用户自己编写的 WASM 模块中，需要重新反序列化成 map 的形式。

总而言之，proxy-wasm 定义了一套代理和扩展之间交互的接口的细节，相比于高级语言之间的简单的函数调用，和 wasm 扩展之间的交互显然要更复杂一些。

所以社区提供了 [proxy-wasm-go-sdk](https://github.com/tetratelabs/proxy-wasm-go-sdk), [proxy-wasm-rust-sdk](https://github.com/proxy-wasm/proxy-wasm-rust-sdk) 这样的开发框架，将 wasm 模块和 Host Environment 函数之间的交互细节屏蔽，提供了更易于用户使用的接口。

### 编写 proxy-wasm 扩展

目前 C++ 和 Rust 是支持的比较好的两种语言，生态也比较完善。Istio 自身的一些监测，统计的扩展也是使用 C++ 开发 WASM 模块来实现(目前是以 webassembly 的形式预编译进 enovy，wasm runtime 是 envoy.wasm.runtime.null，比较特殊)。

WebAssembly 的很多定义都和 rust 强相关，rust 在这方面的生态也比较完善，但是相对来说，rust 在整体的语言生态方面还不是很成熟，缺乏丰富、成熟度高的第三方库的支持，质量也层次不齐。

Go 在 wasm 方面的成熟度非常低，但是标准库和语言生态相对比较完善，可复用的库比较多。

#### Rust

使用 https://github.com/proxy-wasm/proxy-wasm-rust-sdk

##### 环境

安装 rust 相关工具

`curl https://sh.rustup.rs -sSf | sh`

更新 rust 版本

`rustup update`

增加编译 wasm target

`rustup target add wasm32-unknown-unknown`

##### 创建项目

cargo 是 rust 的包管理工具，rust 中的包叫做 crate。

`cargo init --lib`

编辑 Cargo.toml 文件，配置依赖版本。

```
[dependencies]
log = "0.4"
proxy-wasm = "0.1.4" # The Rust SDK for proxy-wasm
```

修改 crate 类型为动态链接库

```
[lib]
path = "src/lib.rs"
crate-type = ["cdylib"]
```

编辑 src/lib.rs 文件，copy 如下的官方示例代码

```rust
use log::trace;
use proxy_wasm::traits::*;
use proxy_wasm::types::*;
 
#[no_mangle]
pub fn _start() {
    proxy_wasm::set_log_level(LogLevel::Trace);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> { Box::new(HttpHeadersRoot) });
}
 
struct HttpHeadersRoot;
 
impl Context for HttpHeadersRoot {}
 
impl RootContext for HttpHeadersRoot {
    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
 
    fn create_http_context(&self, context_id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(HttpHeaders { context_id }))
    }
}
 
struct HttpHeaders {
    context_id: u32,
}
 
impl Context for HttpHeaders {}
 
impl HttpContext for HttpHeaders {
    fn on_http_request_headers(&mut self, _: usize) -> Action {
        for (name, value) in &self.get_http_request_headers() {
            trace!("#{} -> {}: {}", self.context_id, name, value);
        }
 
        match self.get_http_request_header(":path") {
            Some(path) if path == "/hello" => {
                self.send_http_response(
                    200,
                    vec![("Hello", "World"), ("Powered-By", "proxy-wasm")],
                    Some(b"Hello, World!\n"),
                );
                Action::Pause
            }
            _ => Action::Continue,
        }
    }
 
    fn on_log(&mut self) {
        trace!("#{} completed.", self.context_id);
    }
}
```

上述代码，会在收到请求的 rquest path 为 `/hello` 时，直接返回 Hello World 以及指定的 header，否则透传请求。

我们需要实现的就是 `on_http_request_headers` 这个函数中的内容，通过 `self.get_http_request_headers` 和 `self.get_http_request_header` 进行与代理之间的数据交互。

##### 编译

编译出 wasm 文件

`cargo build --target wasm32-unknown-unknown --release`

生成的 wasm 文件被放在 `target/wasm32-unknown-unknown/release` 下，以 `.wasm` 为后缀。

文件大小大约 250KB。

#### Go

使用 https://github.com/tetratelabs/proxy-wasm-go-sdk

由于 Go 官方并不支持直接编译出 WASI 适配的 wasm 模块，目前官方支持的只有 js/wasm，仅用于在浏览器环境中运行，且从社区 issue 中来看，最近几年内可能都不会有进展。官方可能认为 WASI 目前的 spec 仍然不成熟，可能随时会有变化，不太适合在早期就在标准库中做支持。

我们需要借助于 [tinygo](https://github.com/tinygo-org/tinygo) 这个项目来编译出支持 wasi 的模块。

需要注意的是，tinygo 目前在协程，反射等方面支持的不完全，可能会影响到某些库的使用。比如标准库的 json 依赖反射，所以并不是所有的结构体都可以使用标准库来做 json 序列化。

##### 环境

TinyGo 当前 0.19.0 版本不支持 Go1.17，我们需要切换到 Go1.16。

安装 TinyGo，可以从 Github Release 页面下载对应系统平台的压缩包。

解压缩到 home 目录下并且将 `{HOME}/tinygo/bin` 加入到 PATH 环境变量中。

执行 `tinygo env` 查看 `TINYGOROOT` 是否是 `{HOME}/tinygo/bin`，如果不是，则需要自己手动配置一下。

##### 创建项目

生成 go.mod 文件

`go mod init test`

编辑 main.go 文件

```go
package main
 
import (
    "github.com/tetratelabs/proxy-wasm-go-sdk/proxywasm"
    "github.com/tetratelabs/proxy-wasm-go-sdk/proxywasm/types"
)
 
func main() {
    proxywasm.SetVMContext(&vmContext{})
}
 
type vmContext struct {
    // Embed the default VM context here,
    // so that we don't need to reimplement all the methods.
    types.DefaultVMContext
}
 
// Override types.DefaultVMContext.
func (*vmContext) NewPluginContext(contextID uint32) types.PluginContext {
    return &pluginContext{}
}
 
type pluginContext struct {
    // Embed the default plugin context here,
    // so that we don't need to reimplement all the methods.
    types.DefaultPluginContext
}
 
// Override types.DefaultPluginContext.
func (*pluginContext) NewHttpContext(contextID uint32) types.HttpContext {
    return &httpHeaders{contextID: contextID}
}
 
type httpHeaders struct {
    // Embed the default http context here,
    // so that we don't need to reimplement all the methods.
    types.DefaultHttpContext
    contextID uint32
}
 
// Override types.DefaultHttpContext.
func (ctx *httpHeaders) OnHttpRequestHeaders(numHeaders int, endOfStream bool) types.Action {
    err := proxywasm.ReplaceHttpRequestHeader("test", "best")
    if err != nil {
        proxywasm.LogCritical("failed to set request header: test")
    }
 
    hs, err := proxywasm.GetHttpRequestHeaders()
    if err != nil {
        proxywasm.LogCriticalf("failed to get request headers: %v", err)
    }
 
    for _, h := range hs {
        proxywasm.LogWarnf("request header --> %s: %s", h[0], h[1])
    }
    return types.ActionContinue
}
 
// Override types.DefaultHttpContext.
func (ctx *httpHeaders) OnHttpStreamDone() {
    proxywasm.LogWarnf("%d finished", ctx.contextID)
}
```

`OnHttpRequestHeaders` 函数是实现我们具体逻辑的地方，通过 `proxywasm.ReplaceHttpRequestHeader` 和 `proxywasm.GetHttpRequestHeaders` 函数来和代理进行数据交互。

这里用了 `proxywasm.LogWarnf` 常规日志，是因为 Istio 默认安装的情况下不输出 Info 级别的日志，这里为了调试方便，用了 warn 级别，生产环境中需要根据实际需要设置日志级别。

下载依赖，更新 go.sum

`go mod tidy`

##### 编译

编译出 wasm 文件

`tinygo build -o test.wasm -target=wasi .`

文件大小大约 250KB。

#### 模块配置

目前 Enovy 支持在启动 wasm 模块时注入用户自定义的配置，之后在 wasm 模块中使用。

比如我们实现一个设置真实 IP 的需求，需要将 `X-Forwarded-For` 中可信代理的 IP 网段过滤掉。这个可信代理的 IP 网段就可以通过模块配置传入，且可以在后续被修改，也不需要重新加载模块。

示例代码:

```go
// Override types.DefaultPluginContext.
func (ctx *pluginContext) OnPluginStart(pluginConfigurationSize int) types.OnPluginStartStatus {
    data, err := proxywasm.GetPluginConfiguration()
    if err != nil {
        proxywasm.LogCriticalf("error reading plugin configuration: %v", err)
        return types.OnPluginStartStatusFailed
    }
    if len(data) == 0 {
        return types.OnPluginStartStatusOK
    }
 
    proxywasm.LogWarnf("plugin config: %s", string(data))
    return types.OnPluginStartStatusOK
}
```

我们可以在 `OnPluginStart` 函数中通过 `proxywasm.GetPluginConfiguration` 获取到用户的自定义配置并存储在 pluginContext 中，在后续创建 HTTPContext 时注入进去。再然后就可以在 `OnHttpRequestHeaders` 这样的函数中使用了。

#### Proxy-Wasm 架构模型

上述代码中出现了 VMContext，PluginContext，HTTPContext 这样的类型，如果不清楚具体的架构，层级的话，很容易误用。

![proxy-wasm](https://image.fatedier.com/pic/2021/2021-09-17-extend-istio-and-envoy-by-wasm-proxy-wasm.jpg)

VMContext 对应一个 wasm vm 实例，在 envoy 中通过 `vm_config` 配置。

通过 VMContext 可以创建 PluginContext，一对多的关系。通常一个 PluginContext 对应于 enovy 中的一个 Filter，也就是说，不同的 Filter 可以复用一个 VM 实例，然后使用不同的 PluginConfiguration。

通过 PluginContext 会为每一个 HTTP 和 TCP 流创建 HTTPContext 或 TCPContext 用于处理实际的请求。

### Istio 中通过 EnovyFilter 部署 wasm 扩展

当我们编译出了 wasm 文件后，需要能够部署到 sidecar 中让 enovy 使用。

这里可能会关注的一些问题:
1. 哪些服务的 sidecar 需要注入这些 wasm 模块。
2. 哪一个 wasm 文件需要被使用。
3. wasm 扩展需要被注入到 Filter Chain 中的什么位置。
4. 插件依赖的初始化配置文件在 Istio 中如何配置。
5. 如何动态更新 wasm 文件。
6. 如何动态更新配置文件。

#### EnvoyFilter 的配置

在 Istio 中，我们目前需要使用 EnovyFilter 来动态修改注入到 Istio 下发到 sidecar 中的 Enovy 配置来使用 wasm 扩展。（以后应该会有抽象的独立的 CRD 来实现）

Enovy 中 wasm 插件相关的官方文档: https://www.envoyproxy.io/docs/envoy/v1.18.4/configuration/http/http_filters/wasm_filter.html

从本地磁盘中加载 wasm 文件的完整配置:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: ingressgateway-real-ip
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      app: istio-ingressgateway
  configPatches:
    - applyTo: EXTENSION_CONFIG
      match:
        context: GATEWAY
      patch:
        operation: ADD
        value:
          name: realip
          typed_config:
            '@type': type.googleapis.com/udpa.type.v1.TypedStruct
            type_url: type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
            value:
              config:
                configuration:
                  '@type': type.googleapis.com/google.protobuf.StringValue
                  value: |
                    10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
                vm_config:
                  vm_id: realip
                  code:
                    local:
                      filename: /wasm/realip-go.wasm
                  runtime: envoy.wasm.runtime.v8
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.http_connection_manager
      patch:
        operation: INSERT_BEFORE
        value:
          name: realip
          config_discovery:
            config_source:
              ads: {}
              initial_fetch_timeout: 0s
            type_urls: [ "type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm"]
```

workloadSelector 指定了该配置需要应用在哪些 pod 上，比如这里可以限定只在网关生效。

configuration 中我们可以配置任意的字符串，该部分配置信息会被传入 wasm 模块中使用。

上述 yaml 配置中包含了两个 Filter。

第二个 HTTP_FILTER 作用于 gateway 代理中，这里使用了 enovy 的 configDiscovery 的功能，可以从 ads 中获取配置信息，而不是直接定义，后面会说明为什么这么做。这里要获取的配置名称为 `realip`。需要注意的是 `initial_fetch_timeout` 被设置为 0s，这个是必须的，这样在初始化配置时，如果没有从 ads 中拉取到这个 Filter 的配置，则会一直等待，避免了由于拉取配置失败而启动后响应出错的问题。

第一个 EXTENSION_CONFIG Patch 中，则是实际的 realip 这个 filter 的定义。格式参考 enovy 的 API 即可。目前支持 local 和 remote 两种拉取 wasm 文件的方式，local 就是指定本地磁盘的路径(需要采用其他方式将 wasm 文件注入到 sidecar 容器的指定目录上)，remote 可以指定一个远端的 HTTP/HTTPS URL。

Remote 的配置如下:

```yaml
vm_config:
  vm_id: realip
  code:
    remote:
      http_uri:
        uri: http://storage.example.com/realip.wasm
        timeout: 10s
        sha256: <WASM-MODULE-SHA>
  runtime: envoy.wasm.runtime.v8
```

采用 remote 的方式，可以直接拉取远端的 wasm 文件到容器中。sha256 值非必须，但是建议配置，不仅是校验的作用，还对于文件缓存有帮助，这样当配置有变更时，如果 wasm 文件没有变化，istio-agent 就不需要重新去拉取文件。

在 Istio 1.9 版本之前，没有采用 configDiscovery 的方式配置，会有潜在的拉取 wasm 文件失败从而导致影响到入口请求的问题。Istio 1.9 版本中对这一部分做了优化，关于如何拉取 wasm 文件这部分的优化，可以在 https://istio.io/latest/blog/2021/wasm-progress/ 这篇文章中找到更详细的说明。

设计文档: https://docs.google.com/document/d/1-IFziAJYaxQdcbXGyenF6gvVFB-20aPTm5XkwlmcNac/edit#heading=h.xw1gqgyqs5b

![module-fetch](https://image.fatedier.com/pic/2021/2021-09-17-extend-istio-and-envoy-by-wasm-module-fetch.jpg)

1. Istiod 获取到 EnvoyFilter 中关于 wasm 的配置。
2. 通过 ECDS config 指定 wasm 模块配置，下发给 sidecar 中的 istio-agent。
3. istio-agent 会检查 cache 中是否已经存在该 wasm 文件。
4. istio-agent 检查如果 cache 中没有，则从远端下载，并存入 cache。
5. 确保 wasm 文件下载完成后再将配置更新到 envoy。enovy 如果在启动过程中，没有获取到 wasm 配置前不会接收请求。

#### 模块与配置更新

EnovyFilter 中的 wasm 文件路径以及 configuration 都可以被动态修改。

配置的更新不需要重新启动 wasm 的 vm，相对来说比较轻量。wasm 文件的更新需要启动新的 vm。如果模块拉取失败，则仍然会使用旧的 vm，后续的请求不会失败。

### Istio 中如何分发 WASM 文件

在 Istio 中，需要有一套稳定可靠的机制，将指定版本的 wasm 文件推送给 sidecar，供 enovy 使用。

#### Init Container

将 wasm 文件打包为镜像，可以使用体积很小的基础镜像。

在需要注入此插件的服务的 Deployment 中增加 init container，将 wasm 文件拷贝到一处共享目录。Enovy sidecar 也 mount 这个共享目录。

在 EnovyFilter 中指定 wasm 文件路径为这个共享目录。

优点: 简单，安全可靠，利用镜像来存储和分发 wasm 文件，不需要额外的开发和管理成本。
缺点: wasm 文件后续无法动态更新，更新版本需要更新服务的 Deployment。并且增加 init container 增加了少量的容器启动时间。

#### Daemonset and Local FileSystem

目前 Istio 社区和阿里云的 ASM 提供的方案，社区的版本还不是很成熟。

在集群中创建一个 DaemonSet，每一个节点有一个 Pod 负责根据 CRD 拉取对应的 wasm 文件(目前主流的方案是以 OCI Image Spec 的格式存储)，以及反馈拉取信息，文件存放到宿主机的指定目录中。

EnovySidecar 固定挂载宿主机的指定目录到容器中。

EnovyFilter 中指定 wasm 文件路径为挂载到容器中的路径。

另外定义一个新的 CRD，指定 EnovyFilter 配置和 wasm 镜像。由一个独立的控制器，根据 wasm 文件拉取信息进行管理，只有当所有需要的节点都拉取完成后，才会去创建 EnovyFilter。

优点: 支持动态更新，节点级别的 cache，减少重复的拉取和存储。
缺点: 需要额外的开发和维护成本。

#### Remote HTTP URL

在集群内部部署一个 wasm 文件的存储服务，对外提供 HTTP 接口。

EnvoyFilter 中配置 remote 地址为这个内部服务的 service 地址。

Istio sidecar 中的 istio-agent 会做拉取和缓存的工作。并且确保在拉取成功后才将 wasm 扩展的配置推送给 enovy。

优点: 使用简单，支持动态更新扩展版本。
缺点: 可靠性还是稍差，主要体现在容器启动过程中。如果 wasm 扩展存储服务出现问题，会导致所有包含 istio sidecar 的 pod 都无法正常工作。

### 性能测试

这里通过 golang 实现了一个类似 nginx 中获取真实 IP 的扩展，可以通过配置指定可信代理的 IP 段，大概 50 个左右。之后从 X-Forwarded-For 的 IP 列表中，从后往前，过滤掉在可信 IP 段的 IP，之后将最右边保留下的 IP 作为真实 IP 重新写会 X-Forwarded-For header 中传递给后续的服务。

我们测试单线程发送 20000 个请求，响应 body 体为 10KB，同时记录总耗时和一些资源消耗，调整网关副本数为 1，便于观测 CPU 和内存消耗。

无 wasm 扩展注入: 0.24C 28.7s 平均 1.435ms

注入 wasm 扩展后: 0.25C 29.6s 平均 1.48ms

可以看出，引入 wasm 扩展后，CPU 消耗增加了约 5% ，延迟增加了 0.045ms。由于计算真实 IP 的功能本身也需要一定的计算量，会引入一些延迟，所以同样的功能，使用原生代码扩展和使用 wasm 的扩展之间的差距应该更小。目前在一些基础功能的实现上，性能是完全可以接受的。

### Istio 关于 wasm 未来的计划

* 目前是通过 EnvoyFilter 来配置，之后计划会提供独立的 CRD/API 来方便使用。
* 标准化 wasm 模块的定义，分发。目前有一套 OCI Image Spec，定义好后，可以标准化模块的编译，上传，下载和执行，有利于统一这一部分的基础设施的实现。
* 通过 CSI Ephemeral Inline Volumes 实现 wasm 模块的分发，类似于上面提到的通过 Daemonset 统一下载然后挂载到 sidecar 容器的方式。
