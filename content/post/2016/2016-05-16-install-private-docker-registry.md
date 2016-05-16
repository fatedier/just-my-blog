---
categories:
    - "技术文章"
tags:
    - "docker"
date: 2016-05-16
title: "搭建私有docker仓库"
url: "/2016/05/16/install-private-docker-registry"
---

docker 使用起来确实非常方便，易于部署，但是在国内如果要从 DockerHub 上下载镜像实在是一件非常吃力的事，而且公司内部环境使用或者搭建类似 kubernetes 集群的话就需要搭建一个私有的 docker 镜像仓库，方便在集群上快速部署 docker 服务。

<!--more-->

### registry 镜像下载

直接下载官方提供的 docker 镜像

`docker pull registry:2.4`

这里有一点需要注意的比较坑的是官方的 `latest` 的镜像指向的是 `0.9.1` 版本，使用 python 开发的，已经被废弃了，新版本采用 go 开发，效率和安全方面都提升很多，所以需要手动指定最新的版本。

### 启动 registry 容器

`docker run -d --name registry -p 5000:5000 -v /opt/registry:/var/lib/registry registry:2.4`

由于需要做目录映射，如果你的机器上开启了 **SELINUX**，则使用如下命令：

`docker run -d --name registry -p 5000:5000 -v /opt/registry:/var/lib/registry:Z registry:2.4`

否则在 docker 容器中可能没有操作此目录的权限，也可以临时关闭 **SELINUX**，执行 `setenforce 0`，永久关闭的话需要修改配置文件 `/etc/selinux/config`，将 `SELINUX=enforcing` 改为`SELINUX=disabled`，并且重启系统。

**-p 5000:5000**： 对外暴露 5000 端口用于提供服务

**-v  /opt/registry:/var/lib/registry**： 将宿主机的 `/opt/registry` 目录映射到容器内的 `/var/lib/registry`，这个目录用来存储 docker 的镜像文件，为了持久化存储，不然容器关闭后这些镜像文件会丢失。

这里根据 registry 镜像的不同版本，存储镜像文件的目录可能并不是 `/var/lib/registry`，`2.4` 版本是 `/var/lib/registry`，如果是其他版本可以查看具体的 Dockerfile 来确认。

### 上传下载镜像

由于 docker 的安全策略限制，如果要从私有的仓库上传下载镜像需要修改 docker 的启动参数，把我们自己搭建的 registry 的 ip 地址或者域名添加进来。

centos7 上的配置文件位置为 `/etc/sysconfig/docker`。

设置 `INSECURE_REGISTRY='--insecure-registry 192.168.2.129:5000'`，重启 docker 服务，以后要和这个 registry 交互的机器都需要执行上述步骤。

另外一个方法就是自己签一组证书，把 `ca.crt` 拷贝到 `/etc/docker/certs.d/192.168.2.199:5000/ca.crt` 就可以了，这样就不需要重启 docker 服务，这个方法目前还没试过，之后可以尝试一下。

#### 上传镜像

给要上传的镜像打上 tag，修改前缀为我们的 registry 的 ip 和 port

`docker tag centos 192.168.2.129:5000/centos`

`docker push 192.168.2.129:5000/centos`

可以看到上传的镜像已经被存储在 /opt/registry 上了

#### 下载镜像

`docker pull 192.168.2.129:5000/centos`

直接从内网环境下载镜像的速度相当快。

### API

Registry 的 API 也更新到了 V2 版本，可以通过 HTTP API 对私有仓库进行一些管理操作。具体的说明可以参考 github 上的项目文档 https://github.com/docker/distribution。
