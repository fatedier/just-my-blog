---
categories:
    - "技术文章"
tags:
    - "linux"
    - "开发工具"
date: 2014-11-10
title: "使用astyle进行代码格式化"
url: "/2014/11/10/use-astyle-to-format-code"
---

在参与团队的开发的时候，由于平台和编写代码的工具的不同等等问题，经常会遇到代码格式非常混乱的情况，严重影响了代码的阅读效率。后来发现了一款比较好的工具 -- "astyle"。

<!--more-->

astyle这个工具可以将现有的代码格式转换为指定的风格，当你将乱七八糟的代码用astyle转换一下之后，就会感觉整个世界都清静了……

### 如何获取

astyle是一个开放源码的项目，支持C/C++、C#和java的代码格式化

SourceForge地址: [http://sourceforge.net/projects/astyle/](http://sourceforge.net/projects/astyle/)

我的Github拷贝: [https://github.com/fatedier/fatedier-tools/tree/master/astyle](https://github.com/fatedier/fatedier-tools/tree/master/astyle)

### 编译

直接写一个Makefile编译下源码，我的Github的拷贝里有写好的Makefile，直接用gmake命令编译一下就可以用了。

### 示例

```bash
./astyle --style=ansi test.cpp
```

执行之后会提示

```bash
Formatted  xxx/test.cpp
```

**astyle** 会在当前目录下生成一个备份文件，以 **.orig** 结尾，例如 "test.cpp.orig"。

 而 **test.cpp** 就已经转换为了 **ansi** 代码风格了。

###  常用选项

**注：使用 --help 选项可以查看astyle的帮助文档**

#### style风格设置

常用的代码风格主要有三种: **ansi** 和 **k&r** 以及 **java**

1. --style=allman  OR --style=ansi OR --style=bsd OR --style=break OR -A1

    ```cpp
    int Foo()
    {
       if (isBar)
        {
           bar();
           return 1;
        }
       else
        {
           return 0;
        }
    }
    ```

2. --style=kr OR --style=k&r OR --style=k/r OR -A3

    ```cpp
    int Foo()
    {
       if (isBar) {
           bar();
           return 1;
        }else {
           return 0;
        }
    }
    ```

3. --style=java OR --style=attach OR -A2

    ```cpp
    int Foo() {
       if (isBar) {
           bar();
           return 1;
        }else {
           return 0;
        }
    }
    ```

#### Tab选项

默认是使用4个空格替换一个tab。

1. --indent=spaces=# OR -s#

    指定用几个空格替换一个tab，例如 --indent=spaces=8 ，指定用8个空格替换一个tab。

2. --indent=tab OR --indent=tab=# OR -t OR -t#

    指定缩进使用tab，=#同上，指定一个tab占几个空格，不说明的话默认是4个。

#### 递归处理

--recursive OR -r OR -R

可以递归处理所有子目录的文件。

#### 排除不处理的文件

--exclude=####

指定哪些文件或者文件夹不需要进行处理。

#### 指定配置文件

--options=####

可以指定读取某个文件的内容作为参数选项。
