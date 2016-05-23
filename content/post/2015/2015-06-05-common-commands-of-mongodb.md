---
categories:
    - "技术文章"
tags:
    - "mongodb"
date: 2015-06-05
title: "MongoDB常用命令"
url: "/2015/06/05/common-commands-of-mongodb"
---

MongoDB 是一个基于分布式文件存储的数据库，由C++编写，介于关系数据库和非关系数据库之间的产品，所以在很多业务上可以取代 mysql，提供更高的性能以及更好的扩展性。虽然 MongoDB 不支持 sql 语法，但是从常用的操作命令上来说和 sql 的用法相类似。

<!--more-->

#### 查询有哪些数据库

`show dbs`

#### 切换数据库

`use <db_name>`

如果数据库不存在，则创建数据库，否则切换到指定数据库。但是只有在数据库中插入数据，才会在查询数据库列表时显示。

#### 查询当前数据库的所有集合

`db.getCollectionNames()`

#### 查看指定集合的状态信息

`db.<collection_name>.stats()`

```json
{
    "ns" : "<db_name>.<collection_name>",
    "count" : 1,
    "size" : 4080,
    "avgObjSize" : 4080,
    "numExtents" : 1,
    "storageSize" : 8192,
    "lastExtentSize" : 8192,
    "paddingFactor" : 1,
    "paddingFactorNote" : "paddingFactor is unused and unmaintained in 3.0. It remains hard coded to 1.0 for compatibility only.",
    "userFlags" : 1,
    "capped" : false,
    "nindexes" : 1,
    "totalIndexSize" : 8176,
    "indexSizes" : {
        "_id_" : 8176
    },
    "ok" : 1
}
```

#### 查看当前数据库中的所有的索引

`db.system.indexes.find()`

#### 查看指定集合中的索引

`db.col.getIndexes()`

#### 创建指定集合中的索引

`db.col.ensureIndex({"name": 1, "age": -1})`

根据 name 和 age 进行索引，1表示升序，-1表示降序。

#### 查看集合中的文档

##### 查询所有文档

`db.col.find()`

##### 以易读的方式显示文档内容

`db.col.find().pretty()`

##### 查询前10个文档

`db.col.find().limit(10)`

##### 查询结果排序展示

`db.col.find().sort({'clock':-1})`

查询结果按照 clock 排序展示，1 为升序，-1 为降序。

##### where 条件

| 操作 | 范例 | RDBMS中的类似语句 |
| :--- | :---- | :---- |
| 等于 | db.col.find({"key":"value"}).pretty() | where key = 'value' |
| 小于 | db.col.find({"key":{$lt:50}}).pretty() | where key < 50 |
| 小于等于 | db.col.find({"key":{$lte:50}}).pretty() | where key <= 50 |
| 大于 | db.col.find({"key":{$gt:50}}).pretty() | where key > 50 |
| 大于或等于 | db.col.find({"key":{$gte:50}}).pretty() | where key >= 50 |
| 不等于 | db.col.find({"key":{$ne:50}}).pretty() | where key != 50 |

##### and 条件

find() 方法可以传入多个键，每个键以逗号隔开。

`db.col.find({key1:value1, key2:value2}).pretty()`

##### or 条件

```json
db.col.find(
    {
        $or: [
            {key1: value1}, {key2:value2}
        ]
    }
).pretty()
```

例如 `db.col.find({$or:[{"key1":"value1"}, {"key2": "value2"}]}).pretty()`

##### 更新操作

`db.collection.update( query, update, upsert, multi )`

**query**： update 的查询条件，类似 sql update 操作的 where 子句。

**update**： update 的对象和一些更新的操作符（如$set, $inc...）等，也可以理解为 sql update 操作的 set 子句。

**upsert**： 可选，这个参数的意思是，如果不存在 update 的记录，是否插入新的记录，true 为插入，默认是 false，不插入。

**multi**： 可选，默认为 false，只更新找到的第一条记录，如果这个参数为 true，就把按条件查出来多条记录全部更新。

`db.agent_conf.update({hostid:137}, {$set: {upload:{interval:10}}}, true)`

将 agent_conf 集合中 hostid = 137 的记录将 upload.interval 的值修改为 3，如果不存在就插入，只修改匹配的第一条。

#### 删除操作

`db.col.remove({id:1})`

remove 的过滤条件同 find。
