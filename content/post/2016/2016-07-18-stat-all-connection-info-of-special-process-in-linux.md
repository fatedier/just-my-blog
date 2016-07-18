---
categories:
    - "技术文章"
tags:
    - "linux"
date: 2016-07-18
title: "linux下查看指定进程的所有连接信息"
url: "/2016/07/18/stat-all-connection-info-of-special-process-in-linux"
---

定位某个进程的网络故障时经常需要用到的一个功能就是查找所有连接的信息。通常查找某个端口的连接信息使用 ss 或者 netstat 可以轻松拿到，如果是主动与别的机器建立的连接信息则可以通过 lsof 命令来获得。

<!--more-->

例如我想要查看进程 `frps` 当前的所有连接信息，先获得进程的 pid：

`ps -ef|grep frps`

结果为：

```bash
wcl       4721     1  0 10:27 ?        00:00:01 ./frps
```

可以看到进程 pid 为 **4721**，之后通过 lsof 命令查看所有 TCP 连接信息：

`lsof -p 4721 -nP | grep TCP`

显示结果为：

```bash
frps    4721  wcl    4u     IPv6 117051764      0t0     TCP *:7000 (LISTEN)
frps    4721  wcl    6u     IPv6 117051765      0t0     TCP *:7003 (LISTEN)
frps    4721  wcl    7u     IPv6 117092563      0t0     TCP 139.129.11.120:7000->116.231.70.223:61545 (ESTABLISHED)
frps    4721  wcl    8u     IPv6 117092565      0t0     TCP *:6000 (LISTEN)
frps    4721  wcl    9u     IPv6 117334426      0t0     TCP 139.129.11.120:7000->116.237.93.230:64898 (ESTABLISHED)
frps    4721  wcl   10u     IPv6 117053538      0t0     TCP 139.129.11.120:7000->115.231.20.123:41297 (ESTABLISHED)
frps    4721  wcl   11u     IPv6 117053540      0t0     TCP *:6005 (LISTEN)
frps    4721  wcl   12u     IPv6 117334428      0t0     TCP *:6004 (LISTEN)
```

从 **lsof** 的输出结果中可以清楚的看到 **frps** 进程监听了 5 个端口，并且在 7000 端口上建立了 3 个连接，连接两端的 ip 信息也都可以查到。

**lsof** 的 **-nP** 参数用于将 ip 地址和端口号显示为正常的数值类型，否则可能会用别名表示。
