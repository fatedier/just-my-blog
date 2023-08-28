---
categories:
    - "技术文章"
tags:
    - "istio"
date: 2023-08-26
title: "通过 minikube 测试 Istio 多主集群架构"
url: "/2023/08/26/use-minikube-test-istio-multi-primary"
---

minikube 可以很方便地在本地创建用于测试的持久化的 K8s 集群，能够很方便地测试 Istio 多主集群架构。

<!--more-->

### 概述

Istio 多主集群架构，是指每个集群都部署自己的控制面，同时，支持通过 secret 声明其他集群的 API Server 连接信息，通过其他集群的 API Server 获取服务发现信息。

从而实现多个集群之间的任意服务的互相访问的能力，且一个服务可以同时部署在多个集群。

这个架构要求多个集群之间的 Pod 网络是互通的。

![architecture](https://image.fatedier.com/pic/2023/2023-08-26-use-minikube-test-istio-multi-primary-architecture.jpg)

### 创建 K8s 集群

minikube 可以通过 -p 参数指定名称创建不同的 K8s 集群用于测试。

我们需要创建两个 K8s 集群，一个默认的名称就叫 minikube，另外一个名称叫 test。

为了避免 Pod IP 冲突，需要主动给不同集群配置不同的 pod cidr 以及 docker 网桥的 ip 段。

minikube 集群

```
minikube start --registry-mirror=https://docker.mirrors.sjtug.sjtu.edu.cn --cache-images=true --vm-driver=hyperkit --kubernetes-version=1.26.8 --extra-config=kubeadm.pod-network-cidr=172.17.0.0/16 --docker-opt bip=172.17.0.1/24
```

test 集群

```
minikube start --registry-mirror=https://docker.mirrors.sjtug.sjtu.edu.cn --cache-images=true --vm-driver=hyperkit --kubernetes-version=1.26.8 --extra-config=kubeadm.pod-network-cidr=172.18.0.0/16 --docker-opt bip=172.18.0.1/24 -p test
```

### 部署 Istio

`curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.18.2 sh -`

通过上面的命令下载 helm chart 到本地，然后部署到两个集群，可以参考 Istio 文档: https://istio.io/latest/docs/setup/install/helm/

```
$ kubectl create namespace istio-system
$ helm install istio-base istio/base -n istio-system --set defaultRevision=default
$ helm install istiod istio/istiod -n istio-system --wait
```

建议在部署时将 mtls 设置为默认关闭，例如给 pod 加上 `security.istio.io/tlsMode: disabled` label。这么做的目的是部署 istio 时不需要考虑证书的问题，否则需要用同一个 CA 来签两个集群的证书。关闭之后，服务之间通过明文通信，不会走 tls 加密。

如果用默认的配置是 `security.istio.io/tlsMode: istio`，部署完成后，只会将请求发送到本地集群，不会转发给远端集群。

### 打通两个 minikube 集群的 Pod 网络

两个 minikube 集群之间可以通过 Node IP 直接通信，但是访问另一个集群的 Pod IP，则访问不通。

我们需要补充配置相关的路由信息。

在 minikube 集群节点上执行 `sudo ip route add 172.18.0.0/16 via 192.168.64.3 dev eth0`

在 test 集群节点上执行 `sudo ip route add 172.17.0.0/16 via 192.168.64.2 dev eth0`

在两个节点上互相加上对方的路由，就可以实现 pod 和 pod 之间的互通。`192.168.64.2` 和 `192.168.64.3` 是对方 Node 的 IP 地址。这个路由配置的含义是如果访问的是对端集群的 Pod IP，则将数据包转发给对端的 Node，由对端的 Node 再去转发给 Pod。

### 通过 istioctl 启用对端集群的服务发现

通过 istioctl 分别创建用于连接远端集群的 secret。

```
istioctl x create-remote-secret --name=minikube --context minikube > ./minikube.yaml
istioctl x create-remote-secret --name=test --context test > ./test.yaml
```

将对端的 remote secret 分别 apply 到自己的集群。

```
kubectl apply -f ./test.yaml --context minikube
kubectl apply -f ./minikube.yaml --context test
```
    
上面的命令，会创建一个 secret 保存了用于访问另外一个集群 apiserver 的 kubeconfig 信息。

这个 kubeconfig 的鉴权是从对端集群的 的 istio-system/istio-reader-service-account 这个 SA 中获取的，其中只有对相关对象的读权限。

### 测试

参考文档: https://istio.io/latest/docs/setup/install/multicluster/verify/

通过分别在两个集群部署一个客户端和服务端服务来进行验证，最终在客户端服务的 Pod 中，可以正常访问到对端集群的服务即可。

### 问题

#### DNS 解析

目前 istio 的多集群方案，需要在每一个集群都创建一个 service ，分配一个 ClusterIP，目的是需要让每一个服务在任何一个集群都有 DNS 解析。否则用户发送一个请求，在 DNS 解析的步骤就会出错，到不了网络层被 istio 劫持。

通过启用 DNSProxying 可以避免这个问题，sidecar 会劫持并完成 DNS 解析。但是需要注意，其他 VirtualService，DestinationRule 之类的配置仍然需要在每个集群都创建。
