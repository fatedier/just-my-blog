---
categories:
    - "技术文章"
tags:
    - "git"
    - "开发工具"
date: 2014-10-17
title: "Git常用命令"
url: "/2014/10/17/git-usually-command"
---

在用Git进行项目管理的时候有一些经常会遇到的问题处理起来比较复杂，本文记录了一些常用的命令和操作。

<!--more-->

### 修改某一次提交的说明信息

有时候我们需要修改之前提交的时候的说明信息，没有操作命令可以直接完成，但是使用rebase命令可以实现。

例如我们要修改倒数第二次的提交的说明信息：

```bash
$ git rebase -i HEAD~3
```

**注意：这里HEAD~后面跟着的是3而不是2，因为这里指的是要修改的提交的父提交。**

之后会进入到文本编辑界面，如下图

![reset-commit-message](/pic/2014/2014-10-17-git-usually-command-git-reset-commit-message.jpg)

将要修改的提交前面的 **pick** 改为 **edit** ，保存后退出。

这个时候执行

```bash
$ git commit --amend
```

就可以修改该次提交的说明了，修改完成后保存并退出。

```bash
$ git rebase --continue
```

执行这条命令后，后续的提交说明将不会改变。

**注：不要修改已经push到远程仓库的提交！！！会引起版本混乱，使提交历史变的不清晰！**


### 合并多个提交

比如要合并最后两次的提交，其实和修改某一次提交的说明信息有点类似。

```bash
$ git rebase -i HEAD~2
```

之后同样会进入到文本编辑界面，将第二行开头的 **pick** 改为 **squash** 或 **s**，保存后退出。

这时git会把两次提交合并，并且提示让你输入新的提交信息，保存后退出就成功完成两次提交的合并了。


### 强制回退远程仓库到指定提交

当我们在开发的时候出现一些关键性的错误，并且确认现在已经做的开发工作是无意义的时候，可能需要回退到之前的版本。

```bash
$ git reset --hard <commit_id>

$ git push origin HEAD --force
```

另外，reset命令还有几个可选参数

* **git reset --mixed**：此为默认方式，不带任何参数的git reset，即时这种方式，它回退到某个版本，只保留源码，回退commit和index信息。

* **git reset --soft**：回退到某个版本，只回退了commit的信息，不会恢复到indexfile一级。如果还要提交，直接commit即可。

* **git reset --hard**：彻底回退到某个版本，本地的源码也会变为上一个版本的内容。


### reset --hard之后的恢复

使用 `git reset --hard` 之后，也许才发现这是一次错误的操作，那么我们就想要恢复到之前的版本。

这个时候用git log是看不到之前的提交历史记录的。

需要使用 `$ git reflog` 找到我们需要恢复的HEAD的ID，然后使用reset命令恢复回去。


### 查看指定版本的某个文件的内容

例如要查看 f4869b0 这次提交的 test.cpp 文件的内容，test.cpp的路径需要使用相对于git目录的路径名，使用如下命令：

```bash
$ git show f4869b0:test.cpp
```

文件的内容会全部显示在界面上，可以使用文件重定向到另外的文件，再进行后续操作。
