---
categories:
    - "技术文章"
tags:
    - "golang"
date: 2016-04-27
title: "go程序中dns解析无法使用所有域名服务器"
url: "/2016/04/27/go-program-does-not-use-all-nameservers-for-dns-lookups"
---

最近线上服务经常会出现异常，从错误日志来看是因为域名解析失败导致的，我们在 /etc/resolv.conf 中配置了多个域名服务器，第一个是内网的，用于解析内网域名，如果是外网域名，则会通过其他的域名服务器进行解析，按道理来说应该不会有问题，但是最近却频繁发生这样的故障，为了彻底解决问题，特意研究了一下 golang 中进行 dns 查询的源码并最终解决了此问题。

<!--more-->

### 背景

#### nameserver 配置

`/etc/resolv.conf` 中配置了多个 nameserver

```bash
nameserver 10.10.100.3
nameserver 114.114.114.114
nameserver 8.8.8.8
```

`10.10.100.3` 用于解析内网域名，外网域名通过 `114.114.114.114` 或者 `8.8.8.8` 来解析。

#### 测试代码

```golang
package main

import (
    "net"
    "fmt"
)

func main() {
    hostname := "www.baidu.com"
    addrs, err := net.LookupHost(hostname)
    if err != nil {
        fmt.Printf("lookup host error: %v\n", err)
    } else {
        fmt.Printf("addrs: %v", addrs)
    }   
}
```

#### 结果

```bash
lookup host error: lookup www.baidu.com on 10.10.100.3:53: no such host
```

使用 go1.5 版本进行编译，发现程序并没有按照预想的过程来解析，通过 `10.10.100.3` 无法解析后就直接返回了错误信息。

而使用 go1.4 版本编译运行后，确得到了正确的结果。

### 调试标准库的方法

调试 golang 的标准库非常简单，先找到标准库源码的存放位置，然后将要修改的文件备份一份，之后直接在其中添加输出语句，大部分可以 `import "fmt"` 后使用 `fmt.Printf` 函数进行输出，有的包中需要使用其他方式，避免循环引用，这里不详述，因为我们要改的 `net` 包并不涉及这个问题，注意调试完之后将标准库的文件恢复。

#### 查找标准库所在的目录

执行 `go env` 查看 go 的环境变量如下：

```bash
GOARCH="amd64"
GOBIN=""GOCHAR="6"GOEXE=""GOHOSTARCH="amd64"GOHOSTOS="linux"GOOS="linux"
GOPATH="/home/wcl/go_projects"
GORACE=""
GOROOT="/usr/lib/golang"
GOTOOLDIR="/usr/lib/golang/pkg/tool/linux_amd64"
CC="gcc"
GOGCCFLAGS="-fPIC -m64 -pthread -fmessage-length=0"
CXX="g++"
CGO_ENABLED="1"
```

**GOROOT** 的值即是标准库所在的目录，`net` 包的具体路径为 `/usr/lib/golang/src/net`

### go 1.4 与 1.5 版本中 dns 查询逻辑的不同

因为最近很多程序都是使用 **go1.5** 版本进行编译的，所以理所当然查看了两个版本这部分源码的区别，还真的有所改变。

标准库对外暴露的 dns 查询函数是 `func LookupHost(host string) (addrs []string, err error)` **(net/lookup.go)**

这个函数会调用实际处理函数 `lookupHost` **(net/lookup_unix.go)**

#### cgo 与纯 go 实现的 dns 查询

**go1.4 版本源码**

```golang
func lookupHost(host string) (addrs []string, err error) {
    addrs, err, ok := cgoLookupHost(host)
    if !ok {
        addrs, err = goLookupHost(host)
    }
    return
}
```

**go1.5 版本源码**

```golang
func lookupHost(host string) (addrs []string, err error) {
    order := systemConf().hostLookupOrder(host)
    if order == hostLookupCgo {
        if addrs, err, ok := cgoLookupHost(host); ok {
            return addrs, err
        }
        // cgo not available (or netgo); fall back to Go's DNS resolver
        order = hostLookupFilesDNS
    }
    return goLookupHostOrder(host, order)
}
```

**可以明显的看到 1.4 的源码中默认使用 cgo 的方式进行 dns 查询**（这个函数最终会创建一个线程调用c的 getaddrinfo 函数来获取 dns 查询结果），如果查询失败则会再使用纯 go 实现的查询方式。

**而在 1.5 的源码中，这一点有所改变，cgo 的方式不再是默认值，而是根据 `systemConf().hostLookupOrder(host)` 的返回值来判断具体使用哪种方式**。这个函数定义在 **net/conf.go** 中，稍微看了一下， 除非通过编译标志强制使用 cgo 方式或者在某些特定的系统上会使用 cgo 方式，其他时候都使用纯 go 实现的查询方式。

cgo 的方式没有问题，看起来程序会并发地向 `/etc/resolv.conf` 中所有配置的域名服务器发送 dns 解析请求，然后将最先成功响应的结果返回。

#### 纯 go 实现的 dns 查询分析

问题就出在纯 go 实现的查询上，主要看一下 go1.5 的实现。

函数调用逻辑如下：

```bash
LookupHost (net/lookup.go)
    lookupHost  (net/lookup_unix.go)
        goLookupHostOrder  (net/dnsclient_unix.go)
            goLookupIPOrder  (net/dnsclient_unix.go)
                tryOneName   (net/dnsclient_unix.go)
```

大部分实现代码在 `net/dnsclient_unix.go` 这个文件中。

重点看一下 `tryOneName` 这个函数

```golang
func tryOneName(cfg *dnsConfig, name string, qtype uint16) (string, []dnsRR, error) {
    if len(cfg.servers) == 0 {
        return "", nil, &DNSError{Err: "no DNS servers", Name: name}
    }
    if len(name) >= 256 {
        return "", nil, &DNSError{Err: "DNS name too long", Name: name}
    }
    timeout := time.Duration(cfg.timeout) * time.Second
    var lastErr error
    for i := 0; i < cfg.attempts; i++ {
        for _, server := range cfg.servers {
            server = JoinHostPort(server, "53")
            msg, err := exchange(server, name, qtype, timeout)
            if err != nil {
                lastErr = &DNSError{
                    Err:    err.Error(),
                    Name:   name,
                    Server: server,
                }
                if nerr, ok := err.(Error); ok && nerr.Timeout() {
                    lastErr.(*DNSError).IsTimeout = true
                }
                continue
            }
            cname, rrs, err := answer(name, server, msg, qtype)
            if err == nil || msg.rcode == dnsRcodeSuccess || msg.rcode == dnsRcodeNameError && msg.recursion_available {
                return cname, rrs, err
            }
            lastErr = err
        }
    }
    return "", nil, lastErr
}
```

第一层 for 循环是尝试的次数，第二层 for 循环是遍历 `/etc/resolv.conf` 中配置的所有域名服务器，`exchange` 函数是发送 dns 查询请求并将响应结果解析到 `msg` 变量中返回，初看到这里，觉得实现是没问题的，顺序向每一个域名服务器发送 dns 查询请求，如果成功就返回，如果失败就尝试下一个。

问题出现在判断是否成功的那一行代码 `if err == nil || msg.rcode == dnsRcodeSuccess || msg.rcode == dnsRcodeNameError && msg.recursion_available`，这里的意思是如果 dns 查询成功，或者出错了但是对方支持递归查询的话，就直接返回，不继续请求下一个域名服务器。如果对方支持递归查询但是仍然没有查到的话，说明上级服务器也没有这个域名的记录，没有必要继续往下查。（这个逻辑在 go1.6 版本中被修改了，出错了以后不再判断是否支持递归查询，仍然尝试向下一个域名服务器发送请求）

`msg.rcode` 这个值很重要，是问题的关键，

### dns 查询协议格式

![dns-query-package](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-04-27-go-program-does-not-use-all-nameservers-for-dns-lookups-dns-query-package.png)

我们只需要关注首部的12字节。

* ID:占16位，2个字节。此报文的编号，由客户端指定。DNS回复时带上此标识，以指示处理的对应请应请求。 
* QR:占1位，1/8字节。0代表查询，1代表DNS回复 
* Opcode:占4位，1/2字节。指示查询种类：0:标准查询；1:反向查询；2:服务器状态查询；3-15:未使用。 
* AA:占1位，1/8字节。是否权威回复。 
* TC:占1位，1/8字节。因为一个UDP报文为512字节，所以该位指示是否截掉超过的部分。 
* RD:占1位，1/8字节。此位在查询中指定，回复时相同。设置为1指示服务器进行递归查询。 
* RA:占1位，1/8字节。由DNS回复返回指定，说明DNS服务器是否支持递归查询。 
* Z:占3位，3/8字节。保留字段，必须设置为0。 
* RCODE:占4位，1/2字节。由回复时指定的返回码：0:无差错；1:格式错；2:DNS出错；3:域名不存在；4:DNS不支持这类查询；5:DNS拒绝查询；6-15:保留字段。　 
* QDCOUNT:占16位，2字节。一个无符号数指示查询记录的个数。 
* ANCOUNT:占16位，2字节。一个无符号数指明回复记录的个数。 
* NSCOUNT:占16位，2字节。一个无符号数指明权威记录的个数。 
* ARCOUNT:占16位，2字节。一个无符号数指明格外记录的个数。

其中 **RCODE** 是回复时用于判断查询结果是否成功的，对应前面的 `msg.rcode`。

### bind 的 dns 回复问题

`10.10.100.3` 上是使用 **bind** 搭建的本地域名服务器。

使用 `dig @10.10.100.3 www.baidu.com` 命令查看解析结果如下：

```bash
; <<>> DiG 9.8.2rc1-RedHat-9.8.2-0.23.rc1.el6_5.1 <<>> @10.10.100.3 www.baidu.com ;
(1 server found) 
;; global options: +cmd 
;; Got answer: 
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 55909 
;; flags: qr rd; QUERY: 1, ANSWER: 0, AUTHORITY: 13, ADDITIONAL: 0 
;; WARNING: recursion requested but not available 

;; QUESTION SECTION: 
;www.baidu.com.         IN  A 

;; AUTHORITY SECTION: 
.           518400  IN  NS  H.ROOT-SERVERS.NET.  
.           518400  IN  NS  K.ROOT-SERVERS.NET.  
.           518400  IN  NS  C.ROOT-SERVERS.NET.  
.           518400  IN  NS  A.ROOT-SERVERS.NET.  
.           518400  IN  NS  B.ROOT-SERVERS.NET.  
.           518400  IN  NS  F.ROOT-SERVERS.NET.  
.           518400  IN  NS  L.ROOT-SERVERS.NET.  
.           518400  IN  NS  D.ROOT-SERVERS.NET.  
.           518400  IN  NS  I.ROOT-SERVERS.NET.  
.           518400  IN  NS  E.ROOT-SERVERS.NET.  
.           518400  IN  NS  G.ROOT-SERVERS.NET.  
.           518400  IN  NS  M.ROOT-SERVERS.NET.  
.           518400  IN  NS  J.ROOT-SERVERS.NET.  

;; Query time: 1 msec 
;; SERVER: 10.10.100.3#53(10.10.100.3) 
;; WHEN: Wed Apr 27 17:35:15 2016 
;; MSG SIZE  rcvd: 242 
``` 

**bind** 并没有返回 `www.baidu.com` 的 A 记录，而是返回了13个根域名服务器的地址，并且 **status** 的状态是 **NOERROR**（这个值就是前述的 **RCODE**，这里没有错误正则为 0)，问题就在这里，没有查到 A 记录还返回 `RCODE=0`，回顾一下上面 go 代码中的判断条件

`if err == nil || msg.rcode == dnsRcodeSuccess || msg.rcode == dnsRcodeNameError && msg.recursion_available`

如果返回的 **RCODE** 值为 0，则直接退出，不继续尝试后面的域名服务器，从而导致了域名解析失败。

### 解决方案

#### 仍然使用 go1.4 版本进行编译

不推荐这么做，毕竟升级后在 gc 以及很多其他方面都有优化。 

#### 使用 go1.5 及以上版本编译但是通过环境变量强制使用 cgo 的 dns 查询方式

`export GODEBUG=netdns=cgo go build`

使用 cgo 的方式会在每一次调用时创建一个线程，在并发量较大时可能会对系统资源造成一定影响。而且需要每一个使用 go 编写的程序编译时都加上此标志，较为繁琐。 

#### 修改 bind 的配置文件

在 **bind** 中彻底关闭对递归查询的支持也可以解决此问题，但是由于对 **bind** 不是很熟悉，具体是什么原因导致没有查到 **A 记录**但仍然返回 **NOERROR** 不是很清楚，猜测可能和递归转发的查询方式有关，有可能 **bind** 认为返回了根域名服务器的地址，**client** 可以去这些地址上查，所以该次请求并不算做出错。

修改配置文件加上以下内容以后，再次查询时会返回 **RCODE=5**，拒绝递归查询，这样可以达到我们的目的，查询非内网域名时通过其他域名服务器查询

```bash
recursion no;
allow-query-cache { none; };
allow-recursion { none; };
```
