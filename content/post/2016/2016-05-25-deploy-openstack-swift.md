---
categories:
    - "技术文章"
tags:
    - "openstack"
    - "swift"
    - "分布式存储"
date: 2016-05-25
title: "部署openstack的对象存储服务swift"
url: "/2016/05/25/deploy-openstack-swift"
---

OpenStack Swift 是一个开源项目，提供了弹性可伸缩、高可用的分布式对象存储服务，适合存储大规模非结构化数据。由于要开发自己的分布式存储应用，需要借鉴 swift 的一些架构，所以在自己的机器上搭建了一个集群环境用于测试。

<!--more-->

### 环境

一台物理机上，开了三台虚拟机，操作系统是 Centos7

ip 为 **192.168.2.129, 192.168.2.130, 192.168.2.131**

之前安装过一次，当时是 2.4.0 版本，目前最新的是 2.7.0 版本，最新的版本由于我的机器上缺少某些动态库，所以还是选择了比较熟悉的 2.4.0 版本，基本上的步骤是一样的。

后续的安装步骤需要在三台机器上全部执行一遍，下文中的 `user:user` 根据需要修改为自己机器上的用户。

整个步骤参考了官方的文档： http://docs.openstack.org/developer/swift/development_saio.html

### 安装各种依赖

```bash
sudo yum install curl gcc memcached rsync sqlite xfsprogs git-core \
    libffi-devel xinetd liberasurecode-devel \
    python-setuptools \
    python-coverage python-devel python-nose \
    pyxattr python-eventlet \
    python-greenlet python-paste-deploy \
    python-netifaces python-pip python-dns \
    python-mock
```

### 创建磁盘设备

由于 swift 需要使用 xfs 格式的磁盘，这里我们使用回环设备。

#### 创建一个用于回环设备的2GB大小的文件

```bash
sudo mkdir /srv
sudo truncate -s 1GB /srv/swift-disk
sudo mkfs.xfs /srv/swift-disk
```

#### 修改 /etc/fstab

```bash
/srv/swift-disk /srv/node/sdb1 xfs loop,noatime,nodiratime,nobarrier,logbufs=8 0 0
```

#### 创建挂载点并进行挂载

```bash
sudo mkdir -p /srv/node/sdb1
sudo mount /srv/node/sdb1
sudo chown -R user:user /srv/node
```

#### 下载安装 swift 和 swift-client

从 git 下载这两个项目之后切换到 2.4.0 版本，安装 python 依赖以后使用 `python setup.py` 安装。

直接通过 yum 安装的 pip 可能版本不是最新的，需要升级，使用 `pip install --upgrade pip` 升级。

##### swift-client

```bash
git clone https://github.com/openstack/python-swiftclient.git
git checkout 2.4.0
cd ./python-swiftclient; sudo python setup.py develop; cd -
```

##### swift

```bash
git clone https://github.com/openstack/swift.git
git checkout 2.4.0
cd ./swift; sudo pip install -r requirements.txt; sudo python setup.py develop; cd -
```

##### 配置 /etc/rc.local

需要在每次开机时都创建一些需要的目录。

```bash
sudo mkdir -p /var/run/swift
sudo chown user:user /var/run/swift
sudo mkdir -p /var/cache/swift
sudo chown user:user /var/cache/swift
```

### 配置 rsync

#### 修改 /etc/rsyncd.conf

```bash
# /etc/rsyncd: configuration file for rsync daemon mode
uid = root
gid = root
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = 0.0.0.0

[account]
max connections = 25
path = /srv/node/
read only = false
lock file = /var/lock/account.lock

[container]
max connections = 25
path = /srv/node/
read only = false
lock file = /var/lock/container.lock

[object]
max connections = 25
path = /srv/node/
read only = false
lock file = /var/lock/object.lock
```

#### 启动 rsync 并设置开机启动

```bash
sudo chkconfig rsyncd on
sudo service rsyncd start
```

### 配置rsyslog让每个程序输出独立的日志（可选）

swift 默认将日志信息输出到文件 /var/log/syslog 中。如果要按照个人需求设置 rsyslog，生成另外单独的 swift日志文件，就需要另外配置。

#### 创建日志配置文件 /etc/rsyslog.d/10-swift.conf

```bash
# Uncomment the following to have a log containing all logs together
#local1,local2,local3,local4,local5.*   /var/log/swift/all.log

# Uncomment the following to have hourly proxy logs for stats processing
$template HourlyProxyLog,"/var/log/swift/hourly/%$YEAR%%$MONTH%%$DAY%%$HOUR%"
#local1.*;local1.!notice ?HourlyProxyLog

local1.*;local1.!notice /var/log/swift/proxy.log
local1.notice           /var/log/swift/ proxy.error
local1.*                ~

local2.*;local2.!notice /var/log/swift/object.log
local2.notice           /var/log/swift/ object.error
local2.*                ~

local3.*;local3.!notice /var/log/swift/container.log
local3.notice           /var/log/swift/ container.error
local3.*                ~

local4.*;local4.!notice /var/log/swift/account.log
local4.notice           /var/log/swift/ account.error
local4.*                ~
```

#### 编辑文件 /etc/rsyslog.conf，更改参数 $PrivDropToGroup 为 adm

```bash
$PrivDropToGroup adm
```

#### 创建 /var/log/swift 目录，用于存放独立日志

此外，上面的 `10-swift.conf` 文件中设置了输出 Swift Proxy Server 每小时的 stats 日志信息，于是也要创建 `/var/log/swift/hourly` 目录。

```bash
sudo mkdir -p /var/log/swift/hourly
```

#### 更改 swift 独立日志目录的权限

```bash
chown -R root.adm /var/log/swift
```

#### 重启 rsyslog 服务

```bash
sudo service rsyslog restart
```

### 启动 memcached 并设置开机启动

```bash
sudo service memcached start
sudo chkconfig memcached on
```

### 配置swift相关的配置文件

#### 创建存储 swift 配置文件的目录

```bash
sudo mkdir /etc/swift
sudo chown -R user:user /etc/swift
```

#### 创建 swift 配置文件 /etc/swift/swift.conf

```bash
[swift-hash]

# random unique string that can never change (DO NOT LOSE)
swift_hash_path_suffix = jtangfs
```

#### 配置 account 服务 /etc/swift/account-server.conf

```bash
[DEFAULT]
devices = /srv/node
mount_check = false
bind_ip = 0.0.0.0
bind_port = 6002
workers = 4
user = wcl
log_facility = LOG_LOCAL4

[pipeline:main]
pipeline = account-server

[app:account-server]
use = egg:swift#account

[account-replicator]
[account-auditor]
[account-reaper]
```

#### 配置 container 服务 /etc/swift/container-server.conf

```bash
[DEFAULT]
devices = /srv/node
mount_check = false
bind_ip = 0.0.0.0
bind_port = 6001
workers = 4
user = wcl
log_facility = LOG_LOCAL3

[pipeline:main]
pipeline = container-server

[app:container-server]
use = egg:swift#container

[container-replicator]

[container-updater]

[container-auditor]

[container-sync]
```

#### 配置 object 服务 /etc/swift/object-server.conf

```bash
[DEFAULT]
devices = /srv/node
mount_check = false
bind_ip = 0.0.0.0
bind_port = 6000
workers = 4
user = wcl
log_facility = LOG_LOCAL2

[pipeline:main]
pipeline = object-server

[app:object-server]
use = egg:swift#object

[object-replicator]

[object-updater]

[object-auditor]
```

#### 配置 proxy 服务 /etc/swift/proxy-server.conf

```bash
[DEFAULT]
bind_port = 8080
user = wcl
workers = 2
log_facility = LOG_LOCAL1

[pipeline:main]
pipeline = healthcheck cache tempauth proxy-logging proxy-server

[app:proxy-server]
use = egg:swift#proxy
allow_account_management = true
account_autocreate = true

[filter:tempauth]
use = egg:swift#tempauth
user_admin_admin = admin .admin .reseller_admin
user_test_tester = testing .admin
user_test2_tester2 = testing2 .admin
user_test_tester3 = testing3
reseller_prefix = AUTH
token_life = 86400
# account和token的命名前缀，注意此处不可以加"_"。
# 例如X-Storage-Ur可能l为http://127.0.0.1:8080/v1/AUTH_test
# 例如X-Auth-Token为AUTH_tk440e9bd9a9cb46d6be07a5b6a585f7d1# token的有效期，单位：秒。

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:cache]
use = egg:swift#memcache

# 这里可以是多个memcache server，proxy会自动当作一个集群来使用# 例如 memcache_servers = 192.168.2.129:11211,192.168.2.130:11211,192.168.2.131

[filter:proxy-logging]
use = egg:swift#proxy_logging
```

**注：`user_admin_admin = admin .admin .reseller_admin` 后面还可以增加一项 `<storage-url>`，显示地指定 swift 为该用户提供的存储服务入口，admin 用户通过认证后，swift 会把 Token 和该 `<storage-url>`  返回给用户，此后 admin 用户可以使用该 `<storage-url>` 访问 swift 来请求存储服务。特别值得说明的是，如果在 Proxy Server 前面增加了负载均衡器（如 nginx），那么该 `<storage-url>` 应该指向负载均衡器，使得用户在通过认证后，向负载均衡器发起存储请求，再由负载均衡器将请求均衡地分发给 Proxy Server 集群。此时的 `<storage-url>` 形如 `http://<LOAD_BALANCER_HOSTNAME>:<PORT>/v1/AUTH_admin`。**

### 创建 ring 文件

**swift** 安装完成后会有一个 **swift-ring-builder** 程序用于对 ring 的相关操作。

#### 生成 ring

```bash
swift-ring-builder account.builder create 18 3 1
swift-ring-builder container.builder create 18 3 1
swift-ring-builder object.builder create 18 3 1
```

需要事先创建好3个 ring，18 表示 partition 数为2的18次方，3表示 replication 数为3，1 表示分区数据的最短迁移间隔时间为1小时。（官网说明里如果移除设备的话不在这个限制内）

### 向 ring 中加入设备

```bash
swift-ring-builder account.builder add z1-192.168.2.129:6002/sdb1 100
swift-ring-builder container.builder add z1-192.168.2.129:6001/sdb1 100
swift-ring-builder object.builder add z1-192.168.2.129:6000/sdb1 100

swift-ring-builder account.builder add z2-192.168.2.130:6002/sdb1 100
swift-ring-builder container.builder add z2-192.168.2.130:6001/sdb1 100
swift-ring-builder object.builder add z2-192.168.2.130:6000/sdb1 100

swift-ring-builder account.builder add z2-192.168.2.131:6002/sdb1 100
swift-ring-builder container.builder add z2-192.168.2.131:6001/sdb1 100
swift-ring-builder object.builder add z2-192.168.2.131:6000/sdb1 100
```

**z1** 和 **z2** 表示 **zone1** 和 **zone2**（**zone** 这个概念是虚拟的，可以将一个 **device** 划定到一个 **zone**，在分配 **partition** 的时候会考虑到这个因素，尽量划分到不同的 **zone** 中）。

**sdb1** 为 **swift** 所使用的存储空间。

**100** 代表设备的权重，也是在分配 **partition** 的时候会考虑的因素。

#### rebalance

```bash
swift-ring-builder account.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder object.builder rebalance
```

#### 将 ring 文件传输到其他机器的 /etc/swift 目录下

最终生成的 ring 文件以 `.gz` 结尾。

### 创建初始化、起停等脚本

由于 swift 涉及的组件较多，起停都比较麻烦，所以最好先写好起停脚本。

#### remake_rings.sh 脚本文件，用于完成 ring 的重新创建

```bash
#!/bin/bash
cd /etc/swift

rm -f *.builder *.ring.gz backups/*.builder backups/*.ring.gz

swift-ring-builder account.builder create 18 3 1
swift-ring-builder container.builder create 18 3 1
swift-ring-builder object.builder create 18 3 1

swift-ring-builder account.builder add z1-192.168.2.129:6002/sdb1 100
swift-ring-builder container.builder add z1-192.168.2.129:6001/sdb1 100
swift-ring-builder object.builder add z1-192.168.2.129:6000/sdb1 100

swift-ring-builder account.builder add z1-192.168.2.130:6002/sdb1 100
swift-ring-builder container.builder add z1-192.168.2.130:6001/sdb1 100
swift-ring-builder object.builder add z1-192.168.2.130:6000/sdb1 100

swift-ring-builder account.builder add z1-192.168.2.131:6002/sdb1 100
swift-ring-builder container.builder add z1-192.168.2.131:6001/sdb1 100
swift-ring-builder object.builder add z1-192.168.2.131:6000/sdb1 100

swift-ring-builder account.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder object.builder rebalance
```

#### reset_swift.sh 脚本文件，用于一键清空 swift 的对象数据和日志，完全重置

```bash
#!/bin/bash
swift-init all stop

find /var/log/swift -type f -exec rm -f {} \;

sudo umount /srv/node/sdb1
sudo mkfs.xfs -f -i size=1024 /srv/swift-disk
sudo mount /srv/node/sdb1

sudo chown wcl:wcl /srv/node/sdb1

sudo rm -f /var/log/debug /var/log/messages /var/log/rsyncd.log /var/log/syslog
sudo service rsyslog restart
sudo service rsyncd restart
sudo service memcached restart
```

#### start_main.sh 脚本文件，用于启动 swift 所有基础服务

```bash
#!/bin/bash
swift-init main start
```

#### stop_main.sh 脚本文件，用于关闭 swift 所有基础服务

```bash
#!/bin/bash
swift-init main stop
```

#### start_all.sh 脚本文件

一键启动 swift 的所有服务。

```bash
#!/bin/bash
swift-init proxy start
swift-init account-server start
swift-init account-replicator start
swift-init account-auditor start
swift-init container-server start
swift-init container-replicator start
swift-init container-updater start
swift-init container-auditor start
swift-init object-server start
swift-init object-replicator start
swift-init object-updater start
swift-init object-auditor start
```

#### stop_all.sh 脚本文件

一键关闭 swift的所有服务。

```bash
#!/bin/bash
swift-init proxy stop
swift-init account-server stop
swift-init account-replicator stop
swift-init account-auditor stop
swift-init container-server stop
swift-init container-replicator stop
swift-init container-updater stop
swift-init container-auditor stop
swift-init object-server stop
swift-init object-replicator stop
swift-init object-updater stop
swift-init object-auditor stop
```

#### 启动 swift 服务

```bash
./start_all.sh
```

### 动态扩容

重新编写 **remake_rings.sh** 脚本中的内容，加上需要添加的机器信息，重新生成 ring 文件。

将新生成的 ring 文件放到每一个服务器的 `/etc/swift` 目录下。

swift 的各个组件程序会定期重新读取 rings 文件。

### 一些需要注意的地方

- 服务器时间必须一致，不一致的话会出现问题。测试中有一台服务器比其他的慢了2小时，结果向这台 proxy  上传文件，返回成功，但是其实并没有上传成功，可能是由于时间原因，在其他机器看来这个文件已经被删除掉了。

### RESTful API 及测试

swift 可以通过 swift-proxy 提供的 RESTful API 来进行操作。

另外一种方法就是使用 `swift` 程序来进行增删查改的操作，可以实现和 RESTful API 相同的功能。

**所有的操作都需要先获取一个 auth-token，之后的所有操作都需要在 header 中附加上 X-Auth-Token 字段的信息进行权限认证。有一定时效性，过期后需要再次获取。**

#### 获取 X-Storage-Url 和 X-Auth-Token

```bash
curl http://127.0.0.1:8080/auth/v1.0 -v -H 'X-Storage-User: test:tester' -H 'X-Storage-Pass: testing'
```

这里的用户和密码是在 `proxy-server.conf` 中配置的。

返回结果

```bash
< HTTP/1.1 200 OK
< X-Storage-Url: http://127.0.0.1:8080/v1/AUTH_test
< X-Auth-Token: AUTH_tk039a65cb62594b319faea9dc492039a2
< Content-Type: text/html; charset=UTF-8
< X-Storage-Token: AUTH_tk039a65cb62594b319faea9dc492039a2
< X-Trans-Id: tx7bcd450378d84b56b1482-005745b5c8
< Content-Length: 0
< Date: Wed, 25 May 2016 14:25:12 GMT
```

#### 查看账户信息

```bash
curl http://127.0.0.1:8080/v1/AUTH_test -v -H 'X-Auth-Token: AUTH_tk039a65cb62594b319faea9dc492039a2'
```

返回结果

```bash
< HTTP/1.1 200 OK
< Content-Length: 5
< X-Account-Object-Count: 1
< X-Account-Storage-Policy-Policy-0-Bytes-Used: 4
< X-Account-Storage-Policy-Policy-0-Container-Count: 1
< X-Timestamp: 1464106581.68979
< X-Account-Storage-Policy-Policy-0-Object-Count: 1
< X-Account-Bytes-Used: 4
< X-Account-Container-Count: 1
< Content-Type: text/plain; charset=utf-8
< Accept-Ranges: bytes
< X-Trans-Id: tx59e9c2f1772349d684d04-005745b713
< Date: Wed, 25 May 2016 14:30:43 GMT
```

#### 创建 container

```bash
curl http://127.0.0.1:8080/v1/AUTH_test/default -X PUT -H "X-Auth_Token: AUTH_tk039a65cb62594b319faea9dc492039a2"
```

在 test 用户下创建了一个名为 default 的 container。

#### RESTful API 总结

| 资源类型 | URL | GET | PUT | POST | DELETE | HEAD |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 账户 | /account/ | 获取容器列表 | - | - | - | 获取账户元数据 |
| 容器 | /account/container | 获取对象列表 | 创建容器 | 更新容器元数据 | 删除容器 | 获取容器元数据 |
| 对象 | /account/container/object | 获取对象内容和元数据 | 创建、更新或拷贝对象 | 更新对象元数据 | 删除对象 | 获取对象元数据 |

#### 直接使用 swift 客户端程序进行操作

**-A** 参数指定 url，**-U** 参数指定用户，**-K** 参数指定密码。

##### 查看指定账户的 swift 存储信息

```bash
swift -A http://127.0.0.1:8080/auth/v1.0 -U test:tester -K testing stat
```

##### 创建 container

```bash
swift -A http://127.0.0.1:8080/auth/v1.0 -U test:tester -K testing post default
```

##### 查看 test 用户的 container 列表

```bash
swift -A http://127.0.0.1:8080/auth/v1.0 -U test:tester -K testing list
```

##### 上传Object（文件），上传 test.cpp 文件到 default 容器中

```bash
swift -A http://127.0.0.1:8080/auth/v1.0 -U test:tester -K testing upload default ./dd.cpp
```

##### 查看容器中的内容

```bash
swift -A http://127.0.0.1:8080/auth/v1.0 -U test:tester -K testing list default
```

##### 下载Object（文件）

```bash
swift -A http://127.0.0.1:8080/auth/v1.0 -U test:tester -K testing download default dd.cpp
```
