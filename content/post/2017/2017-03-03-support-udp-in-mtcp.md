---
categories:
    - "技术文章"
tags:
    - "linux"
    - "c/cpp"
date: 2017-03-03
title: "为 mtcp 项目添加 udp 支持"
url: "/2017/03/03/support-udp-in-mtcp"
---

mtcp 是一个用户态的 tcp 协议栈，结合 dpdk 可以实现高性能的收发包。mtcp 不支持 udp 协议，想要在 bind 里利用 mtcp 进行加速，需要改动源码以提供支持。

<!--more-->

### 大致思路

mtcp 项目地址：https://github.com/mtcp-stack/mtcp

我们需要实现和 udp 数据收发相关的函数，提供给其他程序使用的 SDK。各个所需函数的实现方式如下。

`mtcp_socket()`

创建 socket 对象，对象池数组，分配一个与其他 socket 对象不冲突的 id(fd)。

`mtcp_bind()`

将绑定的本地 IP 地址和端口等数据写入 socket 对象，将此 socket 对象的地址放入一个存放正在监听中的 socket 对象的 hashmap。

需要创建一个 hashmap，存放所有处于监听状态的 socket 对象，key 是本地 IP，Port。

### UDP 数据包的接收

解析到 以太网帧 -> ip -> udp

解析出目的 ip，port，检查 hashmap 中是否有正处于监听状态的 socket 对象，如果没有，丢弃，否则加入到该 socket 对象的读缓冲区（这里需要一个队列）。

调用 pthread_cond_singal 唤醒处于 recvfrom 的线程，或者是 epoll 队列中有该socket 的可读事件监听，pthread_cond_singal 唤醒 mtcp_epoll_wait 线程。

#### mtcp_recvfrom()

1. 不使用 epoll，阻塞：使用 pthread_cond_wait 等待主线程轮询网卡数据包，有此socket 的 udp 包的时候会被唤醒，从读缓冲区中取出内容返回。
2. 不使用 epoll，非阻塞：直接查询监听中socket-hashmap的此socket的读缓冲区，取出内容并返回。
3. 使用 epoll（非阻塞）：将此 socket 的可读事件加入监听，epoll_wait 被唤醒，检查到可读事件，非阻塞模式读缓冲区内容。

#### mtcp_sendto()

1. 不使用 epoll，阻塞：如果此 socket 的写缓冲区未满，直接写入并返回，如果已满（需要等到有空间后被唤醒，考虑 socket 对象需要加一个 send_wait_list，统一触发）
2. 不使用 epoll，非阻塞：已满就返回错误。
3. 使用 epoll（非阻塞）：将可写事件加入 epoll 事件队列，当 socket 可写时写入缓冲区。
（如果原来写缓冲区是空的，现在有内容了，加入到一个全局的 send_list 队列中）

如果此 socket 的 udp_stream 为 NULL，说明是一个客户端的 socket，创建一个新的udp_stream，分配一个随机的 udp 端口，加入到正在监听中的 socket 对象的 hashmap。

### udp 数据包发送

这里需要一开始创建一个全局的 udp_sender 对象，有一个 send_list 队列，存放需要发送数据的所有的 socket 对象。

轮询这些 socket 对象，构造数据包，udp -> ip -> 以太网帧，调用 dpdk 发送包的接口。

### 主线程循环

* udp 数据包的接收
* udp 数据包发送
