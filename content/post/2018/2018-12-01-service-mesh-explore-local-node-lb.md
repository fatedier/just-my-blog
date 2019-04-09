---
categories:
    - "技术文章"
tags:
    - "kubernetes"
    - "service mesh"
date: 2018-12-01
title: "Service Mesh 探索之优先本地访问"
url: "/2018/12/01/service-mesh-explore-local-node-lb"
---

在设计 Service Mesh 架构方案时，考虑到有一些基础服务，访问频率高，流量大，如果在 kubernetes 平台上采用 DaemonSet 的部署方式，每一个机器部署一个实例，访问方能够优先访问同一个节点上的该服务，则可以极大地减少网络开销和延迟。

<!--more-->

目前开源的项目中还没有支持这一功能，所以我们需要实现自己的负载均衡策略来达到这一目的。

### discovery 组件

和 Istio 的 pilot 类似，一般 Service Mesh 平台中会有一个 discovery 组件，通过 discovery 组件，proxy 才能获得要访问的服务的所有节点信息，discovery 屏蔽了各个服务注册中心的细节。

我们的 discovery 组件对外提供 GRPC 接口。有以下几个概念:

* Zone: 区域，一个区域有多个集群，通常物理上不在一起，互相访问存在网络开销或不能直接访问。
* Cluster: 集群，一个集群是一组服务的集合，集群之间通常在一个区域的内部网络环境中。
* Service: 服务，一个服务对应 N 个实例。
* Instance: 实例，服务的最小实现单元。

这里主要关心 Instance 这个结构，其 protobuf 定义如下:

```
message Instance {
    NetworkEndpoint endpoint = 1;
    Labels labels = 2;
}

message NetworkEndpoint {
    string address = 1;
    int64 port = 2;
    string port_name = 3;
}
```

其中 Labels 是一个 map 结构，每一个实例都会有一些标签，例如 `cluster=c1, zone=z1, node=n1`。

我们需要利用的就是 `node` 这个标签，表示该实例所在的物理机器节点。这个标签可以为空，表示未知。

### kubernetes 中获取 Node 信息

在 kubernetes 中获取 NodeName 的简单代码示例:

```golang
out := make([]*model.Instance, 0)
for _, item := range d.factory.Core().V1().Endpoints().Informer().GetStore().List() {
    ep := *item.(*corev1.Endpoints)
    
    for _, ss := range ep.Subsets {
        for _, ea := range ss.Addresses {
            for _, port := range ss.Ports {
                labels := make(model.Labels)
                labels["namespace"] = ep.Namespace
                labels["registry"] = string(registry.KubernetesRegistry)
                labels["service"] = ep.Name
                labels["cluster_id"] = d.clusterID
                if ea.NodeName != nil {
                    labels["node"] = *ea.NodeName
                }

                out = append(out, &model.Instance{
                    Endpoint: &model.NetworkEndpoint{
                        Address:  ea.IP,
                        Port:     int(port.Port),
                        PortName: port.Name,
                    },
                    Labels: labels,
                })
            }
        }
    }
}
```

k8s 的 Endpoint 信息中会附加上 NodeName，需要注意的是这个参数有可能不存在。

### proxy 组件

proxy 在启动时，会通过环境变量 `NODE_NAME` 识别出自己所在的物理节点。

#### 部署在 k8s

proxy 组件在 k8s 中是以 sidecar 的方式和服务的容器部署在同一个 pod 中，所以必然是在同一个物理机器上。我们通过修改 proxy 的 yaml 文件配置附加上 `NODE_NAME` 这一环境变量。

示例如下:

```yaml
env:
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
```

#### 部署在物理机

通过启动 proxy 时主动指定 `NODE_NAME`。

``env NODE_NAME=`hostname` ./proxy``

### 负载均衡算法

假设 A 服务希望通过 proxy 访问以 DaemonSet 方式部署的 B 服务。

具体的步骤:

* A 服务的 proxy 从环境变量中知道自身所在的 Node。
* 从 discovery 中获取到 B 服务的所有 Instance 对应的 Node 信息。
* 从 B 服务的所有 Instance 中选择具有相同 Node 的节点。
* 优先访问该节点。

注意事项:

* 当 B 服务的本地节点出现故障时，需要依靠重试机制来保证可靠性。
* 重试时会优先以轮询的方式重试具有相同 Node 的节点。
* 如果相同 Node 的节点全部重试过一遍，则继续以轮询的方式重试剩余其他节点。
