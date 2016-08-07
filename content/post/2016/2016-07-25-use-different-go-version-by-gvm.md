---
categories:
    - "技术文章"
tags:
    - "golang"
    - "开发工具"
date: 2016-07-25
title: "使用gvm在不同go版本之间切换"
url: "/2016/07/25/use-different-go-version-by-gvm"
---

Centos7上通过 yum 从 epel 仓库里直接安装的 go 版本还是 1.4.2，从源码编译安装最新的 go 版本比较麻烦，而且开发中有时需要调试在不同编译环境下可能存在的问题，不能忽略使用最新版本是存在某些 bug 的可能性。

<!--more-->

Go 的更新速度比较快，2015年8月发布 1.5 版本，2016年2月发布 1.6 版本，2016年8月即将发布 1.7 版本，在性能以及GC方便都在不断优化，及时更新到新版本的 go 很有优势。

### Go 版本切换的问题

二进制文件的管理比较简单，通过链接使用不同版本的程序即可，实际上主要是一些环境变量和标准库的设置问题，环境变量主要是 `GOPATH` 以及 `GOROOT`，标准库的话需要在切换 go 版本时也能跟着切换。**gvm** 实际上就是帮助完成这些配置工作。

### 安装 gvm

**gvm** 的项目地址：https://github.com/moovweb/gvm

安装命令：

`bash << (curl -s -S -L https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer)`

如果你使用的是 `zsh` 的话将前面的 `bash` 改为 `zsh` 即可，这条命令主要是下载 **gvm** 相关的文件，创建所需目录，并且在 `.bashrc` 或者 `.zshrc` 中加入

`[[ -s "/home/wcl/.gvm/scripts/gvm" ]] && source "/home/wcl/.gvm/scripts/gvm"`

使每次登录 shell 时都可以生效。

### 安装指定 go 版本

`gvm install go1.6.3`

需要注意这里实际上是先执行

`git clone https://go.googlesource.com/go $GVM_ROOT/archive/go`

这个网站在墙外。

我们可以通过配置使 git 可以通过 http 代理访问，修改 `.gitconfig` 文件，加上 http 代理服务器的地址：

```
[http]
        proxy = http://[proxydomain]:[port]
```

下载成功后，有可能提示编译失败，因为 go1.6.3 需要依赖于 go1.4 来编译，需要设置 `GOROOT_BOOTSTRAP` 变量。

通过 `go env` 查看 `GOROOT` 的路径，通常 `GOROOT_BOOTSTRAP` 就设置成 `GOROOT`，centos7 下需要注意 /usr/lib/golang/bin 下并没有 `go` 的二进制文件，通过 cp 命令复制一个过去。

之后再次执行 `gvm install go1.6.3` 即可安装完成。

### 修改配置信息方便使用

最初测试时发现每次切换 go 版本后都会被修改 `GOPATH` 变量，而实际上我并不需要这个功能，只是希望用新版本来编译已有的项目，所以我们需要把 `~/.gvm/environments` 文件夹下所有 `GOPATH` 的设置全部删除。

另外还需要将 `~/.zshrc` 或者 `~/.bashrc` 中的

`[[ -s "~/.gvm/scripts/gvm" ]] && source "~/.gvm/scripts/gvm"`

移到设置 `GOPATH` 变量之前，避免登录 shell 之后被修改 `GOPATH` 变量。

### 使用

#### 切换到安装好的指定 go 版本

`gvm use go1.6.3`

通过 `go version` 可以看到已经是新版本的二进制文件，通过 `go env` 可以查看 `GOROOT` 信息，例如我的就是 `~/.gvm/gos/go1.6.3`，这样编译项目时就会在这个目录下找标准库中的文件。

#### 切换到原来的系统版本

`gvm use system`

#### 查看当前已经安装的所有版本

`gvm list`

```bash
gvm gos (installed)

=> go1.6.3
   system
```

#### 设置某个版本为默认

`gvm use go1.6.3 --default`

这样设置后，再登录 shell 就默认使用 `go1.6.3` 的版本，而不是系统原来的版本了。
