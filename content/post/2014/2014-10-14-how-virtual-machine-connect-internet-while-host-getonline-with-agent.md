---
categories:
    - "技术文章"
tags:
    - "linux"
date: 2014-10-14
title: "主机使用代理上网，虚拟机Linux的shell如何连外网"
url: "/2014/10/14/how-virtual-machine-connect-internet-while-host-getonline-with-agent"
---

在公司电脑上网都需要使用代理，虚拟机里面装的Linux系统需要使用yum命令来安装软件，所以需要在shell界面能连上外网才行。

因为公司限制了每个人只能用一个IP，所以虚拟机中的Linux系统使用NAT方式和主机相连。主机是Win7操作系统，会发现网络里面多了VMnet8这个网络。

<!--more-->

![vmware-net](/pic/2014/2014-10-14-how-virtual-machine-connect-internet-while-host-getonline-with-agent-vmware-net.jpg)

在VMware界面，点击“编辑”，“虚拟网络编辑器”

可以看到子网地址分配的是192.168.131.0

***

一般来说这时我们的主机会自动分配一个IP类似192.168.131.1这样的，子网掩码为255.255.255.0，如下图所示。

![host-net](/pic/2014/2014-10-14-how-virtual-machine-connect-internet-while-host-getonline-with-agent-host-net.jpg)

现在进入虚拟机的Linux进行设置。

![network-configuration](/pic/2014/2014-10-14-how-virtual-machine-connect-internet-while-host-getonline-with-agent-network-configuration.jpg)

注意IP需要设置成192.168.131.x的形势，网关是192.168.131.2。

之后使用 `service network restart` 命令重启网络服务。

然后可以用 `ifconfig` 命令检查配置是否正确。

***

最后，修改自己目录下的配置文件，使用“cd”命令进入自己的根目录。

比如我的是.bash_profile

添加代码如下：

```bash
export http_proxy="http://proxy_addr:port"
export https_proxy="http://proxy_addr:port"
export ftp_proxy="http://proxy_addr:port"
```

**proxy_addr** 就是代理的IP地址

**port** 是代理的款口号

如果代理需要用户名和密码的话，这样设置：

```bash
exporthttp_proxy=”http://username:password@proxy_addr:port”
```

现在就可以使用yum命令安装需要的软件了。
