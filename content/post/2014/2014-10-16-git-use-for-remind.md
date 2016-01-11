---
categories:
    - "技术文章"
tags:
    - "git"
    - "开发工具"
date: 2014-10-16
title: "Git使用备忘"
url: "/2014/10/16/git-use-for-remind"
---

Git是一款免费、开源的分布式版本控制系统，由于 GitHub 的存在，我们很方便的用于管理我们平时的开发项目。

Git的命令较多，虽然大多数都不是很常用，但是还是需要记下来方便日后查看。

<!--more-->

### Git的配置

* /etc/gitconfig 文件：系统中对所有用户都普遍适用的配置。若使用 git config 时用 --system 选项，读写的就是这个文件。

* ~/.gitconfig 文件：用户目录下的配置文件只适用于该用户。若使用 git config 时用 --global 选项，读写的就是这个文件。

当前项目的 Git 目录中的配置文件（也就是工作目录中的 .git/config 文件）：这里的配置仅仅针对当前项目有效。每一个级别的配置都会覆盖上层的相同配置，所.git/config 里的配置会覆盖 /etc/gitconfig 中的同名变量。

#### 设置用户信息

```bash
$ git config --globaluser.name  "your-uasername"
$ git config --global user.email example@example.com
$ git config --global core.editor vim
```

#### 设置差异分析工具

```bash
$ git config --global merge.tool vimdiff
```

#### 如何获取帮助文档

```bash
$ git help <verb>
$ git <verb> --help
$ man git-<verb>
```

例如 `man git-config`


### Git基础操作

#### 取得Git仓库（从现有仓库克隆）

```bash
$ git clone https://github.com/schacon/fatest.git
```

这个命令会在当前目录下创建一个fatest的目录，其中的.git目录保存所有的版本记录。fatest下是项目的所有文件。

如果要自定义目录名称，可以在末尾指定，例如：

```bash
$ git clone https://github.com/schacon/fatest.git fatestnew
```

现在创建的目录就是fatestnew而不是fatest了，其他的都一样。

#### 检查当前项目文件状态

```bash
$ git status
```

可以看到有哪些文件是没有加入到版本中的，哪些是修改了还没提交的等等。

#### 将新文件加入到版本中

```bash
$ git add test.cpp
```

注：`git add`命令对于不同状态的文件有不同的效果，可以用它开始跟踪新文件，或者把已跟踪的文件放到暂存区，还能用于合并时把有冲突的文件标记为已解决状态等。

*注意*修改过后的文件处于未暂存状态，提交的时候处于未暂存状态的文件将不会提交，需要使用git add命令更改为暂存状态，之后再提交就会提交到仓库中了。

#### 忽略某些文件

对于不需要加入到版本中，并且使用git status时不再提示的文件。

在 .gitignore 文件中进行配置，例如*.exe

那么所有的以.exe结尾的文件都会被忽略，而不再提醒。
 
例子：

```bash
# 此为注释，将被 Git 忽略
# 忽略所有 .a 结尾的文件
*.a
# 但 lib.a 除外
!lib.a
# 仅仅忽略项目根目录下的 TODO 文件，不包括 subdir/TODO
/TODO
# 忽略 build/ 目录下的所有文件
build/
# 会忽略 doc/notes.txt 但不包括 doc/server/arch.txt
doc/*.txt
# ignore all .txt files in the doc/ directory
doc/**/*.txt
```
 
#### 查看已暂存和未暂存的更新文件差异

未暂存：

```bash
$ git diff
```
       
已暂存：

```bash
$ git diff --staged
```
 
#### 提交更新

```bash
$ git commit
```

之后进入vim编辑提交说明，保存即可。
 
```bash
$ git commit --m "comment"
```

使用 *-m* 命令可以直接在一行命令中写说明。
 
```bash
$ git commit -a
```

使用 *-a* 命令，会把未暂存和已暂存的文件一起提交，不然只会提交已暂存的文件。
 
#### 删除文件和取消跟踪

可以先本地使用rm命令删掉，这时候放在未暂存区域，之后用“git rm文件名”删掉。
 
也可以直接使用 `git rm 文件名` 删掉。
 
另外一种情况是，我们想把文件从 Git 仓库中删除（亦即从暂存区域移除），但仍然希望保留在当前工作目录中。换句话说，仅是从跟踪清单中删除。比如一些大型日志文件或者一堆 .a 编译文件，不小心纳入仓库后，要移除跟踪但不删除文件，以便稍后在 .gitignore 文件中补上，用 --cached 选项即可：
 
```bash
$ git rm --cached readme.txt
```
 
#### 移动文件

例如要把 test.cpp 改为 tt.cpp

```bash
$ git mv test.cpp tt.cpp
```
 
就相当于是

```bash
$ mv README.txt README
$ git rm README.txt
$ git add README
```
 
#### 查看提交历史

```bash
$ git log
```
 
#### 撤销操作

##### 覆盖上一次的提交

```bash
$ git commit --amend
```

会将上次提交和这次提交合并起来，算作一次提交。
 
##### 取消已暂存文件

```bash
$ git reset HEAD <file>
```

这个时候文件状态就从已暂存变为未暂存
 
##### 取消对文件的修改（还没有放到暂存区）

```bash
$ git checkout -- <file>
```
 
#### 运程仓库的使用

##### 查看当前的远程库

```bash
$ git remote
```

会列出每个远程库的简短的名字，默认使用origin表示原始仓库
 
```bash
$ git remote -v
```

会额外列出远程库对应的克隆地址
 
##### 添加远程仓库

```bash
$ git remote add [shortname] [url]
```
 
##### 从远程仓库抓取数据

```bash
$ git fetch [remote-name]
```

抓取数据，但并不合并到当前分支
 
```bash
$ git pull
```

自动抓取数据，并自动合并到当前分支

```bash
$ git branch -r
```

查看所有远程分支

```bash
$ git checkout -b test origin/test
```

获取远程分支到本地新的分支上，并切换到新分支
 
##### 推送数据到远程仓库

```bash
$ git push [remote-name] [branch-name]
```

推送操作会默认使用origin和master名字
 
##### 查看远程仓库信息

```bash
$ git remote show [remote-name]
```

除了对应的克隆地址外，它还给出了许多额外的信息。它友善地告诉你如果是在 master 分支，就可以用 git pull 命令抓取数据合并到本地。另外还列出了所有处于跟踪状态中的远端分支。
 
##### 远程仓库的删除

```bash
$ git remote rm [remote-name]
```
 
#### 标签的使用

##### 显示已有的标签

```bash
$ git tag
```
 
##### 新建标签

```bash
$ git tag v1.0
```

新建一个简单的标签
 
```bash
$ git tag -a v1.0 -m 'my version 1.0'
```

-m 指定了对应标签的说明

##### 后期加注标签

```bash
$ git log --pretty=oneline --abbrev-commit
```

先显示提交历史

```bash
$ git tag -a v1.1 9fceb02
```

补加标签
 
##### 推送标签

```bash
$ git push origin [tagname]
```
 
#### 设置命令别名

```bash
$ git config --global alias.co checkout
```


### Git分支

#### 新建分支

```bash
$ git branch testing
```

会在当前commit对象上新建一个分支指针
 
*注：HEAD这个特别的指针是指向正在工作中的本地分支的指针*

#### 切换分支

```bash
$ git checkout testing
```

切换到testing分支上
 
#### 分支的合并

在master分支上，执行：

```bash
$ git merge testing
```

将tesing分支合并回master
 
#### 使用合并工具（可以自己设置，例如设置成vimdiff）

```bash
$ git mergetool
```
 
#### 分支的管理

```bash
$ git branch --merged
```

查看哪些分支已经被并入当前分支，通常这些都可以删除了。
 
```bash
$ git branch -d testing
```

删除一个分支
 
```bash
$ git branch -D testing
```

如果该分支尚没有合并，可以使用-D选项强制删除。
 
#### 推送本地分支

```bash
$ git push origin testing
```
 
#### 分支的衍合

例如现在有两个分支，一个master，一个testing

```bash
$ git checkout testing
$ git rebase master
$ git checkout master
$ git merge testing
```

通常在贡献自己的代码之前先衍合，再提交，会让历史提交记录更清晰。


### Git调试

#### 文件标注

```bash
$ git blame -L 12,22 test.cpp
```

查看test.cpp文件对每一行进行修改的最近一次提交。
 
#### 查看文件的历史提交

```bash
$ git log --pretty=oneline test.cpp
```

查看test.cpp文件的历史提交记录
 
#### 查看文件的历史版本

```bash
$ git show [commit] [file]
```

例如：`$ git show 7da7c23 test.cpp`

查看7da7c23这次提交的test.cpp文件。

#### 查看历史提交的详细文件变化

```bash
$ git log -p -2
```

通过这条命令可以看到最近两次提交的文件变化情况，删除的部分会以 "-" 开头，新增的部分会以 "+" 开头，方便查看。
