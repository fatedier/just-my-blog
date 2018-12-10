---
categories:
    - "技术文章"
tags:
    - "golang"
date: 2017-01-01
title: "golang 交叉编译"
url: "/2017/01/01/golang-cross-compile"
---

golang 相比 c/c++ 的优势之一是更容易编写出跨平台的应用，而不需要为各个平台编写适配代码。和 JAVA 相比，对系统环境要求较低，不需要预先安装 JDK 等适配环境。

<!--more-->

### go build

这里以 [frp](https://github.com/fatedier/frp) 项目的跨平台编译脚本作为示例

编译 linux/amd64 版本的应用：

`CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o frpc_linux_amd64 ./cmd/frpc`

编译 windows/amd64 版本的应用：

`CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags "-s -w" -o ./frpc_windows_amd64.exe ./cmd/frpc`

在 linux 上编译出 windows 的 exe 文件后，可以直接拷贝到 windows 机器上运行。

**GOOS** 表明目标平台的操作系统。
**GOARCH** 表明目标平台的架构，通常 386 表示 32位系统，amd64 表示 64位系统。
可以通过 `go tool dist list` 查看支持的操作系统和对应的平台。

**-s -w** 是为了去掉编译时的符号信息和调试信息，缩小编译出的程序文件大小，非必需。
**CGO_ENABLED=0** 可以禁用 cgo 编译，跨平台兼容性会更好。

### 限定代码只在某个特定平台上编译

有时候我们仍然希望为不同平台的应用编写特殊的代码，通过给 Go 文件加上 `// +build` 注释可以实现。

例如 Go 文件开头存在如下注释

`// +build linux,386 darwin,!cgo`

说明该文件仅在 linux/386 或者 darwin(No cgo) 的环境下被编译。
在其他环境下该文件不会被编译。

通过这个方法，我们可以为不同平台编写同一份代码的不同实现。

### 额外注意事项

* 推荐在 linux/amd64 上进行交叉编译，其他平台可能会出现一些意外情况，具体不明确。
* 使用 cgo 时交叉编译可能失败，编写跨平台应用最好禁用 cgo。
