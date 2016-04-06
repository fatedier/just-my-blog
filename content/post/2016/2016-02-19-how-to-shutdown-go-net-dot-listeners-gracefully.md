---
categories:
    - "技术文章"
tags:
    - "go"
date: 2016-02-19
title: "Go中如何优雅地关闭net.Listener"
url: "/2016/02/19/how-to-shutdown-go-net-dot-listeners-gracefully"
---

在开发一个 Go 语言写的服务器项目的时候，遇到一个很有意思的问题，这个程序会根据客户端的请求动态的监听本地的一个端口，并且与客户端交互结束后需要释放这个端口。Go 的标准库提供了常用的接口，开发网络服务非常方便，网上随便就可以找到很多样例代码。

<!--more-->

但是我在释放这个监听端口的时候遇到了一些问题，我发现很难优雅地去关闭这个 **net.Listener**。在网上查阅了一下资料，基本上都是程序结束时资源被系统自动回收，没发现有需要主动释放的。这个需求确实不多，不过想一下在写测试用例的时候或许可能会用到，我们先创建一个 **net.Listener** 监听一个端口，**client** 发送请求进行测试，通过后关闭这个 **net.Listener**，再创建另外一个 **net.Listener** 用于测试其他用例。

初步思考了一下有两个办法来关闭 **net.Listener**：

1. 设置一个结束标志，为 **net.Listener** 的 `accept` 设置超时，**net.Listener** 提供了一个 `SetDeadline(t time.Time)` 接口，需要关闭时将标志置为 **true**，每次超时后检查一下结束标志，如果为 **true** 则退出。
2. 在另外一个协程中 **close net.Listener**，检查 `accept` 返回的 **error** 信息，如果是被 **close** 的话就退出，其他情况就继续。

第一个方法很显然不够优雅，在大并发量连接请求时对效率有很大影响，而且退出机制是延迟的，不能及时退出。

第二个方法的问题就在于如果 **close net.Listener**，`accept` 函数返回的 **error** 信息只能拿到错误的字符串信息，如果是被 **close** 的话返回的信息是：`use of closed network connection`，这个时候退出监听，如果是其他错误，则继续监听。想法是好的，然而并不能用错误信息的字符串来判断是哪一种类型的错误，有可能以后的版本中错误信息字符串变更也说不定，最好不要在代码中写死。这个 **error** 其实是有类型的，在标准库中是 `errClosing`，开头小写，说明只能在包内部使用，我们没有办法使用这个类型来判断具体是哪一种错误。个人觉得这方面可能还没有 **c语言** 中通过 **errno** 的值来判断是哪一种类型的错误来的方便。

既然不能通过 **error** 的字符串信息判断是哪一种错误，那么我们只能用类似第一个方法中使用的标志来判断了，先将结束标志置为 **true**，之后 **close net.Listener**，`accept` 函数返回 `error != nil` 时，检查结束标志，如果为 **true** 就退出，这样相比较第一个方法退出时就没有延迟了，参考代码如下：

```go
package main

import (
    "fmt"
    "net"
    "time"
)

var (
    ln        net.Listener
    closeFlag bool = false
)

func startServer() (err error) {
    ln, err = net.Listen("tcp", ":12345")
    if err != nil {
        return err
    }
    defer ln.Close()

    for {
        conn, err := ln.Accept()
        if err != nil {
            fmt.Printf("accept error: %v\n", err)
            if closeFlag {
                break
            } else {
                continue
            }
        } else {
            conn.Close()
        }
    }
    return nil
}

func main() {
    go startServer()
    time.Sleep(1 * time.Second)
    closeFlag = true
    ln.Close()
    time.Sleep(1 * time.Second)
}
```
