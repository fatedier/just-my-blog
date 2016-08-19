---
categories:
    - "技术文章"
tags:
    - "golang"
    - "influxdb"
    - "数据库"
date: 2016-08-05
title: "InfluxDB详解之TSM存储引擎解析（一）"
url: "/2016/08/05/detailed-in-influxdb-tsm-storage-engine-one"
---

InfluxDB 项目更新比较快，google 了一下网上的一些文档基本上都是简单介绍了一下，而且很多都已经过时了，比如其中使用的 TSM 存储引擎，甚至官方文档上的内容都不是最新的。在源码里的 README 中有最新的设计实现的一些概要说明。

<!--more-->

我认为像这样的针对特殊场景进行优化的数据库会是今后数据库领域发展的主流，这里针对 InfluxDB 1.0.0 版本的源码深入研究一下 TSM 引擎的实现原理。TSM 存储引擎解决了 InfluxDB 之前使用的 LevelDB 和 BoltDB 时遇到的一些问题。

因为 TSM 是根据 LSM Tree 针对时间序列数据优化而来，所以总体架构设计上相差并不是很大，LSM Tree 的概念可以参考 [『LSM Tree 学习笔记』](/2016/06/15/learn-lsm-tree/)。

### 概念

首先需要简单了解 InfluxDB 的总体的架构以及一些关键概念，有一个总的思路，知道这个数据库是为了存储什么样的数据，解决哪些问题而诞生的，便于后面理解 TSM 存储引擎的详细的结构。可以简单看一下我之前的文章，[『时间序列数据库调研之InfluxDB』](/2016/07/05/research-of-time-series-database-influxdb/)。

#### 数据格式

在 InfluxDB 中，我们可以粗略的将要存入的一条数据看作**一个虚拟的 key 和其对应的 value(field value)**，格式如下：

`cpu_usage,host=server01,region=us-west value=0.64 1434055562000000000`

**虚拟的 key 包括以下几个部分： database, retention policy, measurement, tag sets, field name, timestamp。** database 和 retention policy 在上面的数据中并没有体现，通常在插入数据时在 http 请求的相应字段中指定。

* **database**: 数据库名，在 InfluxDB 中可以创建多个数据库，不同数据库中的数据文件是隔离存放的，存放在磁盘上的不同目录。
* **retention policy**: 存储策略，用于设置数据保留的时间，每个数据库刚开始会自动创建一个默认的存储策略 autogen，数据保留时间为永久，之后用户可以自己设置，例如保留最近2小时的数据。插入和查询数据时如果不指定存储策略，则使用默认存储策略，且默认存储策略可以修改。InfluxDB 会定期清除过期的数据。
* **measurement**: 测量指标名，例如 cpu_usage 表示 cpu 的使用率。
* **tag sets**: tags 在 InfluxDB 中会按照字典序排序，不管是 tagk 还是 tagv，只要不一致就分别属于两个 key，例如 `host=server01,region=us-west` 和 `host=server02,region=us-west` 就是两个不同的 tag set。
* **field name**: 例如上面数据中的 `value` 就是 fieldName，InfluxDB 中支持一条数据中插入多个 fieldName，这其实是一个语法上的优化，在实际的底层存储中，是当作多条数据来存储。
* **timestamp**: 每一条数据都需要指定一个时间戳，在 TSM 存储引擎中会特殊对待，以为了优化后续的查询操作。

#### Point

InfluxDB 中单条插入语句的数据结构，`series + timestamp` 可以用于区别一个 point，也就是说一个 point 可以有多个 field name 和 field value。

#### Series

series 相当于是 InfluxDB 中一些数据的集合，在同一个 database 中，retention policy、measurement、tag sets 完全相同的数据同属于一个 series，同一个 series 的数据在物理上会按照时间顺序排列存储在一起。

series 的 key 为 `measurement + 所有 tags 的序列化字符串`，这个 key 在之后会经常用到。

代码中的结构如下：

```go
type Series struct {
    mu          sync.RWMutex
    Key         string              // series key
    Tags        map[string]string   // tags
    id          uint64              // id
    measurement *Measurement        // measurement
}
```
#### Shard

shard 在 InfluxDB 中是一个比较重要的概念，它和 retention policy 相关联。每一个存储策略下会存在许多 shard，每一个 shard 存储一个指定时间段内的数据，并且不重复，例如 7点-8点 的数据落入 shard0 中，8点-9点的数据则落入 shard1 中。每一个 shard 都对应一个底层的 tsm 存储引擎，有独立的 cache、wal、tsm file。

创建数据库时会自动创建一个默认存储策略，永久保存数据，对应的在此存储策略下的 shard 所保存的数据的时间段为 7 天，计算的函数如下：

```go
func shardGroupDuration(d time.Duration) time.Duration {
    if d >= 180*24*time.Hour || d == 0 { // 6 months or 0
        return 7 * 24 * time.Hour
    } else if d >= 2*24*time.Hour { // 2 days
        return 1 * 24 * time.Hour
    }
    return 1 * time.Hour
}
```

如果创建一个新的 retention policy 设置数据的保留时间为 1 天，则单个 shard 所存储数据的时间间隔为 1 小时，超过1个小时的数据会被存放到下一个 shard 中。

### 组件

TSM 存储引擎主要由几个部分组成： **cache、wal、tsm file、compactor**。

![tsm-architecture](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-architecture.png)

#### Shard

shard 并不能算是其中的一个组件，因为这是在 tsm 存储引擎之上的一个概念。在 InfluxDB 中按照数据的时间戳所在的范围，会去创建不同的 shard，每一个 shard 都有自己的 cache、wal、tsm file 以及 compactor，这样做的目的就是为了可以通过时间来快速定位到要查询数据的相关资源，加速查询的过程，并且也让之后的批量删除数据的操作变得非常简单且高效。

在 LSM Tree 中删除数据是通过给指定 key 插入一个删除标记的方式，数据并不立即删除，需要等之后对文件进行压缩合并时才会真正地将数据删除，所以删除大量数据在 LSM Tree 中是一个非常低效的操作。

**而在 InfluxDB 中，通过 retention policy 设置数据的保留时间，当检测到一个 shard 中的数据过期后，只需要将这个 shard 的资源释放，相关文件删除即可，这样的做法使得删除过期数据变得非常高效。**

#### Cache

cache 相当于是 LSM Tree 中的 memtable，在内存中是一个简单的 map 结构，这里的 key 为 `seriesKey + 分隔符 + filedName`，目前代码中的分隔符为 `#!~#`，entry 相当于是一个按照时间排序的存放实际值的数组，具体结构如下：

```go
type Cache struct {
    commit  sync.Mutex
    mu      sync.RWMutex
    store   map[string]*entry
    size    uint64              // 当前使用内存的大小
    maxSize uint64              // 缓存最大值

    // snapshots are the cache objects that are currently being written to tsm files
    // they're kept in memory while flushing so they can be queried along with the cache.
    // they are read only and should never be modified
    // memtable 快照，用于写入 tsm 文件，只读
    snapshot     *Cache
    snapshotSize uint64
    snapshotting bool

    // This number is the number of pending or failed WriteSnaphot attempts since the last successful one.
    snapshotAttempts int

    stats        *CacheStatistics
    lastSnapshot time.Time
}
```

插入数据时，实际上是同时往 cache 与 wal 中写入数据，可以认为 cache 是 wal 文件中的数据在内存中的缓存。当 InfluxDB 启动时，会遍历所有的 wal 文件，重新构造 cache，这样即使系统出现故障，也不会导致数据的丢失。

**cache 中的数据并不是无限增长的，有一个 maxSize 参数用于控制当 cache 中的数据占用多少内存后就会将数据写入 tsm 文件。**如果不配置的话，默认上限为 25MB，每当 cache 中的数据达到阀值后，会将当前的 cache 进行一次快照，之后清空当前 cache 中的内容，再创建一个新的 wal 文件用于写入，剩下的 wal 文件最后会被删除，快照中的数据会经过排序写入一个新的 tsm 文件中。

**目前的 cache 的设计有一个问题**，当一个快照正在被写入一个新的 tsm 文件时，当前的 cache 由于大量数据写入，又达到了阀值，此时前一次快照还没有完全写入磁盘，InfluxDB 的做法是让后续的写入操作失败，用户需要自己处理，等待恢复后继续写入数据。

#### WAL

wal 文件的内容与内存中的 cache 相同，其作用就是为了持久化数据，当系统崩溃后可以通过 wal 文件恢复还没有写入到 tsm 文件中的数据。

由于数据是被顺序插入到 wal 文件中，所以写入效率非常高。但是如果写入的数据没有按照时间顺序排列，而是以杂乱无章的方式写入，数据将会根据时间路由到不同的 shard 中，每一个 shard 都有自己的 wal 文件，这样就不再是完全的顺序写入，对性能会有一定影响。看到官方社区有说后续会进行优化，只使用一个 wal 文件，而不是为每一个 shard 创建 wal 文件。

wal 单个文件达到一定大小后会进行分片，创建一个新的 wal 分片文件用于写入数据。

#### TSM file

单个 tsm file 大小最大为 2GB，用于存放数据。

TSM file 使用了自己设计的格式，对查询性能以及压缩方面进行了很多优化，在后面的章节会具体说明其文件结构。

#### Compactor

compactor 组件在后台持续运行，每隔 1 秒会检查一次是否有需要压缩合并的数据。

主要进行两种操作，一种是 cache 中的数据大小达到阀值后，进行快照，之后转存到一个新的 tsm 文件中。

另外一种就是合并当前的 tsm 文件，将多个小的 tsm 文件合并成一个，使每一个文件尽量达到单个文件的最大大小，减少文件的数量，并且一些数据的删除操作也是在这个时候完成。

### 目录与文件结构

InfluxDB 的数据存储主要有三个目录。

默认情况下是 **meta**, **wal** 以及 **data** 三个目录。

**meta** 用于存储数据库的一些元数据，**meta** 目录下有一个 `meta.db` 文件。

**wal** 目录存放预写日志文件，以 `.wal` 结尾。**data** 目录存放实际存储的数据文件，以 `.tsm` 结尾。这两个目录下的结构是相似的，其基本结构如下：

```bash
# wal 目录结构
-- wal
   -- mydb
      -- autogen
         -- 1
            -- _00001.wal
         -- 2
            -- _00035.wal
      -- 2hours
         -- 1
            -- _00001.wal

# data 目录结构
-- data
   -- mydb
      -- autogen
         -- 1
            -- 000000001-000000003.tsm
         -- 2
            -- 000000001-000000001.tsm
      -- 2hours
         -- 1
            -- 000000002-000000002.tsm
```

其中 **mydb** 是数据库名称，**autogen** 和 **2hours** 是存储策略名称，再下一层目录中的以数字命名的目录是 shard 的 ID 值，比如 **autogen** 存储策略下有两个 shard，ID 分别为 1 和 2，shard 存储了某一个时间段范围内的数据。再下一级的目录则为具体的文件，分别是 `.wal` 和 `.tsm` 结尾的文件。

#### WAL 文件

![wal-entry](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-wal-entry.png)

wal 文件中的一条数据，对应的是一个 key(measument + tags + fieldName) 下的所有 value 数据，按照时间排序。

* **Type (1 byte)**: 表示这个条目中 value 的类型。
* **Key Len (2 bytes)**: 指定下面一个字段 key 的长度。
* **Key (N bytes)**: 这里的 key 为 measument + tags + fieldName。
* **Count (4 bytes)**: 后面紧跟着的是同一个 key 下数据的个数。
* **Time (8 bytes)**: 单个 value 的时间戳。
* **Value (N bytes)**: value 的具体内容，其中 float64, int64, boolean 都是固定的字节数存储比较简单，通过 Type 字段知道这里 value 的字节数。string 类型比较特殊，对于 string 来说，N bytes 的 Value 部分，前面 4 字节用于存储 string 的长度，剩下的部分才是 string 的实际内容。

#### TSM 文件

单个 tsm 文件的主要格式如下：

![tsm-file](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-file.png)

主要分为四个部分： **Header, Blocks, Index, Footer**。

其中 **Index** 部分的内容会被缓存在内存中，下面详细说明一下每一个部分的数据结构。

##### Header

![tsm-file-header](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-file-header.png)

* **MagicNumber  (4 bytes)**: 用于区分是哪一个存储引擎，目前使用的 tsm1 引擎，MagicNumber 为 `0x16D116D1`。
* **Version (1 byte)**: 目前是 tsm1 引擎，此值固定为 `1`。

##### Blocks

![tsm-file-blocks](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-file-blocks.png)

Blocks 内部是一些连续的 Block，block 是 InfluxDB 中的最小读取对象，每次读取操作都会读取一个 block。每一个 Block 分为 CRC32 值和 Data 两部分，CRC32 值用于校验 Data 的内容是否有问题。Data 的长度记录在之后的 Index 部分中。

**Data 中的内容根据数据类型的不同，在 InfluxDB 中会采用不同的压缩方式**，float 值采用了 Gorilla float compression，而 timestamp 因为是一个递增的序列，所以实际上压缩时只需要记录时间的偏移量信息。string 类型的 value 采用了 snappy 算法进行压缩。

Data 的数据解压后的格式为 8 字节的时间戳以及紧跟着的 value，value 根据类型的不同，会占用不同大小的空间，其中 string 为不定长，会在数据开始处存放长度，这一点和 WAL 文件中的格式相同。

##### Index

![tsm-file-index](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-file-index.png)

Index 存放的是前面 Blocks 里内容的索引。索引条目的顺序是先按照 key 的字典序排序，再按照 time 排序。InfluxDB 在做查询操作时，可以根据 Index 的信息快速定位到 tsm file 中要查询的 block 的位置。

这张图只展示了其中一部分，用结构体来表示的话类似下面的代码：

```go
type BlockIndex struct {
    MinTime     int64
    MaxTime     int64
    Offset      int64
    Size        uint32
}

type KeyIndex struct {
    KeyLen      uint16
    Key         string
    Type        byte
    Count       uint32
    Blocks      []*BlockIndex
}

type Index []*KeyIndex
```

* **Key Len (2 bytes)**: 下面一个字段 key 的长度。
* **Key (N bytes)**: 这里的 key 指的是 seriesKey + 分隔符 + fieldName。
* **Type (1 bytes)**: fieldName 所对应的 fieldValue 的类型，也就是 Block 中 Data 内的数据的类型。
* **Count (2 bytes)**: 后面紧跟着的 Blocks 索引的个数。

后面四个部分是 block 的索引信息，根据 Count 中的个数会重复出现，每个 block 索引固定为 28 字节，按照时间排序。

* **Min Time (8 bytes)**: block 中 value 的最小时间戳。
* **Max Time (8 bytes)**: block 中 value 的最大时间戳。
* **Offset (8 bytes)**: block 在整个 tsm file 中的偏移量。
* **Size (4 bytes)**: block 的大小。根据 Offset + Size 字段就可以快速读取出一个 block 中的内容。

##### 间接索引

间接索引只存在于内存中，是为了可以快速定位到一个 key 在详细索引信息中的位置而创建的，可以被用于二分查找来实现快速检索。

![tsm-file-index-simple](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-file-index-simple.png)

![tsm-file-sub-index](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-file-sub-index.png)

offsets 是一个数组，其中存储的值为每一个 key 在 Index 表中的位置，由于 key 的长度固定为 2字节，所以根据这个位置就可以找到该位置上对应的 key 的内容。

当指定一个要查询的 key 时，就可以通过二分查找，定位到其在 Index 表中的位置，再根据要查询的数据的时间进行定位，由于 KeyIndex  中的 BlockIndex 结构是定长的，所以也可以进行一次二分查找，找到要查询的数据所在的 BlockIndex 的内容，之后根据偏移量以及 block 长度就可以从 tsm 文件中快速读取出一个 block 的内容。

##### Footer

![tsm-file-footer](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2016/2016-08-05-detailed-in-influxdb-tsm-storage-engine-one-tsm-file-footer.png)

tsm file 的最后8字节的内容存放了 Index 部分的起始位置在 tsm file 中的偏移量，方便将索引信息加载到内存中。

**由于内容较多，具体的写入与查询操作的流程，以及部分代码的详解会在下一篇文章中介绍。**
