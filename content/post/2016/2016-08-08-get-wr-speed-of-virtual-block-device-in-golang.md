---
categories:
    - "技术文章"
tags:
    - "golang"
    - "linux"
date: 2016-08-08
title: "go 程序中获取虚拟块设备的读写速度"
url: "/2016/08/08/get-wr-speed-of-virtual-block-device-in-golang"
---

最近在写程序时需要在 centos5 系统上获取 device mapper 中的虚拟块设备的读写信息。在这个过程中发现由于
go 跨平台的特性，有一些 api 是无法拿到特定平台上的一些特殊信息的，或者是需要一些小技巧来实现。

<!--more-->

### 获取磁盘读写速度

正常情况下 linux 上通过 `/proc/diskstats` 这个文件来获取磁盘设备的读写信息，这个文件的内容可以通过 `cat /proc/diskstats` 获取，如下：

```bash
   1    0 ram0 0 0 0 0 0 0 0 0 0 0 0
   1    1 ram1 0 0 0 0 0 0 0 0 0 0 0
   1    2 ram2 0 0 0 0 0 0 0 0 0 0 0
   1    3 ram3 0 0 0 0 0 0 0 0 0 0 0
   1    4 ram4 0 0 0 0 0 0 0 0 0 0 0
   1    5 ram5 0 0 0 0 0 0 0 0 0 0 0
   1    6 ram6 0 0 0 0 0 0 0 0 0 0 0
   1    7 ram7 0 0 0 0 0 0 0 0 0 0 0
   1    8 ram8 0 0 0 0 0 0 0 0 0 0 0
   1    9 ram9 0 0 0 0 0 0 0 0 0 0 0
   1   10 ram10 0 0 0 0 0 0 0 0 0 0 0
   1   11 ram11 0 0 0 0 0 0 0 0 0 0 0
   1   12 ram12 0 0 0 0 0 0 0 0 0 0 0
   1   13 ram13 0 0 0 0 0 0 0 0 0 0 0
   1   14 ram14 0 0 0 0 0 0 0 0 0 0 0
   1   15 ram15 0 0 0 0 0 0 0 0 0 0 0
   8    0 sda 29130 11247 905939 500914 155932 727767 7071070 2191673 0 552400 2692588
   8    1 sda1 84 1040 2264 450 31 12 86 382 0 809 832
   8    2 sda2 29026 10190 903379 500111 155901 727755 7070984 2191291 0 551590 2691403
 253    0 dm-0 38942 0 902058 758838 883873 0 7070984 30357342 0 551667 31116195
 253    1 dm-1 142 0 1136 502 0 0 0 0 0 84 502
  22    0 hdc 0 0 0 0 0 0 0 0 0 0 0
   2    0 fd0 0 0 0 0 0 0 0 0 0 0 0
   9    0 md0 0 0 0 0 0 0 0 0 0 0 0
```

第一列和第二列是设备号，第三列是设备名称，第六列是读取的 sectors 数，第十列是写入的 sectors 数。

和计算 cpu 使用率类似，我们需要读取两次该文件，将两次读取到的值相减以后除以间隔时间来计算读写速度。

### 虚拟块设备的区别

通过 `df -h` 可以看到其中 `/dev/mapper/VolGroup00-LogVol00` 就是一个虚拟块设备：

```bash
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/VolGroup00-LogVol00
                       18G  1.9G   15G  12% /
/dev/sda1              99M   13M   81M  14% /boot
tmpfs                 499M     0  499M   0% /dev/shm
```

但是获取读写信息时拿到的对应设备名并不是这个，实际上应该是 `dm-0`。

所以我们需要通过设备号来获取他们的对应关系。

#### 获取设备号

在 centos5 上比较特殊，没法使用 `lsblk` 获取设备号，所以需要用其他的方法。

```bash
ls -lh /dev/mapper/

total 0
crw------- 1 root root  10, 60 Jul 11 22:18 control
brw-rw---- 1 root disk 253,  0 Jul 11 22:19 VolGroup00-LogVol00
brw-rw---- 1 root disk 253,  1 Jul 11 22:18 VolGroup00-LogVol01
```

可以看出 `VolGroup00-LogVol00` 的设备号为 `253,0`，既然 `ls -lh` 可以显示设备号信息，说明这个信息是可以通过 `stat` 获取到的。

#### go 中获取文件信息

go 中文件的信息接口如下：

```go
type FileInfo interface {
    Name() string           // 文件的名字（不含扩展名）
    Size() int64            // 普通文件返回值表示其大小；其他文件的返回值含义各系统不同
    Mode() FileMode         // 文件的模式位
    ModTime() time.Time     // 文件的修改时间
    IsDir() bool            // 等价于
    Mode().IsDir()Sys() interface{} // 底层数据来源（可以返回nil）
}
```

由于 go 语言需要考虑跨平台的特性，正常情况下只能拿到这些通用的信息。而如果要在 linux 下获取设备号，关键就在于那个 `Sys()` 函数所返回的 `Interface{}`。

在 linux 平台上，其对应的是一个 `Stat_t` 结构体：

```go
type Stat_t struct {
    Dev       uint64
    X__pad1   uint16
    Pad_cgo_0 [2]byte
    X__st_ino uint32
    Mode      uint32
    Nlink     uint32
    Uid       uint32
    Gid       uint32
    Rdev      uint64
    X__pad2   uint16
    Pad_cgo_1 [2]byte
    Size      int64
    Blksize   int32
    Blocks    int64
    Atim      Timespec
    Mtim      Timespec
    Ctim      Timespec
    Ino       uint64
}
```

**需要注意这个结构体在不同平台上的定义是不同的。**

其中的 `Rdev` 就是设备号的值，例如查看上文中的设备文件设备号返回结果是 `64768`，转换成 `ls -lh` 中显示的格式就是 `253,0`，转换成 16 进制是 `FD00`。

下面是示例代码片段，需要注意的是这段代码可能并不能在除 linux 之外的其他平台运行。

```go
dev, err := os.Stat("/dev/mapper/VolGroup00-LogVol00")
if err != nil {
    os.Exit(1)
}
sys, ok := dev.Sys().(*syscall.Stat_t)
if !ok {
    os.Exit(1)
}
major := sys.Rdev / 256
minor := sys.Rdev % 256
devNumStr := fmt.Sprintf("%d:%d", major, minor)
fmt.Printf("get dev mapper [%s] [%s]", dev.Name, devNumStr)
```
