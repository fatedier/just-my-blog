---
categories:
    - "技术文章"
tags:
    - "kubernetes"
    - "service mesh"
date: 2019-01-12
title: "Service Mesh 探索之升级 HTTP/2 协议"
url: "/2019/01/12/service-mesh-explore-upgrade-http2"
---

HTTP/2 是 HTTP/1.1 的升级，在请求方法、状态码乃至 URI 和绝大多数 HTTP 头部字段等方面保持高度兼容性，同时能够减少网络延迟和连接资源占用。Service Mesh 架构中，由于两个服务之间的通信由 proxy 介入，对于依靠 HTTP/1.1 通信的服务来说，可以无缝升级到 HTTP/2 协议。

<!--more-->

### HTTP/2 的优势

* 对 HTTP 头字段进行数据压缩(即 HPACK 算法)。
* HTTP/2 服务端推送(Server Push)。
* 修复 HTTP/1.0 版本以来未修复的队头阻塞问题。
* 对数据传输采用多路复用，让多个请求合并在同一 TCP 连接内。

对于我们最主要的收益在于 TCP 连接的多路复用和头部字段压缩。

TCP 连接的多路复用可以有效减少连接建立的延迟。在 HTTP/1.1 中我们也会复用空闲连接的方式来解决此问题，但是通常的实现方式是一个连接池，当空闲连接超过多长时间之后会被关闭，所以并没有完全解决这一问题。

Header 字段压缩，对于内部服务来说可以有效减少请求和响应的数据大小。内部服务之间通常会在 Header 中附加较多的内容来表征一些类似标签格式的信息。经过测试，HTTP/2 使我们的内部服务在 Header 上的传输的数据量减少了 50% 以上。

### 在同一个端口上同时支持 HTTP/1.1 和 HTTP/2

HTTP/2 协议本身和 TLS 无关，但是通常浏览器 (Chrome 等) 都要求必须结合 TLS 来使用。

h2c（HTTP/2 cleartext）是不带 TLS 的 HTTP/2。对于内部 API 服务来说，TLS 并非必须，反而会增加额外的资源开销。

Go 的标准库已经支持了 h2，不支持 h2c，但是在 `golang.org/x/net/http2/h2c` 中有对 h2c 的支持，算是半个标准库。

由于 HTTP/2 和 HTTP/1.1 高度兼容，Golang 中我们需要提供的 `http.Handler` 方法并没有什么变化，所以只需要替换 `Transport` 就可以实现升级到 HTTP/2 这一能力。

#### 服务端

示例程序:

```golang
package main

import (
    "fmt"
    "log"
    "net/http"

    "golang.org/x/net/http2"
    "golang.org/x/net/http2/h2c"
)

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, "You tell %s\n", r.Proto)
    })
    h2s := &http2.Server{}
    h1s := &http.Server{Addr: ":9100", Handler: h2c.NewHandler(mux, h2s)}

    log.Fatal(h1s.ListenAndServe())
}
```

服务端会监听在 9100 端口，并且同时支持 HTTP/1.1 和 HTTP/2。

通过 curl 用不同的协议访问的输出结果如下:

```
curl http://127.0.0.1:9100
You tell HTTP/1.1

curl http://127.0.0.1:9100 --http2
You tell HTTP/2.0
```

之所以能够在同一个端口上同时支持这两个协议，是因为 `h2c.NewHandler` 这个函数的封装。这个函数会在连接建立时先检测 `Request` 的内容，h2c 要求连接以 `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` 开头，如果匹配成功则交给 h2c 的 Handler 处理，否则交给 HTTP/1.1 的 Handler 处理。

h2c 这部分的源码如下:

```golang
// ServeHTTP implement the h2c support that is enabled by h2c.GetH2CHandler.
func (s h2cHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    // Handle h2c with prior knowledge (RFC 7540 Section 3.4)
    if r.Method == "PRI" && len(r.Header) == 0 && r.URL.Path == "*" && r.Proto == "HTTP/2.0" {
        if http2VerboseLogs {
            log.Print("h2c: attempting h2c with prior knowledge.")
        }
        conn, err := initH2CWithPriorKnowledge(w)
        if err != nil {
            if http2VerboseLogs {
                log.Printf("h2c: error h2c with prior knowledge: %v", err)
            }
            return
        }
        defer conn.Close()

        s.s.ServeConn(conn, &http2.ServeConnOpts{Handler: s.Handler})
        return
    }
    // Handle Upgrade to h2c (RFC 7540 Section 3.2)
    if conn, err := h2cUpgrade(w, r); err == nil {
        defer conn.Close()

        s.s.ServeConn(conn, &http2.ServeConnOpts{Handler: s.Handler})
        return
    }

    s.Handler.ServeHTTP(w, r)
    return
}
```

#### 客户端

由于我们的服务端同时支持 HTTP/1.1 和 HTTP/2，所以客户端可以通过任意的协议来通信，最好通过配置或环境变量的方式来决定是否启用升级 HTTP/2 的功能，后面会讲一下这个里面存在的坑。

客户端的示例代码:

```golang
package main

import (
    "crypto/tls"
    "fmt"
    "log"
    "net"
    "net/http"

    "golang.org/x/net/http2"
)

func main() {
    client := http.Client{
        // Skip TLS dial
        Transport: &http2.Transport{
            AllowHTTP: true,
            DialTLS: func(network, addr string, cfg *tls.Config) (net.Conn, error) {
                return net.Dial(network, addr)
            },
        },
    }
    resp, err := client.Get("http://127.0.0.1:9100")
    if err != nil {
        log.Fatal(fmt.Errorf("get response error: %v", err))
    }
    fmt.Println(resp.StatusCode)
    fmt.Println(resp.Proto)
}
```

http2.Transport 本身没有提供 `Dial` 方法来不启用 TLS，但是由于 HTTP/2 和 TLS 无关，只需要将 `DialTLS` 替换成我们自己方法，不建立 TLS 连接，对上层的 HTTP/2 的协议处理完全没有影响。

### 遇到的问题

实际上线此功能后，运行了两天，出现了服务超时的问题，排查后看起来和 https://github.com/golang/go/issues/28204 这个 issue 比较相似。

目前 Golang 标准库(Go1.11)中对于 HTTP/2 的流量控制在某些特殊场景下存在 Bug，会导致 Flow Control 的写窗口一直为 0，且无法恢复。这就导致了请求超时，并且复用的 Stream 没有被正常关闭，如果持续请求，默认单个 TCP 连接中存在 100 个 Stream 时，会新建一个 TCP 连接，此时后续的请求会恢复正常，但是如果又出现了有问题的请求，会重复之前的错误。

由于时间原因，并没有继续跟踪源码查看问题到底在哪，因为本地环境经过大量并发测试也并没有出现问题，说明应该是一个比较极端的 case 导致了这个错误。后续有精力时，可以考虑在线上开启流量复制的功能，将流量额外复制一份到单独版本的实例上，这个版本可以开启更多的 Debug 日志来辅助调试。

线上暂时关闭了此功能，待问题确认修复后再通过环境变量控制开启。
