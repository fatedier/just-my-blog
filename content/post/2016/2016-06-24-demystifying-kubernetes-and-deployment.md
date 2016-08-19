---
categories:
    - "技术文章"
tags:
    - "docker"
    - "kubernetes"
date: 2016-06-24
title: "kubernetes 初探及部署实践"
url: "/2016/06/24/demystifying-kubernetes-and-deployment"
---

Kubernetes 是 Google 开源的容器集群管理系统，作为 Go 语言开发的热门项目之一，它提供了应用部署、维护、 扩展机制等功能，利用 Kubernetes 能够方便地管理跨机器运行的容器化应用，目前主要是针对 Docker 的管理。

<!--more-->

### 主要概念

#### Pod

在 Kubernetes 中是最基本的调度单元，可以包含多个相关的容器，属于同一个 pod 的容器会被运行在同一个机器上，看作一个统一的管理单元。例如我们的一个应用由 nginx、web网站、数据库三部分组成，每一部分都运行在一个单独的容器中，那么我们可以将这三个容器创建成一个 pod。

#### Service

Service 是 pod 的路由代理抽象，主要是为了解决 pod 的服务发现问题。因为当有机器出现故障导致容器异常退出时，这个 pod 可能就会被 kubernetes 分配到另外一个正常且资源足够的机器上，此时 IP 地址以及端口都有可能发生变化，所以我们并不能通过 host 的真实 IP 地址和端口来访问。Service 的引入正是为了解决这样的问题，通过 service 这层代理我们就可以访问到 pod 中的容器，目前的版本是通过 iptables 来实现的。

#### ReplicationController

ReplicationController 的概念比较简单，从名字就可以看出是用于管理 pod 的多副本运行的。它用于确保 kubernetes 集群中指定的 pod 始终会有指定数量的副本在运行。如果检测到有容器异常退出，replicationController 会立即重新启动新的容器，并且通过 replicationController 我们还可以动态地调整 pod 的副本数量。

#### Label

Label 是用于将上述几个概念关联起来的一些 k-v 值。例如我们创建了一个 pod 并且设置了 label 为 `app=nginx`，同样在创建 service 和 replicationController 时也设置相同的 label，这样通过 label 的 selector 机制就可以将创建好的 service 和 replicationController 作用在之前创建的 pod 上。

### 主要组件

![k8s-overview](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-06-24-demystifying-kubernetes-and-deployment-k8s-overview.png)

Kubernetes 集群中主要存在两种类型的节点，分别是 master 节点，以及 minion 节点。

Minion 节点是实际运行 Docker 容器的节点，负责和节点上运行的 Docker 进行交互，并且提供了代理功能。

Master 节点负责对外提供一系列管理集群的 API 接口，并且通过和 Minion 节点交互来实现对集群的操作管理。

#### apiserver

用户和 kubernetes 集群交互的入口，封装了核心对象的增删改查操作，提供了 RESTFul 风格的 API 接口，通过 etcd 来实现持久化并维护对象的一致性。

#### scheduler

负责集群资源的调度和管理，例如当有 pod 异常退出需要重新分配机器时，scheduler 通过一定的调度算法从而找到最合适的节点。

#### controller-manager

主要是用于保证 replicationController 定义的复制数量和实际运行的 pod 数量一致，另外还保证了从 service 到 pod 的映射关系总是最新的。

#### kubelet

运行在 minion 节点，负责和节点上的 Docker 交互，例如启停容器，监控运行状态等。

#### proxy

运行在 minion 节点，负责为 pod 提供代理功能，会定期从 etcd 获取 service 信息，并根据 service 信息通过修改 iptables 来实现流量转发（最初的版本是直接通过程序提供转发功能，效率较低。），将流量转发到要访问的 pod 所在的节点上去。

### 部署实践

Kubernetes 的部署十分简单，先从 Github 上下载编译好的二进制文件（我自己尝试编译耗时太久，遂作罢），这里强调简单的原因是因为每个组件并不需要配置文件，而是直接通过启动参数来设置。相比于很多 Java 项目一系列的环境设置，组件搭建，k8s 还是比较友好的。下面主要说一下各个组件常用的启动参数的设置。

#### etcd

安装并启动 etcd 集群，这里以一台作为示例，比较简单，不具体说明，假设访问地址为 `192.168.2.129:2379`。

#### flannel

Flannel 是 CoreOS 团队针对 Kubernetes 设计的一个覆盖网络（Overlay Network）工具，需要另外下载部署。我们知道当我们启动 Docker 后会有一个用于和容器进行交互的 IP 地址，如果不去管理的话可能这个 IP 地址在各个机器上是一样的，并且仅限于在本机上进行通信，无法访问到其他机器上的 Docker 容器。

Flannel 的目的就是为集群中的所有节点重新规划 IP 地址的使用规则，从而使得不同节点上的容器能够获得同属一个内网且不重复的 IP 地址，并让属于不同节点上的容器能够直接通过内网 IP 通信。

具体实现原理可以参考： http://www.open-open.com/news/view/1aa473a

##### 安装 flannel

在 etcd 中创建 flannel 需要用到的键，假设我们 Minion 中 flannel 所使用的子网范围为`172.17.1.0~172.17.254.0`（每一个Minion节点都有一个独立的flannel子网）。

`etcdctl mk /coreos.com/network/config '{"Network":"172.17.0.0/16", "SubnetMin": "172.17.1.0", "SubnetMax": "172.17.254.0"}'`

##### 启动参数

`flanneld -etcd-endpoints=http://192.168.2.129:2379 -etcd-prefix=/coreos.com/network --log_dir=./ --logtostderr=false`

```bash
-etcd-endpoints: etcd 集群的地址
-etcd-prefix: etcd 中存储 flannel 信息的前缀
--log_dir: 设置日志文件存储目录
--logtostderr: 设置错误信息是否存储到标准输出中
```

##### 修改 docker0 网卡的 IP 地址

默认情况下启动 docker 后会有一个 docker0 的虚拟网卡，每一台机器的 docker0 网卡对应的 ip 地址都是相同的。

修改启动 docker 的参数，centos7 下可以修改 `/usr/lib/systemd/system/docker.service` 文件。

增加 `EnvironmentFile=-/run/flannel/subnet.env`。

`ExecStart` 增加两个参数 `--bip=${FLANNEL_SUBNET}  --mtu=${FLANNEL_MTU}`。

`FLANNEL_SUBNET` 和 `FLANNEL_MTU` 这两个变量就是从 `/run/flannel/subnet.env` 文件中读取，记录了 flannel 在这台机器上被分配到的一个网段。

`systemctl daemon-reload`

`systemctl start docker.service`

之后通过 `ifconfig` 可以看到 docker0 的网卡 ip 已经变成了 flannel 的网段。

#### kube-apiserver

部署在 Master 节点上。

`kube-apiserver --logtostderr=false --log-dir=./ --v=0 --etcd-servers=http://192.168.2.129:2379 --address=0.0.0.0 --port=8080 --kubelet-port=10250 --allow-privileged=true --service-cluster-ip-range=10.254.0.0/16`

#### kube-scheduler

部署在 Master 节点上。

`kube-scheduler --logtostderr=false --log-dir=./ --v=0 --master=http://192.168.2.129:8080`

#### kube-controller-manager

部署在 Master 节点上。

`kube-controller-manager --logtostderr=false --log-dir=./ --v=0 --master=http://192.168.2.129:8080`

#### kubelet 

部署在 Minion 节点上。

`kubelet --logtostderr=false --log-dir=./ --v=0 --api-servers=http://192.168.2.129:8080 --address=0.0.0.0 --port=10250 --allow-privileged=true`

#### kube-proxy

部署在 Minion 节点上。

`kube-proxy --logtostderr=false --log-dir=./ --v=0 --master=http://192.168.2.129:8080`

### 遇到的问题

通过上面的步骤，k8s 集群就差不多搭建成功了，但是仍然遇到了一些问题，有的甚至目前还没有找到解决方案，直接导致了我丧失了将 k8s 用于实际开发环境的动力。

#### pause 镜像

在每个 Minion 节点上的 Docker 需要安装  gcr.io/google_containers/pause 镜像，这个镜像是在 kubernetes 集群启动用户配置的容器时需要用到。

本来启动容器后会直接从 google 官方源下载，因为墙的原因，在国内无法下载成功，这里可以先从 dockerhub 上下载，`sudo docker pull kubernetes/pause`。

之后再打上 tag，`sudo docker tag kubernetes/pause gcr.io/google_containers/pause:2.0`。

我装的 `kubernetes 1.2.3` 版本对应的 tag 是 `pause:2.0`，如果不知道版本，可以尝试运行一个 pod ，之后通过查看错误信息得到。

后来查看文档发现也可以通过在 kubelet 的启动参数中设置这个镜像的地址，不过还没有测试过。

#### 搭建私有 docker 镜像仓库

为了便于使用，最好自己搭建内网环境的私有镜像仓库，因为 k8s 中每一台机器上的 docker 都需要 pull 镜像到本地，如果从外网环境拉镜像的话效率较低，而且以后更新镜像等操作将变的非常不方便。

具体的步骤可以参考我之前的一篇文章， [『搭建私有docker仓库』](/2016/05/16/install-private-docker-registry/)。

#### service 访问问题

测试时可以在一台机器上的容器内部通过 service 提供的内网 IP 地址访问到运行在另外一台机器上的容器。但是必须是在容器内部才行，如果直接在这个机器上通过 telnet 或者 curl 访问，则无法正确地根据这个内网 IP 转发到对应节点的容器中。

因为是通过 iptables 来进行转发，我查看了 iptables 的规则，并没有发现问题，后来通过抓包发现这个包的目的 IP 地址被替换成功了，但是源地址并没有被正确替换，导致对方节点无法正确回复。这个问题我还没有发现具体的原因，目前不能在容器外部通过 service 提供的 IP 地址来访问容器，导致很多应用没有了实际部署的意义，后面有时间还是要研究下。

#### 文件存储

由于 pod 可能会被在任意一台机器上重新启动，所以并不能简单的像运行单机 Docker 那样将容器内部的目录映射到宿主机的指定目录上，否则将会丢失文件。所以通常我们需要使用类似 NFS、ceph、glusterFS 这样的分布式存储系统来为 k8s 集群提供后端的统一存储。这样一来，无疑就增加了部署的难度，比如要搭建一个靠谱的 ceph 集群，无疑是需要有比较靠谱的运维团队的。

### 测试 nginx 容器

#### 创建并启动 replicationController 

创建配置文件 `nginx-rc.yaml`。

```yaml
apiVersion: v1 
kind: ReplicationController 
metadata: 
  name: nginx-controller 
spec: 
  replicas: 2 
  selector: 
    name: nginx 
  template: 
    metadata: 
      labels: 
        name: nginx 
    spec: 
      containers: 
        - name: nginx
          image: nginx
          ports: 
            - containerPort: 80
```

这里定义了一个 nginx pod 的复制器，复制份数为2。

执行下面的操作创建nginx pod复制器：

`kubectl -s http://192.168.2.129:8080 create -f nginx-rc.yaml`

查看创建 pod 的状态：

`kubectl -s http://192.168.2.129:8080 get pods`

#### 创建并启动 service

Service 的 type 有 ClusterIP 和 NodePort 之分，缺省是 ClusterIP，这种类型的 Service 只能在集群内部访问，而 NodePort 可以在集群外部访问，但是它的原理就是在所有节点上都绑定这个端口，之后将所有的流量转发到正确的节点上。

创建配置文件 `nginx-service-clusterip.yaml`

```yaml
apiVersion: v1 
kind: Service 
metadata: 
  name: nginx-service-clusterip 
spec: 
  ports: 
    - port: 8001 
      targetPort: 80 
      protocol: TCP 
  selector: 
    name: nginx
```

执行下面的命令创建 service：

`kubectl -s http://192.168.2.129:8080 create -f ./nginx-service-clusterip.yaml`

查看 service 提供的 IP 地址和端口：

`kubectl -s http://192.168.2.129:8080 get service`

之后就可以通过 curl 来验证是否能够成功访问到之前部署的 nginx 容器，由于启用了 service，会自动帮我们进行负载均衡，流量会被分发到后端的多个 pod 中。
