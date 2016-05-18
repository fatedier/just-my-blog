---
categories:
    - "技术文章"
tags:
    - "opentsdb"
    - "数据库"
date: 2016-03-12
title: "OpenTSDB部署与使用"
url: "/2016/03/12/install-and-use-opentsdb"
---

OpenTSDB 是基于 HBase 存储时间序列数据的一个开源数据库，对于存储监控系统采集的数据来说非常合适，不仅在写入查询上有很高的效率，而且节省存储空间。

<!--more-->

### 安装 HBase

因为 OpenTSDB 的后端存储使用的是 HBase，所以我们需要先安装 HBase。

参考文档： [Quick Start - Standalone HBase](https://hbase.apache.org/book.html#quickstart)

这里简单搭建了一个**单机**的 HBase 环境：

1. 安装 JDK 环境，centos 上可以直接通过 yum 安装。
2. 下载 HBase，[http://apache.fayea.com/hbase/stable](http://apache.fayea.com/hbase/stable)，这里我们选择下载 stable 的 1.1.3 版本，文件名为 `hbase-1.1.3-bin.tar.gz`，解压到任意目录。
3. 修改 `conf/hbase-env.sh` ，设置  `JAVA_HOME=/usr`，这个是 `/bin/java` 所在的目录，通过 `which java` 查看。
4. 修改 `conf/hbase-site.xml`， 设置 hbase 的数据存储目录以及 zookeeper 的数据存储目录，默认会放到 `/tmp` 目录下，这个目录机器重启后会清空，所以需要更改目录。
5. 执行 `bin/start-hbase.sh` 启动 HBase，之后可以通过 `jps` 命令来查看 HMaster 进程是否启动成功。 `bin/stop-hbase.sh` 用于关闭 HBase。

`conf/hbase-site.xml` 的配置示例如下

```xml
<configuration>
    <property>
        <name>hbase.rootdir</name>
        <value>file:///home/testuser/hbase</value>
    </property>
    <property>
        <name>hbase.zookeeper.property.dataDir</name>
        <value>/home/testuser/zookeeper</value>
    </property>
</configuration>
```

### 通过命令行操作 HBase

这里可以稍微熟悉一下 HBase 的操作，非必须。

##### 连接到 HBase

`./bin/hbase shell`

##### 创建一张表

`create 'test', 'cf'`

##### 查看表信息

`list 'test'`

##### 向表中插入数据

```bash
put 'test', 'row1', 'cf:a', 'value1'
put 'test', 'row2', 'cf:b', 'value2'
put 'test', 'row3', 'cf:c', 'value3'
``` 

##### 查看表中所有数据

`scan 'test'`

##### 查看指定行的数据

`get 'test', 'row1'`

##### 禁用指定表（删除表或修改表设置前需要先禁用该表）

`disable 'test'`

##### 恢复指定表

`enable 'test'`

##### 删除表

`drop 'test'`

### 安装OpenTSDB

**参考文章**

[http://debugo.com/opentsdb/](http://debugo.com/opentsdb/)

[http://opentsdb.net/docs/build/html/installation.html#runtime-requirements](http://opentsdb.net/docs/build/html/installation.html#runtime-requirements)

1. 直接从 github 上下载 OpenTSDB 的 [release](https://github.com/OpenTSDB/opentsdb) 版本的 RPM 包。安装 `yum localinstall opentsdb-2.2.0.noarch.rpm`。

2. 配置完成后，我们通过下面命令在 HBase 中建立 opentsdb 所需的表。默认情况下 opentsdb 建立的 HBase 表启用了 lzo 压缩。需要开启 Hadoop 中的 lzo 压缩支持， 这里我们直接在下面脚本中把 COMPRESSION 的支持关闭。修改 `/usr/share/opentsdb/tools/create_table.sh`，设置 `COMPRESSION=NONE`，并且在文件开始处设置 HBase 所在目录， `HBASE_HOME=/home/xxx/hbase-1.1.3`。之后执行该脚本，在 HBase 中创建相应的表。

3. 修改 OpenTSDB 的配置文件，`/etc/opentsdb/opentsdb.conf`，例如绑定的端口号等。**这里需要注意的是 tsd.core.auto_create_metrics 从 false 改为 true。这样上传数据时会自动创建 metric，否则会提示 Unknown metric 的错误。也可以设置为 false，但是使用 `tsdb mkmetric proc.loadavg.1m` 来手动添加 metric。**

4. 启动 OpenTSDB，`service opentsdb start` 或者 `nohup tsdb tsd &`。

5. 通过浏览器访问 http://x.x.x.x:4242 查看是否安装成功。

### HTTP API

#### 插入数据

**/api/put**

根据 url 参数的不同，可以选择是否获取详细的信息。

**/api/put?summary**        // 返回失败和成功的个数

```json
{
    "failed": 0,
    "success": 1
}
```

**/api/put?details**        // 返回详细信息

```json
{
    "errors": [],
    "failed": 0,
    "success": 1
}
```

通过POST方式插入数据，JSON格式，例如

```json
{
    "metric":"self.test", 
    "timestamp":1456123787, 
    "value":20, 
    "tags":{
        "host":"web1"
    }
}
```

### 查询数据

**/api/query**

可以选择 Get 或者 Post 两种方式，推荐使用 Post 方式，JSON 格式。

```json
{
    "start": 1456123705,
    "end": 1456124985,
    "queries": [
        {
            "aggregator": "sum",
            "metric": "self.test",
            "tags": {
                "host": "web1"
            }
        },
        {
            "aggregator": "sum",
            "metric": "self.test",
            "tags": {
                "host": "web2"
            }
        }
    ]
}
```

start 和 end 为指定的查询时间段。

queries 为一个数组，可以指定多个查询。

metric 和 tags 是用于过滤的查询条件。

**返回字符串也为json格式**

```json
[
    {
        "metric": "self.test",
        "tags": {},
        "aggregateTags": [
            "host"
        ],
        "dps": {
            "1456123785": 10,
            "1456123786": 10
        }
    },
    {
        "metric": "self.test",
        "tags": {
            "host": "web1"
        },
        "aggregateTags": [],
        "dps": {
            "1456123784": 10,
            "1456123786": 15
        }
    }
]
```

#### 聚合

**aggregator** 是用于对查询结果进行聚合，将同一 unix 时间戳内的数据进行聚合计算后返回结果，例如如果 tags 不填，1456123705 有两条数据，一条 `host=web1`，另外一条 `host=web2`，值都为10，那么返回的该时间点的值为 sum 后的 20。

#### 条件过滤

可以针对 tag 进行一些条件的过滤，返回 tag 中 host 的值以 web 开头的数据。

```json
"queries": [
    {
        "aggregator": "sum",
        "metric": "self.test",
        "filters": [
            {
                "type": "wildcard",
                "tagk": "host",
                "filter": "web*"
            }
        ]
    }
]
```

#### downsample

简单来说就是对指定时间段内的数据进行聚合后返回，例如需要返回每分钟的平均值数据

```json
"queries": [
    {
        "aggregator": "sum",
        "metric": "self.test",
        "downsample": "1m-avg",
        "tags": {
            "host": "web1"
        }
    }
]
```
