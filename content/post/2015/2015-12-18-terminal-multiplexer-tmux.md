---
categories:
    - "技术文章"
tags:
    - "linux"
    - "开发工具"
date: 2015-12-18
title: "终端利器 Tmux"
url: "/2015/12/18/terminal-multiplexer-tmux"
---

开发过程中通过ssh到服务器是很常见的，工作中基本上90%的时间在和终端打交道，如果没有一个称手的工具，将会在不停打开新的 tab 页，窗口切换中耗费大量的时间。Tmux 是终端复用器的意思，和 screen 类似，但是高度可定制，通过 tmux 可以方便地管理大量的 ssh 连接，并且灵活地在不同窗口，不同面板之间切换。

<!--more-->

### 界面

![tmux](/pic/2015/2015-12-18-terminal-multiplexer-tmux-tmux-overview.png)

我用了自己的配置文件，对界面做过一些优化，左下角是 **session** 名称，中间是各个 **window** 的名称，可以理解为一般 IDE 中的 Tab 页，右下角显示时间，这个窗口中打开了3个 **pane**，通过快捷键，我就可以在不同的 **session**, **window**, **pane** 之间来回切换，基本上脱离了鼠标的使用。

* session： 可以用于区分不同的项目，为每个项目建立一个 session。
* window： 对应于其他 IDE 的 Tab 标签页，一个 window 占据一个显示屏幕，一个 session 可以有多个 window。
* pane： 在一个 window 中可以有多个 pane，便于大屏幕显示屏将屏幕切分成多块。

### 安装

Centos下直接通过 `yum install -y tmux` 来安装，其他系统也一样可以使用相应的包管理工具安装。

### 常用命令

#### 快捷键前缀

为了避免按键冲突，使用 tmux 的快捷键都需要加上一个**前缀按键**，默认是 **Ctrl-b** 的组合，可以通过配置修改为自定义的按键。

例如要退出 tmux 的快捷键是前缀键 + d，那么就需要按 Ctrl-b + d：

* 按下组合键 Ctrl-b
* 放开组合键 Ctrl-b
* 按下 s 键

我自己将 Ctrl-b 改成了 Ctrl-x ，感觉这样操作顺手一些。

#### 基本操作

**创建一个叫做 "test" 的 session，并且进入 tmux 界面**

`tmux new -s test`

**查看开启了哪些 session**

`tmux ls`

**进入 session "test"**

`tmux attach -t test`

**退出 tmux 环境**

`Ctrl-b + d  // 退出后 session 并不会被关闭，之后通过 attach 进入仍然会看到原来的界面`

**切换 session**

`Ctrl-b + s，之后按序号切换，或者通过方向键选择后按 Enter 键切换`

**切换 window**

```
Ctrl-b + <窗口号>
Ctrl-b + n  // 切换到下一个窗口
Ctrl-b + p  // 切换到上一个窗口
```

**切换 pane**

```
这个我在配置文件中修改过，修改成了 vim 的使用习惯，具体配置见下节
Ctrl-b + h  // 左
Ctrl-b + j  // 下
Ctrl-b + k  // 上
Ctrl-b + l  // 右
```

**关闭 pane**

`Ctrl-b + x  // 焦点在要关闭的 pane 内`

**关闭 window**

`Ctrl-b + & // 焦点在要关闭的 window 内`

**分割 window 成多个 pane**

```
这个为了记忆方便也修改了原有的配置
Ctrl-b + _  // 竖直分割
Ctrl-b + |  // 水平分割
```

**重新加载配置文件**

```
这个被我映射到了 r 键，修改完配置文件后不用关闭所有 session 重新打开，直接重新加载即可
Ctrl-b + r
```

### 小技巧

#### 复制模式

如果要在不同 **window** 或者 **pane** 之间复制内容，又想实现全键盘的操作，就需要借助于 tmux 的复制功能。

1. **Ctrl-b + [** 进入复制模式
2. 移动光标到要复制的地方，这里我配置成了 vim 的操作方式
3. 按下**空格**开始复制
4. 再移动到结束的地方，按下 **Enter** 键退出
5. 在需要粘贴的地方按下 **Ctrl-b + ]** 粘贴

#### 多 pane 批量操作

有时候同时登录了多台机器，需要执行一样的命令来进行批量操作，借助于 tmux 同样可以实现。

`:setw synchronize-panes`

这个是设置批量操作的开关，如果原来功能是关闭的，则打开，反之亦然，可以将其映射到一个快捷键方便操作。开启这个功能后，在当前 window 任意一个 pane 输入的命令，都会同时作用于该 window 中的其他 pane。

### 配置文件

配置文件需要自己在 $HOME 目录下创建，命名为 .tmux.conf，具体内容如下

```
# Use something easier to type as the prefix.
set -g prefix C-x
unbind C-b
bind C-x send-prefix

# 窗口计数从1开始，方便切换
set -g base-index 1
setw -g pane-base-index 1

# 启用和关闭status bar
bind S set status on
bind D set status off 

# 消息背景色
set -g message-bg white

set -g mode-keys vi

# 关闭自动重命名窗口
setw -g allow-rename off 
setw -g automatic-rename off 

# bind a reload key
bind r source-file ~/.tmux.conf \; display-message "Config reloaded..."

# I personally rebind the keys so "|" splits the current window vertically, and "-" splits it horizontally. Not the easiest things to type, though easy to remember.
bind | split-window -h
bind _ split-window -v

# fixes the delay problem
set -sg escape-time 0

# 面板切换
bind-key k select-pane -U
bind-key j select-pane -D
bind-key h select-pane -L
bind-key l select-pane -R

# 面板大小调整
bind -r ^k resizep -U 10  
bind -r ^j resizep -D 10
bind -r ^h resizep -L 10
bind -r ^l resizep -R 10

# 状态栏
# 颜色
set -g status-bg black
set -g status-fg white

# 对齐方式
set-option -g status-justify centre

# 左下角
set-option -g status-left '#[bg=black,fg=green][#[fg=cyan]#S#[fg=green]]'
set-option -g status-left-length 20

# 窗口列表
set-window-option -g window-status-format '#[dim]#I:#[default]#W#[fg=grey,dim]'
set-window-option -g window-status-current-format '#[fg=cyan,bold]#I#[fg=blue]:#[fg=cyan]#W#[fg=dim]'

# 右下角
set -g status-right '#[fg=green][#[fg=cyan]%H:%M#[fg=green]]'

```

### 配套工具

#### tmuxinator

使用 tmux 可以让我们不管在什么时候，什么地点登录服务器都能得到同样的工作界面，不用因为担心网络暂时中断而需要重新打开一大堆的 tab 页。

但是如果有的时候服务器重启了，那么所有的 session 就都没了，必须重新打开，可以想象一下我开发时有4-5个 session，每个 session 中有多个 window，然后每个 winodw 中通常又有2-3个 pane，要重新一个个建立开发环境是一件多么痛苦的事。

[tmuxinator](https://github.com/tmuxinator/tmuxinator) 可以稍微缓解一下这个问题，但是不彻底。tmuxinator 可以用于管理 tmux 的 session 和 window 布局等，便于在机器重启后能够快速恢复自己的工作环境。

##### 安装

先安装 gem， `yum install -y rubygems`

**由于天朝特殊的网络环境，gem的第三方包可能安装不了，可以替换成阿里提供的镜像源。**
`gem sources --add [https://ruby.taobao.org/](https://ruby.taobao.org/) --remove [https://rubygems.org/](https://rubygems.org/)`

##### 使用

创建一个 tmuxinator 的 project： `tmuxinator new [project]`

之后编写项目的配置文件，以后重新打开这个项目所显示的界面就是根据这个配置文件来生成。具体用法可以参考项目文档： https://github.com/tmuxinator/tmuxinator。

当服务器重启了以后，执行 `tmuxinator start [project]`，tmuxinator 就会自动根据配置文件创建一个指定布局的 tmux session。

##### 缺点

布局是预先在配置文件中指定好的，你在使用 tmux 过程中修改了的布局是不会记录下来的。

#### Tmux Resurrect

Tmux Resurrect 用于保存当前的session环境到磁盘上，用于以后恢复。

**由于这个插件需要 tmux 1.9 及以上的版本，而 centos7 的 yum 源里现在是1.8的版本，我的开发环境全是自动构建，不方便升级，所以暂时还没有尝试。**

关于 Tmux Resurrect 的相关文档： http://www.linuxidc.com/Linux/2015-07/120304.htm
