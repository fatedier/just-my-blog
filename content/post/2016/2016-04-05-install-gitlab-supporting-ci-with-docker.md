---
categories:
    - "技术文章"
tags:
    - "git"
    - "docker"
date: 2016-04-05
title: "利用docker搭建gitlab及持续集成模块"
url: "/2016/04/05/install-gitlab-supporting-ci-with-docker"
---

版本控制的重要性应该是毋庸置疑了，git 作为现在最流行的版本控制工具，各种规模的公司都在用。通常开源项目都会放在 github 上，基础功能是免费的，私有项目收费。对于一个小团队来说，gitlab 就是另外一个替代品，可以用来搭建自己私有的git服务器。

<!--more-->

### 为什么需要版本控制和持续继承？

经常听到很多程序员说自己没有时间写测试用例，但其实很多人的时间都花在了手动测试，修复bug，调试程序上。如果写好测试用例，每次提交代码后都自动进行编译，然后将测试用例全部跑一遍，如果测试失败能够获取到足够的反馈信息，这样避免了重复构建测试环境，手动运行测试用例等低效率的工作，而这就是持续集成的好处。

### 准备工作

#### docker 环境

安装 `docker` 环境，`centos` 的话可以使用 `sudo yum install -y docker` 直接安装

之后启动 `docker`，`sudo service docker start`

#### docker 镜像加速

由于国内的网络环境过于恶劣，多次尝试从 [gitlab](https://gitlab.com/) 官网下载源码安装包未果，之后发现  gitlab 还提供 docker 镜像，这样不仅部署方便，利用国内一些云服务商提供的镜像加速功能，可以加速 docker 镜像的下载。

推荐 daocloud 的镜像加速服务，[https://dashboard.daocloud.io/mirror](https://dashboard.daocloud.io/mirror)，安装之后，使用 `dao pull` 替代 `docker pull` 即可。

#### 下载相关docker镜像

* gitlab/gitlab-ce:latest （gitlab 的 docker镜像）
* gitlab/gitlab-runner:latest （用于持续集成，构建测试环境）
* golang:1.5 （golang基础环境，用于编译代码，运行测试用例）

### 启动 gitlab

具体的官方说明文档：[http://doc.gitlab.com/omnibus/docker/README.html](http://doc.gitlab.com/omnibus/docker/README.html)

启动 `gitlab` 就是启动相应的 `docker` 镜像，设置好相关配置参数，命令如下：

```bash
sudo docker run --detach \
    --hostname x.x.x.x \
    --publish 7000:443 --publish 80:80 --publish 7002:22 \
    --name gitlab \
    --restart always \
    --volume /srv/gitlab/config:/etc/gitlab \
    --volume /srv/gitlab/logs:/var/log/gitlab \
    --volume /srv/gitlab/data:/var/opt/gitlab \
    gitlab/gitlab-ce:latest
```

如果你的机器开启了 `SELINUX`，需要使用如下的命令

```bash
sudo docker run --detach \
    --hostname x.x.x.x \
    --publish 7000:443 --publish 80:80 --publish 7002:22 \
    --name gitlab \
    --restart always \
    --volume /srv/gitlab/config:/etc/gitlab:Z \
    --volume /srv/gitlab/logs:/var/log/gitlab:Z \
    --volume /srv/gitlab/data:/var/opt/gitlab:Z \
    gitlab/gitlab-ce:latest
```

`hostname` 可以是gitlab服务器的ip，也可以是绑定的域名，80端口需要映射到宿主机的80端口，因为之后 `github-ci-runner` 会从这个端口下载测试源码。

`/srv/gitlab` 是用于持久化 docker 容器中产生的数据，例如 **redis**，**postgresql** 等等，gitlab 的docker 镜像中已经内置了这些服务。

启动成功后，可以通过浏览器访问80端口来使用 gitlab 了，可能是由于我的测试服务器配置较低，等待约2分钟后才能访问。

初始帐号和密码为 `root`  `5iveL!fe`，第一次登录成功后需要修改密码。

gitlab 的具体使用文档比较多，这里就不详细介绍了。

### 创建测试项目

简单创建一个 `test` 项目，先不要提交到 gitlab 仓库。

包含一个 `a.go` 文件，文件内容如下

```go
package main

import fmt 

func main() {
    fmt.Printf("aaa\n")
}
```

**可以看到 import 包名没有加双引号，显然编译时就会出错。**

#### 添加 .gitlab-ci.yml 文件

配置文件详细内容请参考 [http://doc.gitlab.com/ce/ci/yaml/README.html](http://doc.gitlab.com/ce/ci/yaml/README.html)

这里简单写一下，仅仅用于测试：

```yaml
image: golang:1.5

job1:
    script:
        - go build a.go
        - ./a
```

`image` 表示使用 `golang:1.5` 的 docker 镜像来部署编译和测试代码，我们之前已经下好了。

测试命令有两条，`go build a.go` 编译源码， `./a` 执行编译后的程序。

### 获取 Runner registration token


![registration-token](https://image.fatedier.com/pic/2016/2016-04-05-install-gitlab-supporting-ci-with-docker-registration-token.png)

在 `gitlab` 的管理员配置界面，左边有一个 `Runners`，点进去之后可以看到有一个 `Registration token`，这个是用于之后创建的 `runner` 服务与 `gitlab` 通信的时候认证使用。

例如图中的 `Registration token` 为 `XKZmVj9t8j4xj1e5k34N`。

### 启动 Runner

Runner 官方详细说明文档： [https://gitlab.com/gitlab-org/gitlab-ci-multi-runner/blob/master/docs/install/docker.md](https://gitlab.com/gitlab-org/gitlab-ci-multi-runner/blob/master/docs/install/docker.md)

`Runner`其实就是用于编译和管理测试环境的服务，当 `gitlab` 上的项目有 `commit` 或 `merge` 的时候，`Runner` 可以 hook 到相关信息，然后从 `gitlab` 上拉取代码，利用 `docker` 创建一个新的测试环境，之后执行 `.gitlab-ci.yml` 文件中预先配置好的命令。

```bash
docker run -d --name gitlab-runner --restart always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /srv/gitlab-runner/config:/etc/gitlab-runner \
      gitlab/gitlab-runner:latest
```

如果你的机器开启了 SELINUX，需要使用如下的命令：

```bash
docker run -d --name gitlab-runner --restart always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /srv/gitlab-runner/config:/etc/gitlab-runner:Z \
      gitlab/gitlab-runner:latest
```

#### 关联 gitlab

启动成功后的 `Runner` 需要在 `gitlab` 上注册，通过在 `Runner` 上执行注册命令，会调用 `gitlab` 的相关接口注册。

```bash
docker exec -it gitlab-runner gitlab-runner register

Please enter the gitlab-ci coordinator URL (e.g. [https://gitlab.com/ci](https://gitlab.com/ci) )
[https://gitlab.com/ci](https://gitlab.com/ci)（这里的gitlab.com替换成之前启动gitlab时填写的 hostname）

Please enter the gitlab-ci token for this runner
xxx（填写获取到的 runner registration token）

Please enter the gitlab-ci description for this runner
my
INFO[0034] fcf5c619 Registering runner... succeeded

Please enter the executor: shell, docker, docker-ssh, ssh?
docker

Please enter the Docker image (eg. ruby:2.1):
golang:1.5
INFO[0037] Runner registered successfully. Feel free to start it, but if it's
running already the config should be automatically reloaded!
```

### 测试

利用 `docker` 来搭建这套环境还是非常简单的。

接着提交我们之前创建的两个文件，`a.go` 和 `.gitlab-ci.yml`。

访问 `gitlab` 查看 `build` 的结果。

![test-commit](https://image.fatedier.com/pic/2016/2016-04-05-install-gitlab-supporting-ci-with-docker-test-commit.png)

可以看到提交记录右边有一个红叉，表示测试未通过，点击红叉，可以看到测试的摘要信息。

![test-info](https://image.fatedier.com/pic/2016/2016-04-05-install-gitlab-supporting-ci-with-docker-test-info.png)

继续点 红色的 `failed` 按钮就可以看到详细的测试信息。

![test-deatil](https://image.fatedier.com/pic/2016/2016-04-05-install-gitlab-supporting-ci-with-docker-test-deatil.png)

从 `Runner` 测试过程的输出信息可以看出来，`Runner` 先 `pull` 我们指定的 `docker` 镜像，这里是 `golang:1.5`，之后 `git clone` 代码到测试环境，然后开始执行测试命令，在执行 `go build a.go` 的时候出现了错误，并且显示了错误信息。

将错误的代码修改后再次提交

```go
package main

import (
    "fmt"
)

func main() {
    fmt.Printf("aaa\n")
}
```

可以看到能够通过测试了，执行程序后的输出 `aaa` 也能够看到。

![test-commit-all](https://image.fatedier.com/pic/2016/2016-04-05-install-gitlab-supporting-ci-with-docker-test-commit-all.png)

![test-succ-detail](https://image.fatedier.com/pic/2016/2016-04-05-install-gitlab-supporting-ci-with-docker-test-succ-detail.png)
