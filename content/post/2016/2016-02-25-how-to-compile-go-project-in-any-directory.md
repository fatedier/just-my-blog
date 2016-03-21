---
categories:
    - "技术文章"
tags:
    - "golang"
date: 2016-02-25
title: "如何使golang项目可以在任意目录下编译"
url: "/2016/02/25/how-to-compile-go-project-in-any-directory"
---

通常我们将golang项目直接放在 $GOPATH/src 目录下，所有 import 的包的路径也是相对于 GOPATH 的。我在开发 frp（一个可以用于穿透内网的反向代理工具）的时候就遇到一个比较小但是挺棘手的问题，需要使这个项目可以在任意目录里被编译，方便其他成员不需要做额外的操作就可以一同开发，这里分享一下解决的方法。

<!--more-->

### 背景

[frp](https://github.com/fatedier/frp) 是我业余时间写的一个用于穿透内网的反向代理工具，可以将防火墙内或内网环境的机器对外暴露指定的服务，例如22端口提供ssh服务或者80端口提供一个临时的web测试环境。

一开始项目是直接放在 `$GOPATH/src` 目录下的，第三方包的引用是 `import github.com/xxx/xxx`，内部包的引用 `import frp/xxx`，这样编译时内部包的查找路径实际上就是 `$GOPATH/src/frp/xxx`。

后来由于使用了 [travis-ci](https://travis-ci.org/) 做持续集成，travis-ci 中是直接使用 `go get github.com/fatedier/frp` 下载代码，然后编译运行。这样问题就来了，通过 go get 下载的源码在本地的路径是 `$GOPATH/src/github.com/fatedier/frp`，内部包就找不到了，导致编译失败。

### 使用类似第三方包的引用方式

解决这个问题最直接的方法就是将内部包的引用方式修改成 `import github.com/fatedier/frp/xxx`，在 travis-ci 中编译的时候就可以通过了，同时需要注意把自己本地的项目路径也更换成`$GOPATH/src/github.com/fatedier/frp`，很多开源项目都是用的这种方式引用内部包。

**注：不推荐使用 ./ ../ 等相对路径来引用内部包，这样管理和定位问题其实都不是很方便。**

之后由于需要其他人共同开发，fork了我的项目之后，他们也使用 go get 下载他们fork后的项目源码，这样 `fatedier` 就替换成了他们自己的用户名，但是代码中 import 的包名并没有改变，会导致他们无法编译通过。当然，他们可以将项目再放到正确的目录，但是多了一部操作总归不方便。

### 比较tricky的做法，修改GOPATH

其实问题的关键就在于 `GOPATH` 这个环境变量，这个变量决定了查找包的绝对路径。我们在项目根目录下建立 `src/frp` 这样的目录结构，之后将原来的源代码放到这个目录下，然后内部包的应用方式还是改成 `import frp/xxx` 这种简洁的格式。

编译的时候，把项目根目录加到 `GOPATH` 中去，例如 `GOPATH=\`pwd\`:${GOPATH}`，这样就会在自己的目录里查找内部包。

可以看到，通过这样的方式不管把你把项目放到哪一个目录下，都可以编译成功，当然，为了便于管理，推荐还是放在 `$GOPATH/src` 目录下，同时使用 [godep](https://github.com/tools/godep) 来管理第三方包。
