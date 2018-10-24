---
categories:
    - "技术文章"
tags:
    - "数据库"
    - "分布式存储"
date: 2016-07-06
title: "InfluxDB 与 OpenTSDB 对比测试"
url: "/2016/07/06/test-influxdb-and-opentsdb"
---

通过调研，在时间序列数据库的选择上，从社区活跃度，易用程度，综合性能上来看比较合适的就是 OpenTSDB 和 InfluxDB，所以对这两个数据库进行了一个简单测试。

<!--more-->

### 时间序列数据库热度排名

![db-rank](http://image.fatedier.com/pic/2016/2016-07-06-test-influxdb-and-opentsdb-db-rank.png)

### 测试环境

青云 centos7

4 cpu，8GB RAM

### 测试样本

**metric** 从 cpu_load1 - cpu_load10 共10个。

**tags** 只有一个，host_id 为 1-100。

**time** 为 1467000000 - 1467010000，各维度每秒生成1条数据。

**value** 取值为 0.1-0.9。

合计数据量为 10 * 100 * 10000 = 1000w。

### 查询测试用例

#### 查询1：单条查询

指定 metricName 以及 host_id，对 time 在 1467000000 和 1467005000 内的数据按照每3分钟的粒度进行聚合计算平均值。 

例如 InfluxDB 中的查询语句

`select mean(value) from cpu_load1 where host_id = '1' and time > 1467000000000000000 and time < 1467005000000000000 group by time(3m)`

#### 查询2：批量10条不同 metricName 查询

单条查询的基础上修改成不同的 metricName

### InfluxDB

并发数 50 通过 http 写入，每次 100 条数据

#### 资源占用

cpu 使用率维持在 100% 左右，耗时 1m58s，约 84746/s

磁盘占用 70MB

#### 查询1

* Num1: 0.010s
* Num2: 0.010s

#### 查询2

* Num 1: 0.029s
* Num 2: 0.021s

### OpenTSDB

并发数 50 通过http写入，每次 100 条数据

#### 资源占用

cpu 开始时跑满，之后在250%左右 耗时 2m16s，约 73529/s

磁盘占用 1.6GB，由于是简单部署，这里 HBase 没有启用 lzo 压缩，据说压缩之后只需要占用原来 1/5 的空间，也就是 320MB。

#### 查询1

* Num 1: 0.285s
* Num 2: 0.039s

#### 查询2

* Num 1: 0.111s
* Num 2: 0.040s

### 总结

一开始是准备在本地的一个2核2GB的虚拟机里进行测试，InfluxDB 虽然比较慢，但是测试完成，而 OpenTSDB 测试过程中，要么 zookeeper 出现故障，要么 Hbase 异常退出，要么无法正常写入数据，始终无法完成测试。更换成配置更高的青云服务器后，两者都能正常完成测试。

在单机部署上，InfluxDB 非常简单，一两分钟就可以成功运行，而 OpenTSDB 需要搭建 Hbase，创建 TSD 用到的数据表，配置 JAVA 环境等，相对来说更加复杂。

资源占用方面，InfluxDB 都要占据优势，cpu 消耗更小，磁盘占用更是小的惊人。

查询速度，由于测试样本数据量还不够大，速度都非常快，可以看到 InfluxDB 的查询在 10ms 这个数量级，而 OpenTSDB 则慢了接近 10 倍，第二次查询时，由于缓存的原因，OpenTSDB 的查询速度也相当快。

集群方面，目前 InfluxDB 还没有比较好的解决方案，而 OpenTSDB 基于 HBase，这一套集群方案已经被很多大公司采用，稳定运行。
