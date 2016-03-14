---
categories:
    - "技术文章"
tags:
    - "golang"
    - "开发工具"
date: 2016-01-15
title: "使用godep管理golang项目的第三方包"
url: "/2016/01/15/use-godep-to-manage-third-party-packages-of-golang-projects"
---

go语言项目的第三方包资源现在十分丰富，使用起来也非常方便，直接在代码中 import 之后再使用 go get 命令下载到本地即可。但是在合作开发一个golang项目时，经常会遇到每个人在各自的机器上使用 go get 下载的第三方包版本不一致的情况（因为 go get 会下载指定包的最新版本），很有可能会遇到版本不兼容的情况。

<!--more-->

目前 go 自身的包管理体系比较薄弱，go 1.5 以后开始使用 vendor 机制来管理，但是依然缺乏对第三方包的版本的管理。

### 安装

1. 确保已经有go语言的环境并且设置好了 GOPATH 环境变量。
2. 使用 `go get -u github.com/tools/godep` 下载 godep 包并自动安装。
3. godep 可执行程序会放在 $GOPATH/bin 目录下。所以想直接用 godep 执行命令的话需要将该路径加入到全局的环境变量 PATH 中，可以将`export PATH="$PATH:$GOPATH/bin"`加入到系统启动脚本中。

### 使用

进入go项目的根目录，需要该项目已经可以使用 go build 正常编译。

#### godep save

执行 `godep save` 或者 `godep save ./...`，后者会递归地查找所有引用的第三方包。

如果加上 -r 参数，则会替换原来代码中的第三包的路径为 godep 在该项目下copy过后的路径，例如 `C/Godeps/_workspace/src/D`， 这样一来，以后直接执行 `go build` 等就可以了，不需要使用 `godep go build`。**（这个特性在最新版本中已经被移除了）**

这个命令做了以下几件事：

* 查找项目中所用到的所有的第三方包
* 在项目目录下创建 `Godeps` 目录，`Godeps/Godeps.json` 是依赖文件，包括了go的版本，用到的第三包的引入路径，版本号等信息，json文件需要一并加入到版本控制里。
* 所有依赖的第三包的代码会被拷贝到 `Godeps/_workspace/src` 下，并且移除了 `.git` 这样的版本控制信息。`Godeps/_workspace` 里的内容如果加到版本控制里，别人下载代码后可以直接编译，不需要另外再下依赖包，但是项目大小会变大。

#### godep restore

这个命令是根据 `Godeps/Godeps.json` 文件把项目的依赖包下载到 `$GOPATH` 目录下，需要注意这个命令是会修改 `$GOPATH` 下依赖包的状态的，所以最好还是将 `Godeps/_workspace` 里的内容直接加到自己项目的版本控制里。

#### 其他命令

其他的 go 命令基本上都可以通过 godep 执行，例如

```bash
godep go build
godep go install
godep go fmt
```
godep 封装的 go 命令其实就是将 Godeps/_workspace 加入到 GOPATH 中，这样编译的时候就会去 Godeps/_workspace 中寻找第三方包。
