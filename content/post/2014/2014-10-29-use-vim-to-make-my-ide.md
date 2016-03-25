---
categories:
    - "技术文章"
tags:
    - "linux"
    - "开发工具"
date: 2014-10-29
title: "使用Vim打造自己的IDE"
url: "/2014/10/29/use-vim-to-make-my-ide"
---

之前一直使用UE的FTP功能编辑Linux虚拟机上的代码文件，之后再切换到Linux上去编译，调试程序，感觉这样比较麻烦，而且UE的功能也不像VS以及Eclipse的IDE那样强大，所以就查阅了一些资料，想要把Linux下最常用的文本编辑工具Vim打造成一个适合自己的IDE，可以直接ssh登陆到远程机器上直接进行开发。

<!--more-->

配置自己的Vim过程中参考了以下的blog和文档：

* [http://blog.csdn.net/fbfsber008/article/details/7055842](http://blog.csdn.net/fbfsber008/article/details/7055842)
* [http://www.douban.com/note/257815917/](http://www.douban.com/note/257815917/)
* [https://github.com/vim-scripts/vundle](https://github.com/vim-scripts/vundle)

最终的效果：

![overview](http://7xs9f1.com1.z0.glb.clouddn.com/pic/2014/2014-10-29-use-vim-to-make-my-ide-overview.jpg)

现在把整个配置的过程记录下来，方便以后参考。

### 前期准备

1. 有一个github帐号
2. Linux上安装git版本控制工具，可以使用命令安装，例如 yum install git

github是一个好地方，不仅可以浏览很多的开源程序，而且可以把自己正在开发的项目或者有用的文档托管在上面，不管在其他任何的计算机上都可以很容易的获取到。

比如我的 .vimrc 的配置文件就放在了Github上，有一个版本库是专门用来存放配置文件的。

地址为：[https://github.com/fatedier/dot_file](https://github.com/fatedier/dot_file)

### vim常用配置

个人的vim配置文件一般是放在用户主目录下的.vimrc文件。

配置文件中 `"` 之后的部分都被当作注释。

```
if v:lang =~ "utf8$" || v:lang =~"UTF-8$"
    set fileencodings=ucs-bom,utf-8,latin1
endif
       
set nocompatible            " Use Vim defaults (much better!)
set bs=indent,eol,start     " allow backspacing overeverything in insert mode
set viminfo='20,\"50        " read/write a .viminfo file, don't store more
                            " than 50 lines of registers
set history=50              " keep 50 lines of command line history
set ruler                   " show the cursor position all the time
                                    
" -----------个人设置-----------
filetype off

set ts=4          " tab所占空格数
set shiftwidth=4  " 自动缩进所使用的空格数
set expandtab     " 用空格替换tab
set autoindent    " 自动缩进
set smartindent   " C语言缩进
set number        " 显示行号
set ignorecase    " 搜索忽略大小写
set incsearch     " 输入字符串就显示匹配点
set showtabline=2 " 总是显示标签页
                                      
if has("mouse")
    set mouse=iv  " 在 insert 和 visual 模式使用鼠标定位
endif
      
" -------------颜色配置-------------
" 补全弹出窗口
hi Pmenu ctermbg=light magenta
" 补全弹出窗口选中条目
hi PmenuSel ctermbg=yellow ctermfg=black
       
" -------------键盘映射-------------
" Ctrl+S 映射为保存
nnoremap <C-S> :w<CR>
inoremap <C-S><Esc>:w<CR>a
        
" Ctrl+C 复制，Ctrl+V 粘贴
inoremap <C-C> y
inoremap <C-V> <Esc>pa
vnoremap <C-C> y
vnoremap <C-V> p
nnoremap <C-V> p

" F3 查找当前高亮的单词
inoremap <F3>*<Esc>:noh<CR>:match Todo /\k*\%#\k*/<CR>v
vnoremap <F3>*<Esc>:noh<CR>:match Todo /\k*\%#\k*/<CR>v

" Ctrl+\ 取消缩进
inoremap <C-\> <Esc><<i
```

### 使用vundle管理vim插件

很多时候我们的vim都需要安装大量的插件，需要进行各种配置，而且插件路径下面的文件也会变的非常混乱，这个时候使用 **vundle** 就是一个不错的选择。

[vundle](https://github.com/vim-scripts/vundle) 是可以算是一个用来管理各种vim插件的插件。

#### 安装ctags

直接使用命令 yuminstall ctags 进行安装。

之后在你的项目文件的根目录中执行如下的命令：

```bash
$ ctags -R
```

会发现当前目录下生成了一个名为tags的文件。

tags文件是由ctags程序产生的一个索引文件，如果你在读程序时看了一个函数调用, 或者一个变量, 或者一个宏等等, 你想知道它们的定义在哪儿，tags文件就起作用了。使用把光标移动到你想查的地方，按下"Ctrl + ]"，就可以跳转到定义处。

最后需要在vim配置文件中将tags文件加入到vim中来：

```bash
set tags=~/tags
```

**注：这里需要填具体的tags文件所在路径。**

#### 先安装vundle这个插件

```bash
$ git clone https://github.com/gmarik/vundle.git ~/.vim/bundle/vundle
```

之后其他的插件也都会被放在~/.vim/bundle这个目录下。

#### 安装其他需要的插件

以后当你需要安装其他的vim插件的时候，直接在.vimrc中加上如下部分：

```bash
filetype off
 
setrtp+=~/.vim/bundle/vundle/
call vundle#rc()
" Bundles
" 显示变量、函数列表等
Bundle"taglist.vim"
" 窗口管理器
Bundle"winmanager"
" 标签工具
Bundle"Visual-Mark"
" 代码补全工具
Bundle"neocomplcache"
  
filetype pluginindent on
```

Bundle 后面的插件名称用引号引起来，最后在vim中输入:BundleInstall就会完成自动安装，实际上是也是从github上下载各种插件，因为大多数的插件已经备份在了github上的vim-scripts上。

`:PluginSearch` 命令可以查看有哪些插件可以直接使用插件名下载的。

如果你需要的插件在这个里面没有找到，那么在.vimrc配置文件中可以直接用git远程仓库的地址，例如要安装command-t这个插件，可以在配置文件中加上：

```bash
Bundle "git://git.wincent.com/command-t.git"
```

这样就会直接从这个地址上下载所需插件。

### 其他插件的配置与使用

#### 快速浏览源码：TagList

在Windows平台我经常用来浏览项目源码的工具就是SourceInsight，会在窗口左边列出当前文件中的变量、宏、函数名等等，点击以后就会快速跳转到页面相应的地方，使用taglist就可以在vim中实现相同的效果。

通过vundle安装完成后，在vim中使用 `:Tlist` 命令就可以打开TagList窗口。

#### 窗口管理器：WinManager

WinManager可以帮助我们管理在屏幕上显示的多个窗口。

之后我们需要设置一下在normal模式下可以直接输入wm来打开文件管理窗口以及TagList，.vimrc文件增加如下命令：

```bash
let g:winManagerWindowLayout='FileExplorer|TagList'
nnoremap wm:WMToggle<cr>
```

**注：nnoremap是设置键盘映射。第一个字母n是normal模式，i是insert模式，v是visual模式。加上nore表示不会递归替换命令，比如a映射到b，b映射到c，那么按a不会得到按c的效果。**

#### 高亮标签：VisualMark

这个插件的作用就是在浏览代码的时候在指定的行上添加标签，之后可以快速跳转回来，方便快捷。

安装完成之后直接就可以在vim中使用。

"mm" 命令会在当前行添加标签，再次按 "mm" 会取消标签。

按下“F2”可以在多个标签之间进行快速跳转。
 
#### 自动补全：neocomplcache

这个补全插件需要tags文件的支持，所以需要安装ctags，并且在项目根目录生成tags文件，之后在.vimrc中加入这个tags文件。

并且在配置文件中加上如下配置：

```bash
let g:neocomplcache_enable_at_startup = 1
```

这一行是设置是否自动启用补全，为1代表启用。这样就不需要每次都使用Ctrl+P或者Ctrl+N来弹出补全列表。

```bash
let g:neocomplcache_enable_auto_select = 1
```

这一行是设置是否启用自动选择，为1代表启用。这个时候弹出补全列表的时候会自动选择第一个，按下Enter键就会使用列表的第一项，否则每一次都需要自己多按一次进行选择。
