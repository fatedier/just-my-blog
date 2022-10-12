---
categories:
    - "技术文章"
tags:
    - "mac"
date: 2021-11-17
title: "macos 上如何实现类似 iptables 的防火墙规则"
url: "/2021/11/17/macos-iptables-block-address"
---

Linux 上调试开发的时候，经常需要模拟网络断开，端口无法访问等场景。

mac 上开发也有类似的需求，例如禁用掉所有到 192.168.100.2 的 80 端口的流量。可以通过 PF 防火墙来实现。

<!--more-->

1. 修改配置文件 `/etc/pf.conf`

    ```
    sudo vim /etc/pf.conf
    ```

2. 添加 block 规则

    ```
    block drop proto tcp from any to 192.168.100.2 port 80
    ```
    
3. 执行命令使配置生效，生效后请求对应的端口已经不通了

    ```
    pfctl -e -f /etc/pf.conf
    ```
    
4. 不需要的时候可以移除配置，或执行命令关闭防火墙

    ```
    pfctl -d
    ```
