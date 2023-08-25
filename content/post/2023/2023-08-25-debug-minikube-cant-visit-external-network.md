---
categories:
    - "技术文章"
tags:
    - "network"
date: 2023-08-25
title: "minikube 虚拟机无法访问外网的问题排查"
url: "/2023/08/25/debug-minikube-cant-visit-external-network"
---

通过 minikube 搭建本地的 K8s 环境用于测试，但是过了一段时间，突然在虚拟机内访问不了外网，拉不到镜像了，这里记录一下排查的过程，供后续再遇到时检索。

问题的根本原因是网卡上不知道为什么绑了两个 IP，其中只有一个可用，虚拟机访问外网时本地 IP 是不可用的那一个，才导致了问题。

<!--more-->

### 访问链路

首先，需要大致上知道虚拟机里面是怎么通过宿主机的网络和外网通信的。

我的系统环境是 macos，minikube 指定的 vm-driver 是 hyperkit。

通过 minikube ssh 登录到虚拟机环境，执行 ip route 查看路由表。

```
# default 路由
default via 192.168.77.1 dev eth0 proto dhcp src 192.168.77.6 metric 1024
# docker pod ip 路由
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
```

可以看出来，docker 内部的数据包是会发给 docker0 这个网络接口。

剩下的数据包会通过 192.168.77.1 转发出去。

192.168.77.1 是宿主机的一个 bridge 接口：

```
bridge100: flags=8a63<UP,BROADCAST,SMART,RUNNING,ALLMULTI,SIMPLEX,MULTICAST> mtu 1500
        options=3<RXCSUM,TXCSUM>
        ether 16:7d:da:47:fb:64
        inet 192.168.77.1 netmask 0xffffff00 broadcast 192.168.77.255
        inet6 fe80::147d:daff:fe47:fb64%bridge100 prefixlen 64 scopeid 0x13
        inet6 fdc3:c045:483c:7986:c67:998c:8b2c:7afa prefixlen 64 autoconf secured
        Configuration:
                id 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0
                maxage 0 holdcnt 0 proto stp maxaddr 100 timeout 1200
                root id 0:0:0:0:0:0 priority 0 ifcost 0 port 0
                ipfilter disabled flags 0x0
        member: vmenet0 flags=3<LEARNING,DISCOVER>
                ifmaxaddr 0 port 18 priority 0 path cost 0
        member: vmenet1 flags=3<LEARNING,DISCOVER>
                ifmaxaddr 0 port 22 priority 0 path cost 0
        nd6 options=201<PERFORMNUD,DAD>
        media: autoselect
        status: active
```

macos 上的路由表通过 `netstat -nr` 查看。

```
Routing tables

Internet:
Destination        Gateway            Flags           Netif Expire
default            172.2.2.2          UGScg             en0
```

由于是公司的网络，所以默认的路由会通过 en0 网络接口，转发给 172.2.2.2 这个网关 IP。

### 抓包

分别在宿主机和虚拟机里通过 curl 访问 baidu.com 测试。

同时在宿主机上通过 tcpdump 抓包 `tcpdump -i en0 -nn host x.x.x.x`。

发现宿主机和虚拟机里建立连接的本地 IP 不一样。

通过 ifconfig 发现 en0 网卡接口上绑定了两个 IP，虚拟机访问外网的时候使用的那一个看上去是有问题的。

### 删除无效的网卡 IP

不确定是因为系统原因还是什么其他的原因，导致 en0 上同时存在两个 IP。正常来说，应该每次在连接办公网络的时候会通过 DHCP 分配一个新的 IP。

通过 `sudo ifconfig en0 delete <ip 地址>` 来删除有问题的那个 IP，删除后问题解决。
