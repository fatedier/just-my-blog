---
categories:
    - "技术文章"
tags:
    - "golang"
date: 2017-02-04
title: "减小 golang 编译出程序的体积"
url: "/2017/02/04/reduce-golang-program-size"
---

Go 语言的优势是可以很方便地编译出跨平台的应用程序，而不需要为每一个平台做代码适配，也不像 JAVA 一样需要预先安装 JDK 环境。相应的问题就是 go 编译出的程序体积较大，和 c/c++ 不同，它将大多数依赖都以静态编译的方式编译进了程序中。

<!--more-->

### -ldflags

`go build` 编译程序时可以通过 `-ldflags` 来指定编译参数。

**-s** 的作用是去掉符号信息。
**-w** 的作用是去掉调试信息。

测试加与不加 `-ldflags` 编译出的应用大小。

```
go build -o tmp/frpc ./cmd/frpc
-rwxr-xr-x  1 fate  staff  12056092 Dec 10 15:49 frpc

go build -ldflags "-s -w" -o tmp/frpc2 ./cmd/frpc
-rwxr-xr-x  1 fate  staff   8353308 Dec 10 15:49 frpc2
```

减小了接近 4MB 的体积。

### UPX 压缩

在某些设备上动辄接近 10MB 的程序大小还是比较大的，这个时候可以采用 UPX 来进一步压缩。好处是占用磁盘空间小了，坏处是程序启动时会先进行一æ­¥解压缩，将代码还原到内存中，也就是说占用的内存大小并不会减少，当然，对于现代设备来说，启动的耗时几乎可以忽略。

通过各系统的包管理工具一般可以自动安装 UPX。
例如 Centos 上 epel 库 `yum install -y upx`。
macos 上通过 brew 安装 `brew install upx`。

压缩命令
`upx -9 -o ./frpc2_upx ./frpc2`

**-o** 指定压缩后的文件名。
**-9** 指定压缩级别，1-9。

压缩后的文件体积
```
-rwxr-xr-x  1 fate  staff   2998928 Dec 10 15:49 frpc2_upx
```

可以看到缩小了接近 5MB，效果显著。

需要注意的是，UPX 可能并不能正确的压缩所有平台的程序，压缩完成后最好自行在对应平台运行测试一下。
