---
categories:
    - "技术文章"
tags:
    - "开发技巧"
date: 2015-12-06
title: "gem 源被屏蔽的解决方法"
url: "/2015/12/06/the-solution-when-gem-source-is-shielded"
---

由于国内的网络环境比较特殊，使用 gem install 安装 ruby 包的时候，往往不能成功，我们可以手动替换成阿里提供的镜像源来进行下载。

<!--more-->

官方原先的源地址是 https://rubygems.org/

可以使用 `gem sources` 命令来查看源地址。

```bash
*** CURRENT SOURCES ***

https://rubygems.org/
```

通过 `gem sources --add https://ruby.taobao.org/ --remove https://rubygems.org/` 替换成阿里的源。

再次查看源地址列表。

```bash
*** CURRENT SOURCES ***

https://ruby.taobao.org/
```

之后就可以使用 `gem install xxx -V` 安装第三方包或应用并且显示详细过程。
