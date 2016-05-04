---
categories:
    - "技术文章"
tags:
    - "codis"
    - "redis"
    - "分布式存储"
date: 2015-10-07
title: "codis 2.x版本环境搭建与测试"
url: "/2015/10/07/installation-and-testing-of-codis-version-two"
---

Codis 是一个分布式 Redis 解决方案, 对于上层的应用来说, 连接到 Codis Proxy 和连接原生的 Redis Server 没有明显的区别（有一些命令不支持），上层应用可以像使用单机的 Redis 一样，Codis 底层会处理请求的转发。Codis 支持不停机进行数据迁移, 对于前面的客户端来说是透明的, 可以简单的认为后面连接的是一个内存无限大的 Redis 服务。

<!--more-->

### 安装并启动 zookeeper

codis 2.x 版本重度依赖于 zookeeper。

从官网下载 [zookeeper](http://zookeeper.apache.org/releases.html)，解压安装。

使用默认配置启动 zookeeper `sh ./bin/zkServer.sh start`，监听地址为 `2181`。

### 下载安装 codis

`go get -d github.com/CodisLabs/codis`

进入源码根目录 `cd $GOPATH/src/github.com/CodisLabs/codis`

执行安装脚本 `./bootstrap.sh`

**注：这里第一步和第三步（会下载第三方库到本地）需要从 github copy 数据，鉴于网络环境的问题，时间会比较长。**

之后生成的可执行文件都在 `codis/bin` 文件夹下。

### 部署 codis-server

**codis-server** 基于 **redis 2.8.21** 稍微进行了一些修改以支持原子性的迁移数据，具体用法和 redis 一致。

将 `bin` 文件夹下的 codis-server 拷贝到集群中每个节点，和 redis-server 的启动命令一样，指定配置文件，启动。

**这里要注意 redis.conf 配置中需要设置 maxmemory，不然无法自动按照负载均衡的方式分配 slot（可以手动分配），推荐单台机器部署多个 redis 实例。**

`./bin/codis-server ./redis_conf/redis_6400.conf`

### 启动 dashboard

**dashboard** 既是 codis 集群的管理中心，又提供了一个人性化的 web 界面，方便查看统计信息以及对集群进行管理操作。

启动 web 控制面板，注意这里要用到配置文件，不指定的话就是当前目录下的 config.ini，可以用 `-c` 参数指定。

`nohup ./bin/codis-config -c ./config.ini dashboard --addr=:18087 &`

### 初始化 slot

`./bin/codis-config -c ./config.ini slot init`

该命令会在 zookeeper 上创建 slot 相关信息。

### 添加 group

每个 **group** 只能有一个 **master** 和多个 **slave**。

命令格式： `codis-config -c ./config.ini server add <group_id> <redis_addr> <role>`

例如向 group 1 和 group 2 中各加入两个 codis-server 实例，一主一从。

`./bin/codis-config -c ./config.ini server add 1 localhost:6379 master`

`./bin/codis-config -c ./config.ini server add 1 localhost:6380 slave`

`./bin/codis-config -c ./config.ini server add 2 localhost:6381 master`

`./bin/codis-config -c ./config.ini server add 2 localhost:6382 slave`

**1 代表 group_id，必须为数字，且从 1 开始**

### 分配 slot

#### 手动分配

`codis-config -c ./config.ini slot range-set <slot_from> <slot_to> <group_id> <status>`

**slot** 默认为 **1024** 个，范围是 **0 - 1023**，需要将这 1024 个 slot 分配到集群中不同的 group 中。

例如将 1024 个 slot 平均分配到 

`./bin/codis-config -c ./config.ini slot range-set 0 511 1 online`

`./bin/codis-config -c ./config.ini slot range-set 512 1023 2 online`

#### 自动分配

在 dashboard 上可以自动分配 slot，会按照负载均衡的方式进行分配，不推荐使用，因为可能会造成大量数据的迁移。

或者使用命令进行自动分配

`./bin/codis-config -c ./config.ini slot rebalance`

### 启动 codis-proxy

`./bin/codis-proxy -c ./config.ini -L ./log/proxy.log --cpu=8 --addr=10.10.100.1:19000 --http-addr=10.10.100.1:11000`

**注意：这里 --addr 和 --http-addr 不要填 0.0.0.0，要绑定一个具体的 ip，不然 zookeeper 中存的将是hostname，会导致 dashboard 无法连接。**

codis-proxy 是无状态的，可以部署多个，且用 go 编写，可以利用多核，建议 cpu 设置核心数的一半到2/3，19000 即为访问 redis 集群的端口，11000 为获取 proxy 相关状态的端口。

之后使用 codis-config 将 codis-proxy 加入进来，也就是设置online（后来更新了一个版本，默认启动后即自动注册为online）

`bin/codis-config -c ./config.ini proxy online <proxy_name>`

**需要注意的是，启动 codis-proxy，会在 zookeeper 中注册一个 node，地址为 /zk/codis/db_test/fence，如果使用 kill -9 强行杀掉进程的话，这个会一直存在，需要手工删除。且 node 名称为 [hostname:port]，所以需要注意这个组合不能重复。**

### 主从切换

官方建议是手工操作，避免数据不一致的问题，但是没有自动容灾的话可用性太差。

官方另外提供了一个工具，**codis-ha**，这是一个通过 codis 开放的 api 实现自动切换主从的工具。该工具会在检测到 master 挂掉的时候将其下线并选择其中一个 slave 提升为 master 继续提供服务。

这个工具不是很好用，如果 codis-ha 连接 dashboard 失败之后进程就会自动退出，需要手动重启或者使用 supervisor 拉起来。另外，当有机器被提升为 master 之后，其他 slave 的状态不会改变，还是从原 master 同步数据。原来的 master 重启之后处于 offline 状态，也需要手动加入 group 指定为 slave。也就是说有master 挂掉后，其余机器的状态需要手动修改。

`./bin/codis-ha --codis-config=10.10.100.3:18087 --productName=common`

`10.10.100.14:18088` 为 dashboard 所在机器的 ip 和端口。

### 旧数据的迁移

官方提供了一个 **redis-port** 工具可以将旧 redis 中的数据实时迁移到 codis 集群中，之后需要修改各服务配置文件，重启服务，指向 codis 集群即可。

### 性能测试

测试环境： 24核 2.1GHz，4个redis实例

#### 不启用 pipeline

| | SET | GET | MSET |
|:--:|:--:|:--:|:--:|
|redis单机|58997.05|58651.02|33557.05|
|codis1核1proxy|42973.79|33003.30|12295.58|
|codis4核1proxy|44208.66|39936.10|21743.86|
|codis8核1proxy|39478.88|23052.10|24679.17|
|codis12核1proxy|28943.56|24224.81|21376.66|
|codis8核2proxy|62085.65|68964.40|48298.74|

#### pipeline = 100

| | SET | GET | MSET |
|:--:|:--:|:--:|:--:|
|redis单机|259067.36|340136.06|40387.72|
|codis1核1proxy|158982.52|166112.95|15199.88|
|codis4核1proxy|491159.12|403551.25|40157.42|
|codis8核1proxy|518134.72|537634.38|58156.44|
|codis12核1proxy|520833.34|500000.00|53418.80|
|codis8核2proxy|529812.81|607041.47|62872.28|


通过测试可以看出，使用 codis 会在性能上比原来直接使用 redis 会有所下降，但是优势就在于可以通过横向扩展（加机器）的方式去提高 redis 的存储容量以及并发量。
