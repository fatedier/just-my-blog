---
categories:
    - "技术文章"
tags:
    - "kubernetes"
date: 2019-01-03
title: "使用 telepresence 在 k8s 环境中实现快速开发"
url: "/2019/01/03/using-telepresence-for-quick-dev-in-k8s"
---

随着容器化，微服务的概念逐渐成为主流，在日常的开发测试中，会遇到一些新的问题。例如如果服务跑在 istio 这样的 ServiceMesh 平台上，依赖于 k8s 的 sidecar 功能，在本地模拟这样的场景来调试和测试是比较复杂的。而 telepresence 帮助我们缓解了这样的问题。

<!--more-->

### 安装

telepresence 的项目地址：https://github.com/telepresenceio/telepresence

OS X

```
brew cask install osxfuse
brew install datawire/blackbird/telepresence
```

其他的系统环境安装参考 https://www.telepresence.io/reference/install

### 简介

Telepresence 是用 python 编写的用于帮助我们在本地运行一个服务，同时能够访问到远端的 kubernetes 集群的服务。

这样的话，我们不再需要每次修改代码后，重新编译，推送镜像，部署到 k8s 集群，然后调试，如果出现错误，再重复这样的步骤。并且由于服务是在本地运行，可以更方便地利用本地环境的一些调试工具来帮助我们排查分析问题。

### 原理

Telepresence 在远端 k8s 集群部署了一个和本地环境网络互通的 pod，可以选择 VPN 的方式。这个 pod 会将指定的网络流量，环境变量，磁盘等数据转发到本地的服务。且本地服务的 DNS 查询，网络流量，都可以被路由到远端的 k8s 集群。

### 常用的功能

#### 新建一个 Deployment 用于测试本地服务访问远端服务

```
telepresence --new-deployment myserver --run-shell --also-proxy 192.168.0.0/16
```

telepresence 默认会使用当前的 kubectl 的 current context 来进行请求。

**--new-deployment** 表示新创建一个名为 **myserver** 的 deployment。
**--run-shell** 表示启动完成后进入一个 shell 命令行环境，可以继续执行自己需要的服务或命令。
**--also-proxy** 表示我们需要在本地通过 IP 的方式访问 192.168 网段的 k8s 服务。这个 IP 段是 k8s 上容器会被分配到的 IP 段。如果不设置这个参数，就只能通过 service 名来访问服务。

启动成功后，会进入到一个 shell 终端。在这个终端里运行的命令都能够访问到 k8s 集群里的服务。

因为只打开了一个 shell 终端，如果需要同时调试多个服务就比较麻烦。最好能够借助于 **tmux** 这样的工具来打开多个终端窗口。

#### 替换一个远端的 Deployment 服务

有时在远端 k8s 集群我们已经部署了一套完整的服务，但是其中某个服务可能有问题。我们希望能够将集群内的流量劫持到本地的进程，来进行调试，这样就可以快速修改代码，加日志，方便排查问题。

```
telepresence --swap-deployment proxy:proxy --expose 9100:9100 --also-proxy 192.168.0.0/16
```

**--swap-deployment** 表示替换一个远端集群的 Deployment。
**proxy:proxy** 是要替换的 Deployment 中的指定容器的名字。如果要替换所有，可以不用加冒号。格式为 **{Deployment}:{Container}** 。
**--expose 9100:9100** 表示要将远端容器 9100 端口的流量转发到本地的 9100 端口，格式为 **--expose PORT[:REMOTE_PORT]** 。

启动成功后，使用方式和 **--new-deployment** 一样，但是发往 proxy 这个服务的 9100 端口的流量会被路由到本地的 9100 端口的服务，此时只需要让本地调试的程序监听在 9100 端口，就可以实时接收 k8s 集群内部的流量，方便我们测试开发。
