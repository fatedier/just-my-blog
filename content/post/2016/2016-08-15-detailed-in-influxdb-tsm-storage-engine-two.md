---
categories:
    - "技术文章"
tags:
    - "golang"
    - "influxdb"
    - "数据库"
date: 2016-08-15
title: "InfluxDB详解之TSM存储引擎解析（二）"
url: "/2016/08/15/detailed-in-influxdb-tsm-storage-engine-two"
---

上一篇文章主要介绍了 TSM 存储引擎一些相关的概念、组件以及数据存储的目录结构，文件组成结构等内容。这一篇将会尽量从 InfluxDB 源码的角度，深入讲解数据插入、查询、合并等操作的具体流程以及内部数据结构的设计。

<!--more-->

上一篇文章传送门： [『InfluxDB详解之TSM存储引擎解析（一）』](http://blog.fatedier.com/2016/08/05/detailed-in-influxdb-tsm-storage-engine-one/)。

### 主要数据结构

InfluxDB 中的数据结构主要分为以下几个层次：

```bash
tsdb.Store
    -- map[string]*tsdb.DatabaseIndex
        -- map[string]*tsdb.Measurement
        -- map[string]*tsdb.Series
    -- map[uint64]*tsdb.Shard
        -- Engine // 抽象接口，可插拔设计，目前是 tsm1 存储引擎
            -- tsm1.WAL
            -- tsm1.Cache
            -- tsm1.Compactor
            -- tsm1.FileStore
```

#### Store

```go
type Store struct {
    path string         // 数据库文件在磁盘上的存储路径

    // 数据库索引文件，key 为数据库名
    databaseIndexes map[string]*DatabaseIndex

    // 所有 shards 的索引，key 为其 shard ID
    shards map[uint64]*Shard
}
```

Store 是存储结构中最顶层的抽象结构体，主要包含了 InfluxDB 中所有数据库的 **索引** 和 **实际存储数据的 Shard 对象**。InfluxDB 中的其他服务都需要通过 Store 对象对底层数据进行操作。

#### Shard

```go
type Shard struct {
    index   *DatabaseIndex      // 所在数据库的索引对象
    path    string              // shard 在磁盘上的路径
    walPath string              // 对应的 wal 文件所在目录
    id      uint64              // shard ID，就是在磁盘上的文件名
    database        string      // 所在数据库名
    retentionPolicy string      // 对应存储策略名
    engine  Engine              // 存储引擎
}
```

每一个 Shard 对象都有一个单独的底层数据存储引擎，engine 负责和底层的文件数据打交道。Shard 还保存了一个指向所在数据库索引的指针，便于快速检索到该 Shard 中的元数据信息。

#### Engine

Engine 是一个抽象接口，对于 InfluxDB 来说，可以很方便地替换掉底层的存储引擎。

```go
type Engine interface {
    LoadMetadataIndex(shardID uint64, index *DatabaseIndex) error

    Backup(w io.Writer, basePath string, since time.Time) error
    Restore(r io.Reader, basePath string) error

    CreateIterator(opt influxql.IteratorOptions) (influxql.Iterator, error)
    WritePoints(points []models.Point) error
    ContainsSeries(keys []string) (map[string]bool, error)
    DeleteSeries(keys []string) error
    DeleteSeriesRange(keys []string, min, max int64) error
    DeleteMeasurement(name string, seriesKeys []string) error
    SeriesCount() (n int, err error)
    MeasurementFields(measurement string) *MeasurementFields
    CreateSnapshot() (string, error)
}
```

目前 tsm1 存储引擎中 Engine 的结构：

```go
type Engine struct {
    path      string
    index             *tsdb.DatabaseIndex                 // 数据库索引信息，目前没和存储引擎放在一起，看起来后续会更改设计作为存储引擎的一部分
    measurementFields map[string]*tsdb.MeasurementFields  // 所有 measurement 对应的 fields 对象
    WAL            *WAL                 // WAL 文件对象
    Cache          *Cache               // WAL 文件在内存中的缓存
    Compactor      *Compactor           // 压缩合并管理对象
    CompactionPlan CompactionPlanner
    FileStore      *FileStore           // 数据文件对象
    MaxPointsPerBlock int               // 每个 block 中最多存储的 Points 数量

    // Cache 超过指定大小后内容会被写入一个新的 TSM 文件
    CacheFlushMemorySizeThreshold uint64

    // Cache 超过多长时间后还没有数据写入，会将内容写入新的 TSM 文件
    CacheFlushWriteColdDuration time.Duration
}
```

Engine 负责维护和管理 **Cache, FileStore, WAL** 等对象。当用户进行插入或查询操作时，Engine 都会对这些对象进行相应的操作，而这些对上层用户和服务来说是透明的。

**从代码中的注释来看，在后续的版本中会把 tsdb.DatabaseIndex 移到 Engine 这一层，由存储引擎自己维护，降低代码的耦合程度。**

### 数据写入

`curl -i -XPOST 'http://localhost:8086/write?db=mydb' --data-binary 'cpu_usage,host=server01 value=0.64 1434055562000000000'`

#### 通过 httpd 插入数据

通常我们通过 HTTP 的接口写入一条或同时写入多条数据。在 InfluxDB 启动时会启动一个  httpd 服务，代码在 `services/httpd` 包中。

```go
func (h *Handler) serveWrite(w http.ResponseWriter, r *http.Request, user *meta.UserInfo) {
    ...
    err := h.PointsWriter.WritePoints(database, r.URL.Query().Get("rp"), consistency, points)
    ...
}
```

httpd 服务解析出要插入的所有 Points，以及数据库，存储策略等内容，之后调用 PointsWriter 的 WritePoints 方法插入数据。

#### PointsWriter

PointsWriter 的结构在 `coordinator` 包定义中，所有对数据的操作实际上都是通过这个对象来进行。

```go
func (w *PointsWriter) WritePoints(database, retentionPolicy string, consistencyLevel models.ConsistencyLevel, points []models.Point) error {
    ...
    // 将要写入的 Points 按照时间划分到要写入的 shard，返回一个 Point 和 shard 之间的映射关系
    shardMappings, err := w.MapShards(&WritePointsRequest{Database: database, RetentionPolicy: retentionPolicy, Points: points})
    ...
    
    // 每一个 shard 都有一个独立的协程负责写入，只要有一个出错，就立即返回错误信息
    ch := make(chan error, len(shardMappings.Points))
    for shardID, points := range shardMappings.Points {
        go func(shard *meta.ShardInfo, database, retentionPolicy string, points []models.Point) {
            ch <- w.writeToShard(shard, database, retentionPolicy, points)
        }(shardMappings.Shards[shardID], database, retentionPolicy, points)
    }
}
```

`WritePoints` 函数会**根据 Point 的时间戳判断出其属于哪一个 Shard**，之后调用 `writeToShard` 函数批量将 Points 分别写入到不同的 Shard 中。

`writeToShard` 函数中，实际上是调用了 `TSDBStore` 的 `WriteToShard`。这里的 `TSDBStore` 就是前文中提到的 `Store` 对象，是一个负责数据存储的顶层的抽象数据结构。而在 `Store` 对象中存储了所有 Shard 的管理对象，数据将会交由指定的 Shard 去处理。Shard 会继续调用底层 tsm1 引擎的 engine 对象来真正意义上的写入数据。代码如下：

```go
// PointsWirte.writeToShard -> TSDBStore.WriteToShard
func (w *PointsWriter) writeToShard(shard *meta.ShardInfo, database, retentionPolicy string, points []models.Point) error {
    ...
    err := w.TSDBStore.WriteToShard(shard.ID, points)
    ...
}

// TSDBStore.WriteToShard -> shard.WritePoints
func (s *Store) WriteToShard(shardID uint64, points []models.Point) error {
    ...
    sh, ok := s.shards[shardID]
    if !ok {
        return ErrShardNotFound
    }
    return sh.WritePoints(points)
}

// shard.WritePoints -> engine.WritePoints
func (s *Shard) WritePoints(points []models.Point) error {
    ...
    err := s.engine.WritePoints(points)
    ...
}
```

#### Engine 实际写入数据

从下面的代码中可以看出，写入操作实际上就是将 value 写入 Cache 和 WAL 中，Cache 中主要是一个 Map 的结构，根据 key 缓存不同时间戳的 value，而 WAL 文件中的数据就是内存中数据的一个持久化的存储文件。

```go
func (e *Engine) WritePoints(points []models.Point) error {
    values := map[string][]Value{}
    for _, p := range points {
        // 一条插入语句中一个 series 对应的多个 value 会被拆分出来，形成多条数据
        for k, v := range p.Fields() {
            // 这里的 key 是 seriesKey + 分隔符 + filedName
            key := string(p.Key()) + keyFieldSeparator + k
            values[key] = append(values[key], NewValue(p.Time().UnixNano(), v))
        }    
    }    
    e.mu.RLock()
    defer e.mu.RUnlock()

    // 向 cache 中写入 value 数据，如果超过了内存阀值上限，返回错误
    err := e.Cache.WriteMulti(values)
    if err != nil {
        return err
    }    

    // 将数据写入 wal 文件中
    _, err = e.WAL.WritePoints(values)
    return err
}
```

### 数据删除

InfluxDB 支持对数据的删除操作，和其他 LSM Tree 类似的数据库一样，都是采用了标记要删除的键的方式来进行操作，等到需要进行压缩合并时，再真正意义上地删除这些数据。

在 `data` 中和 tsm file 同一级的目录下，会存在一些以 `.tombstone` 文件，其中就记录了哪些 key 在哪一个时间段内的数据需要删除。

有两种情况需要用到这些文件，一种是在查询时，对于查询结果，需要和 `.tombstone` 文件中的内容进行比对，把不符合条件的 value 剔除。另外就是在 `Compactor` 进行压缩合并多个 tsm file 时，这些被删除的数据将不会被转存到新的 tsm file 中，从而达到删除数据，释放磁盘空间的目的。

### 数据查询与索引结构

由于 LSM Tree 的原理就是通过将大量的随机写转换为顺序写，从而极大地提升了数据写入的性能，与此同时牺牲了部分读的性能。TSM 存储引擎是基于 LSM Tree 开发的，所以情况类似。通常设计数据库时会采用索引文件的方式（例如 LevelDB 中的 Mainfest 文件） 或者 Bloom filter 来对 LSM Tree 这样的数据结构的读取操作进行优化。

**InfluxDB 中采用索引的方式进行优化，主要存在两种类型的索引。**

#### 元数据索引

一个数据库的元数据索引通过 **DatabaseIndex** 这个结构体来存储，在数据库启动时，会进行初始化，从所有 shard 下的 tsm file 中加载 index 数据，获取其中所有 **Measurement** 以及 **Series** 的信息并缓存到内存中。

```go
type DatabaseIndex struct {
    measurements map[string]*Measurement // 该数据库下所有 Measurement 对象
    series       map[string]*Series      // 所有 Series 对象，SeriesKey = measurement + tags
    name string // 数据库名
}
```

这个结构体中最主要存放的就是该数据下所有 `Measurement` 和 `Series` 的内容，其数据结构如下：

```go
type Measurement struct {
    Name       string `json:"name,omitempty"`
    fieldNames map[string]struct{}      // 此 measurement 中的所有 filedNames

    // 内存中的索引信息
    // id 以及其对应的 series 信息，主要是为了在 seriesByTagKeyValue 中存储Id节约内存
    seriesByID          map[uint64]*Series              // lookup table for series by their id

    // 根据 tagk 和 tagv 的双重索引，保存排好序的 SeriesID 数组
    // 这个 map 用于在查询操作时，可以根据 tags 来快速过滤出要查询的所有 SeriesID，之后根据 SeriesKey 以及时间范围从文件中读取相应内容
    seriesByTagKeyValue map[string]map[string]SeriesIDs // map from tag key to value to sorted set of series ids

    // 此 measurement 中所有 series 的 id，按照 id 排序
    seriesIDs           SeriesIDs                       // sorted list of series IDs in this measurement
}

type Series struct {
    Key         string              // series key
    Tags        map[string]string   // tags
    id          uint64              // id
    measurement *Measurement        // 所属 measurement
    // 在哪些 shard 中存在
    shardIDs    map[uint64]bool // shards that have this series defined
}
```

#### 元数据查询

InfluxDB 支持一些特殊的查询语句（支持正则表达式匹配），可以查询一些 measurement 以及 tags 相关的数据，例如

```bash
SHOW MEASUREMENTS
SHOW TAG KEYS FROM "measurement_name"
SHOW TAG VALUES FROM "measurement_name" WITH KEY = "tag_key"
```

例如我们需要查询 `cpu_usage` 这个 measurement 上传数据的机器有哪些，一个可能的查询语句为：

```bash
SHOW TAG VALUES FROM "cpu_usage" WITH KEY = "host"
```

1. 首先根据 measurement 可以在 `DatabaseIndex.measurements` 中拿到 `cpu_usage` 所对应的 `Measurement` 对象。
2. 通过 `Measurement.seriesByTagKeyValue` 获取 `tagk=host` 所对应的以 `tagv` 为键的 map 对象。
3. 遍历这个 map 对象，所有的 key 则为我们需要获取的数据。

#### 普通数据查询的定位

对于普通的数据查询语句，则可以通过上述的元数据索引快速定位到要查询的数据所包含的所有 **seriesKey，fieldName 和时间范围**。

举个例子，假设查询语句为获取 `server01` 这台机器上 `cpu_usage` 指标最近一小时的数据：

```bash
`SELECT value FROM "cpu_usage" WHERE host='server01' AND time > now() - 1h`
```

先根据 `measurement=cpu_usage` 从 `DatabaseIndex.measurements` 中获取到 `cpu_usage` 对应的 `Measurement` 对象。

之后通过 `DatabaseIndex.measurements["cpu_usage"].seriesByTagKeyValue["host"]["server01"]` 获取到所有匹配的 `series` 的 ID值，再通过 `Measurement.seriesByID` 这个 map 对象根据 `series ID` 获取它们的实际对象。

**注意这里虽然只指定了 `host=server01`，但不代表 `cpu_usage` 下只有这一个 `series`，可能还有其他的 tags 例如 `user=1` 以及 `user=2`，这样获取到的 `series ID` 实际上有两个，获取数据时需要获取所有 `series` 下的数据。**

在 `Series` 结构体中的 `shardIDs` 这个 map 变量存放了哪些 shard 中存在这个 series 的数据。而 `Measurement.fieldNames` 这个 map 可以帮助过滤掉 fieldName 不存在的情况。

至此，我们在 o(1) 的时间复杂度内，获取到了所有符合要求的 series key、这些 series key 所存在的 shardID，要查询数据的时间范围，之后我们就可以创建数据迭代器从不同的 shard 中获取每一个 series key 在指定时间范围内的数据。后续的查询则和 tsm file 中的 Index 的在内存中的缓存相关。

#### TSM File 索引

上一篇文章中讲过了对于 tsm file 中的 Index 部分会在内存中做间接索引，从而可以实现快速检索的目的。这里看一下具体的数据结构：

```go
type indirectIndex struct {
    b []byte                // 下层详细索引的字节流
    offsets []int32         // 偏移量数组，记录了一个 key 在 b 中的偏移量
    minKey, maxKey string   
    minTime, maxTime int64  // 此文件中的最小时间和最大时间，根据这个可以快速判断要查询的数据在此文件中是否存在，是否有必要读取这个文件
    tombstones map[string][]TimeRange   // 用于记录哪些 key 在指定范围内的数据是已经被删除的
}
```

`b` 直接对应着 tsm file 中的 Index 部分，通过对 offsets 进行二分查找，可以获取到指定 key 的所有 block 的索引信息，之后根据 offset 和 size 信息可以取出一个指定的 block 中的所有数据。

```go
type indexEntries struct {
    Type    byte 
    entries []IndexEntry
}

type IndexEntry struct {
    // 一个 block 中的 point 都在这个最小和最大的时间范围内
    MinTime, MaxTime int64

    // block 在 tsm 文件中偏移量
    Offset int64

    // block 的具体大小
    Size uint32
}
```

在上一节中说明了通过元数据索引可以获取到所有 **符合要求的 series key，它们对应的 shardID，时间范围**。通过 tsm file 索引，我们就可以根据 series key 和 时间范围快速定位到数据在 tsm file 中的位置。

#### 从 tsm file 中读取数据

InfluxDB 中的所有数据读取操作都通过 **Iterator** 来完成。

**Iterator** 是一个抽象概念，并且支持嵌套，一个 Iterator 可以从底层的其他 Iterator 中获取数据并进行处理，之后再将结果传递给上层的 Iterator。

这部分的代码逻辑比较复杂，这里不展开说明。实际上 **Iterator** 底层最主要的就是通过 `cursor` 来获取数据。

```go
type cursor interface {
    next() (t int64, v interface{})
}

type floatCursor interface {
    cursor
    nextFloat() (t int64, v float64)
}

// 底层主要是 KeyCursor，每次读取一个 block 的数据
type floatAscendingCursor struct {
    // 内存中的 value 对象
    cache struct {
        values Values
        pos    int
    }

    tsm struct {
        tdec      TimeDecoder   // 时间序列化对象
        vdec      FloatDecoder  // value 序列化对象
        buf       []FloatValue
        values    []FloatValue  // 从 tsm 文件中读取到的 FloatValue 的缓存
        pos       int
        keyCursor *KeyCursor
    }
}
```

**cursor** 提供了一个 `next()` 方法用于获取一个 value 值。每一种数据类型都有一个自己的 `cursor` 实现。

底层实现都是 **KeyCursor**，**KeyCursor** 会缓存每个 Block 的数据，通过 `Next()` 函数依次返回，当一个 Block 中的内容读完后再通过 `ReadBlock()` 函数读取下一个 Block 中的内容。

### 数据压缩与合并

主要涉及到两个结构体：

```go
type Compactor struct {
    Dir  string
    Size int
    FileStore interface {
        NextGeneration() int
    }
}

type CompactionPlanner interface {
    Plan(lastWrite time.Time) []CompactionGroup
    PlanLevel(level int) []CompactionGroup
    PlanOptimize() []CompactionGroup
}

// 默认的压缩合并计划
type DefaultPlanner struct {
    FileStore interface {
        Stats() []FileStat
        LastModified() time.Time
        BlockCount(path string, idx int) int
    }

    // 如果一个 shard 对应的 wal 文件超过指定时间一直没有数据写入
    // 存储引擎将会将此 shard 中的 tsm 文件进行一次全量压缩合并
    CompactFullWriteColdDuration time.Duration

    // 如果为 true，表示此 shard 中的 tsm 文件要么只有一个，要么已经处于单个文件最大值
    lastPlanCompactedFull bool

    // lastPlanCheck is the last time Plan was called
    lastPlanCheck time.Time
}
```

在 InfluxDB 创建一个 Shard 对应的底层的存储引擎时，会启用一些协程，每隔 1s 检查是否有需要压缩合并的任务，如果有就去执行相应的操作，部分代码如下：

```go
func (e *Engine) SetCompactionsEnabled(enabled bool) {
    if enabled {
        ...
        e.done = make(chan struct{})
        // 启用压缩合并功能
        e.Compactor.Open()

        // 启用另外的协程去定期检测是否需要进行压缩合并
        e.wg.Add(5)
        // 将 cache 中的内容刷新到磁盘上的新的 tsm 文件中
        go e.compactCache()
        // 下面是定期合并不同 level 的 tsm 文件
        go e.compactTSMFull()
        go e.compactTSMLevel(true, 1)
        go e.compactTSMLevel(true, 2)
        go e.compactTSMLevel(false, 3)
    }
    ...
}

func (e *Engine) compactCache() {
    defer e.wg.Done()
    // 每秒钟检查一次
    for {
        select {
        case <-e.done:
            return

        default:
            // 更新缓存据上一次快照时间的间隔时间
            e.Cache.UpdateAge()
            if e.ShouldCompactCache(e.WAL.LastWriteTime()) {
                start := time.Now()
                err := e.WriteSnapshot()
                ...
            }
        }
        time.Sleep(time.Second)
    }
}
```

`compactCache()` 函数负责定期检测 Cache 中的容量是否达到阀值，如果超过阀值会将 Cache 中的内容做一个快照，之后写入到一个新的 tsm file 中。

`compactTSMLevel()` 函数则负责对 tsm file 文件进行合并，每一个协程负责不同级别的文件，多个文件合并后，生成的新的文件级别会是旧文件中级别最高的那个文件加1。合并过程中，会在同一目录下创建以 `.tmp` 结尾的临时文件存储合并后的数据，当合并操作完成后，会进行替换操作，删除已经被合并完成的文件。`.tombstone` 文件在合并时也会被利用以过滤无效数据。

### 一些问题

#### Go 不支持泛型

由于 go 不支持泛型，所以 InfluxDB 中很多代码需要兼容各种类型，例如 float,int,string 等都是通过模版文件来 generate 源文件的方式来生成的。

这样导致代码可读性比较差，并且有大段大段的重复内容。如果使用 interface 的话，势必效率会下降很多。

对比一下 C++ 的 STL 库，go 在这方面的支持还不是很好，标准库里的 list, heap 等容器包还是用的 interface 的方式，自己要开发一个通用的算法或者容器时也不方便，还是希望之后能支持泛型这样的功能。

#### 多个 WAL 文件同时写入

由于每一个 shard 都有一个独立的 wal 文件，如果使用者创建了多个数据库、存储策略并且数据没有按照时间顺序插入，就会造成写入性能的下降。官方文档中有说之后会采用一个总的 WAL 文件来解决这个问题，不过可能会带来一些其他方面的问题。

#### 索引数据对内存的占用

InfluxDB 中对于所有 measument 以及 series 的元数据都是缓存在内存中，特别是 tsm file 的 Index 部分的数据，随着保留的数据越来越多，这部分的内存占用也会逐渐增加。

官方设计文档里也提到了一些方案缓解这类问题，例如采用 LRU 策略，或是采用和 OpenTSDB 中类似的对 key 进行压缩的方法。还有一个方案是将索引数据放到另外一个数据库例如 BoltDB 中进行存储。

综合来说，InfluxDB 在性能和资源占用等方面都表现得很优秀，1.0.0 版本的稳定性也很高，我在测试环境中使用的一个月中没有出现过异常状况。可能目前最重要的问题就是不支持集群，对数据量有要求的公司需要自己进行二次开发。
