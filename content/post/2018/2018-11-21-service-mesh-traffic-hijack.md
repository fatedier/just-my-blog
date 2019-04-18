---
categories:
    - "技术文章"
tags:
    - "kubernetes"
    - "service mesh"
date: 2018-11-21
title: "Service Mesh 探索之流量劫持"
url: "/2018/11/21/service-mesh-traffic-hijack"
---

Istio 的项目中有一个亮点就是可以将旧的应用无缝接入到 Service Mesh 的平台上来，不用修改一行代码。实现这个功能，目前主要是通过 iptables 来截获流量转发给 proxy。

<!--more-->

### 如何实现？

参考 Istio 的实现方式，我们可以自己设计一个简单的流量劫持的方案。

要做哪些事？

* 首先要有一个支持透明代理的 proxy，处理被劫持的流量，能够获取到连接建立时的原来的目的地址。在 k8s 中这个 proxy 采用 sidecar 的方式和要劫持流量的服务部署在一个 Pod 中。
* 通过 iptables 将我们想要劫持的流量劫持到 proxy 中。proxy 自身的流量要排除在外。
* 要实现零侵入，最好不修改服务的镜像，在 k8s 中可以采用 Init 容器的方式在应用容器启动之前做 iptables 的修改。

#### 透明代理

proxy 作为一个透明代理，对于自身能处理的流量，会经过一系列的处理逻辑，包括重试，超时，负载均衡等，再转发给对端服务。对于自身不能处理的流量，会直接透传，不作处理。

通过 iptables 将流量转发给 proxy 后，proxy 需要能够获取到原来建立连接时的目的地址。在 Go 中的实现稍微麻烦一些，需要通过 `syscall` 调用来获取，

示例代码:

```golang
package redirect

import (
    "errors"
    "fmt"
    "net"
    "os"
    "syscall"
)

const SO_ORIGINAL_DST = 80

var (
    ErrGetSocketoptIPv6 = errors.New("get socketopt ipv6 error")
    ErrResolveTCPAddr   = errors.New("resolve tcp address error")
    ErrTCPConn          = errors.New("not a valid TCPConn")
)

// For transparent proxy.
// Get REDIRECT package's originial dst address.
// Note: it may be only support linux.
func GetOriginalDstAddr(conn *net.TCPConn) (addr net.Addr, c *net.TCPConn, err error) {
    fc, errRet := conn.File()
    if errRet != nil {
        conn.Close()
        err = ErrTCPConn
        return
    } else {
        conn.Close()
    }
    defer fc.Close()

    mreq, errRet := syscall.GetsockoptIPv6Mreq(int(fc.Fd()), syscall.IPPROTO_IP, SO_ORIGINAL_DST)
    if errRet != nil {
        err = ErrGetSocketoptIPv6
        c, _ = getTCPConnFromFile(fc)
        return
    }

    // only support ipv4
    ip := net.IPv4(mreq.Multiaddr[4], mreq.Multiaddr[5], mreq.Multiaddr[6], mreq.Multiaddr[7])
    port := uint16(mreq.Multiaddr[2])<<8 + uint16(mreq.Multiaddr[3])
    addr, err = net.ResolveTCPAddr("tcp4", fmt.Sprintf("%s:%d", ip.String(), port))
    if err != nil {
        err = ErrResolveTCPAddr
        return
    }

    c, errRet = getTCPConnFromFile(fc)
    if errRet != nil {
        err = ErrTCPConn
        return
    }
    return
}

func getTCPConnFromFile(f *os.File) (*net.TCPConn, error) {
    newConn, err := net.FileConn(f)
    if err != nil {
        return nil, ErrTCPConn
    }

    c, ok := newConn.(*net.TCPConn)
    if !ok {
        return nil, ErrTCPConn
    }
    return c, nil
}
```

通过 `GetOriginalDstAddr` 函数可以获取到连接原来的目的地址。

这里需要格外注意的是，当启用 iptables 转发后，proxy 如果接收到直接访问自己的连接时，会识别到自身不能处理，会再去连接此目的地址(就是自己绑定的地址)，这样就会导致死循环。所以在服务启动时，需要将目的地址为自身 IP 的连接直接断开。

#### Sidecar

使用 Sidecar 模式部署服务网格时，会在每一个服务身边额外启一个 proxy 去接管容器的部分流量。在 kubernetes 中一个 Pod 可以有多个容器，这多个容器可以共享网络，存储等资源，从概念上将服务容器和 proxy 容器部署成一个 Pod，proxy 容器就相当于是 sidecar 容器。

我们通过一个 Deployment 来演示，这个 Deployment 的 yaml 配置中包括了 test 和 proxy 两个 container，它们共享网络，所以登录 test 容器后，通过 `127.0.0.1:30000` 可以访问到 proxy 容器。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test
  namespace: default
  labels:
    app: test
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: test
        image: {test-image}
        ports:
          - containerPort: 9100
      - name: proxy
        image: {proxy-image}
        ports:
          - containerPort: 30000    
```

为每一个服务都编写 sidecar 容器的配置是一件比较繁琐的事情，当架构成熟后，我们就可以利用 kubernetes 的 `MutatingAdmissionWebhook` 功能，在用户创建 Deployment 时，主动注入 sidecar 相关的配置。

例如，我们在 Deployment 的 annotations 中加入如下的字段:

```yaml
annotations:
  xxx.com/sidecar.enable: "true"
  xxx.com/sidecar.version: "v1"
```

表示在此 Deployment 中需要注入 v1 版本的 sidecar。当我们的服务收到这个 webhook 后，就可以检查相关的 annotations 字段，根据字段配置来决定是否注入 sidecar 配置以及注入什么版本的配置，如果其中有一些需要根据服务改变的参数，也可以通过这种方式传递，极大地提高了灵活性。

#### iptables

通过 iptables 我们可以将指定的流量劫持到 proxy，并将部分流量排除在外。

```
iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner 9527 -j RETURN
iptables -t nat -A OUTPUT -p tcp -d 172.17.0.0/16 -j REDIRECT --to-port 30000
```

上面的命令，表示将目标地址是 `172.17.0.0/16` 的流量 `REDIRECT` 到 30000 端口(proxy 所监听的端口)。但是 UID 为 9527 启动的进程除外。`172.17.0.0/16` 这个地址是 k8s 集群内部的 IP 段，我们只需要劫持这部分流量，对于访问集群外部的流量，暂时不劫持，如果劫持全部流量，对于 proxy 不能处理的请求，就需要通过 iptables 的规则去排除。

#### Init 容器

前文说过为了实现零侵入，我们需要通过 Init 容器的方式，在启动用户服务容器之前，就修改 iptables。这部分配置也可以通过 kubernetes 的 `MutatingAdmissionWebhook` 功能注入到用户的 Deployment 配置中。

将前面 sidecar 的配置中加上 Init 容器的配置:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test
  namespace: default
  labels:
    app: test
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: test
    spec:
      initContainers:
      - name: iptables-init
        image: {iptables-image}
        imagePullPolicy: IfNotPresent
        command: ['sh', '-c', 'iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner 9527 -j RETURN && iptables -t nat -A OUTPUT -p tcp -d 172.17.0.0/16 -j REDIRECT --to-port 30000']
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
          privileged: true
      containers:
      - name: test
        image: {test-image}
        ports:
          - containerPort: 9100
      - name: proxy
        image: {proxy-image}
        ports:
          - containerPort: 30000    
```

这个 Init 容器需要安装 iptables，在启动时会执行我们配置的 iptables 命令。

需要额外注意的是 `securityContext` 这个配置项，我们加了 `NET_ADMIN` 的权限。它用于定义 Pod 或 Container 的权限，如果不配置，则 iptables 执行命令时会提示错误。

### 问题

#### 如何判断目标服务的类型

我们将 `172.17.0.0/16` 的流量都劫持到了 proxy 内部，那么如何判断目标服务的协议类型？如果不知道协议类型，就不能确定如何去解析后续的请求。

在 kubernetes 的 service 中，我们可以为每一个 service 的端口指定一个名字，这个名字的格式可以固定为 `{name}-{protocol}`，例如 `{test-http}`，表示这个 service 的某个端口是 http 协议。

```yaml
kind: Service
apiVersion: v1
metadata:
  name: test
  namespace: default
spec:
  selector:
    app: test
  ports:
    - name: test-http
      port: 9100
      targetPort: 9100
      protocol: TCP
```

proxy 通过 discovery 服务获取到 service 对应的 Cluster IP 和端口名称，这样通过目标服务的 IP 和 port 就可以知道这个连接的通信协议类型，后面就可以交给对应的 Handler 去处理。

#### Cluster IP

在 kubernetes 中创建 Service，如果没有指定，默认采用 Cluster IP 的方式来访问，kube-proxy 会为此创建 iptables 规则，将 Cluster IP 转换为以负载均衡的方式转发到 Pod IP。

当存在 Cluster IP 时，service 的 DNS 解析会指向 Cluster IP，负载均衡由 iptables 来做。如果不存在，DNS 解析的结果会直接指向 Pod IP。

proxy 依赖于 service 的 Cluster IP 来判断用户访问的是哪一个服务，所以不能设置为 `clusterIP: None`。因为 Pod IP 是有可能会经常变动的，当增减实例时，Pod IP 的集合都会改变，proxy 并不能实时的获取到这些变化。
