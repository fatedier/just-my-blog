---
categories:
    - "技术文章"
tags:
    - "golang"
date: 2016-08-01
title: "golang 中使用 statik 将静态资源编译进二进制文件中"
url: "/2016/08/01/compile-assets-into-binary-file-with-statik-in-golang"
---

现在的很多程序都会提供一个 Dashboard 类似的页面用于查看程序状态并进行一些管理的功能，通常都不会很复杂，但是其中用到的图片和网页的一些静态资源，如果需要用户额外存放在一个目录，也不是很方便，如果能打包进程序发布的二进制文件中，用户下载以后可以直接使用，就方便很多。

<!--more-->

最近在阅读 InfluxDB 的源码，发现里面提供了一个 admin 管理的页面，可以通过浏览器来执行一些命令以及查看程序运行的信息。但是我运行的时候只运行了一个 influxd 的二进制文件，并没有看到 css, html 等文件。

原来 InfluxDB 中使用了 statik 这个工具将静态资源都编译进了二进制文件中，这样用户只需要运行这个程序即可，而不需要管静态资源文件存放的位置。

### 安装

先下载并安装 statik 这个工具

`go get -d github.com/rakyll/statik`

`go install github.com/rakyll/statik`

注意将 `$GOPATH/bin` 加入到 PATH 环境变量中。

### 创建测试项目

创建一个测试用的 golang 项目，这里假设目录为 `$GOPATH/src/test/testStatikFS`。

创建一个 assets 目录用于放静态资源文件。包括 `./assets/a` 和 `./assets/tmp/b` 两个文件，文件内容分别为 `aaa` 和 `bbb`。

创建 main.go 文件，代码如下：

```go
//go:generate statik -src=./assets
//go:generate go fmt statik/statik.go

package main

import (
    "fmt"
    "io/ioutil"
    "os"

    _ "test/testStatikFS/statik"
    "github.com/rakyll/statik/fs"
)

// Before buildling, run go generate.
func main() {
    statikFS, err := fs.New()
    if err != nil {
        fmt.Printf("err: %v\n", err)
        os.Exit(1)
    }   

    file, err := statikFS.Open("/tmp/b")
    if err != nil {
        fmt.Printf("err: %v\n", err)
        os.Exit(1)
    }   
    content, err := ioutil.ReadAll(file)
    if err != nil { 
        fmt.Printf("err: %v\n", err)
        os.Exit(1)
    }   
    fmt.Printf("content: %s\n", content)
}
```

注意文件最开始的两行

```go
//go:generate statik -src=./assets
//go:generate go fmt statik/statik.go
```

这个注释是告诉 `go generate` 需要执行的命令，之后就可以通过 `go generate` 生成我们需要的 go 文件。

这段代码的功能就是从 **statikFS** 提供的文件系统接口中获取 `/tmp/b` 这个文件的内容并输出，可以看到操作起来和操作普通文件的方法基本一致。

### 将静态资源打包成 go 文件

执行 `go generate`。

在项目目录下执行这个命令会生成一个 **statik** 目录，里面存放的是自动生成的 go 文件，将所有 `./assets` 下的文件变成了一个压缩后的字符串放在了这个文件中，并且在程序启动时会解析这个字符串，构造一个 **http.FileSystem** 对象，之后就可以使用对文件系统类似的操作来获取文件内容。

### 编译

`go build -o test ./main.go`

在 main.go 中我们 import 了两个包

```go
_ "test/testStatikFS/statik"
"github.com/rakyll/statik/fs"
```

第一个就是 `go generate` 自动生成的目录，其中只有一个 `init()` 函数，初始化相关的资源，我们不需要调用这个包里面的函数，只执行 `init()` 函数，所以在包名前加上 `_`。

### 运行

运行编译后的文件： `./test`。

输出了文件 `./assets/tmp/b` 中的内容：

```bash
content: bbb
```

### 文件系统接口

由于 statik 实现了标准库中的 http.FileSystem 接口，所以也可以直接使用 http 包提供静态资源的访问服务，关键部分代码如下：

```go
import (
  "github.com/rakyll/statik/fs"

    _ "./statik" // TODO: Replace with the absolute import path
)

// ...

statikFS, _ := fs.New()
http.ListenAndServe(":8080", http.FileServer(statikFS))
```
