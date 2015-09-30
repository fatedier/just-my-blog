---
categories:
    - "技术文章"
tags:
    - "linux"
date: 2014-11-03
title: "Linux下如何进行文件编码格式转换"
url: "/2014/11/03/how-to-convert-file-encoding-format-on-linux"
---

最近把项目放到github上，但是发现代码中注释的中文部分有些是乱码，检查后发现是因为我的Centos装在虚拟机上，而我是在Windows环境下通过UE来写代码的，而UE默认是使用ASCII编码。为了避免在UE里对一个个文件进行手动修改，希望在Linux上使用命令来批量转换编码格式。

<!--more-->

查了资料后发现可以使用 **iconv** 命令。

首先使用 **file** 命令来检测文件的类型

例如

```bash
file test.cpp
```

输出
```bash
ISO-8859 Cprogram text
```

### iconv命令的参数说明

```bash
-l  列出所有已知的字符集
-f  原始文本编码
-t  输出文本编码
-o  输出文件名
-s  关闭警告
```

### 例子

```bash
iconv -f GB2312 -t UTF-8 test.cpp > test_utf.cpp
```

因为iconv默认输出到标准输出，所以我们需要重定向到一个其他文件。**（这里不能重定向到自身，否则会清空文件内容）**

如果想要把输出内容直接输出到当前文件，可以这样用：

```bash
iconv -f GB2312 -t UTF-8 -o test.cpp test.cpp
```

### 附上我自己用的编码转换脚本 iconvfa.sh

#### 使用说明

```bash
Usage:
    iconvfa.sh [option] [file|dir]
    from GB2312 to UTF-8, the old file will be replaced by the new converted file

Options:
    -R: convert files recursively, the following parameter should be the directory name
```

#### 脚本代码

```bash
#!/bin/env bash

function show_help
{
    echo "Usage:"
    echo "  iconvfa.sh [option] [file|dir]"
    echo -e "  from GB2312 to UTF-8, the old file will be replaced by the new converted file\n"
    echo "Options:"
    echo "  -R: convert files recursively, the following parameter should be the directory name"
}

# param 1: directory name
function convert_rescursive()
{
   local dir_path=`echo $1 | sed 's/\(.*\)\/$/\1/g'`
   local dir_names=`ls ${dir_path} -l | awk '/^d/{print $NF}'`
   
   # convert files in this directory
   local file_names=`ls ${dir_path} -l | awk '/^-/{print $NF}'`
   for file in ${file_names}
   do
       iconv -f ${from_code} -t ${to_code} ${dir_path}/${file} &> /dev/null
       if [ $? == 0 ]; then
           iconv -f ${from_code} -t ${to_code} < ${dir_path}/${file} > $@.$$$$
           cp $@.$$$$ ${dir_path}/${file}
           rm -f $@.$$$$
           echo "File ${dir_path}/${file} is formatted."
       fi
   done

   # if the directory has no other directory, return 0
   if [ "${dir_names}X" == "X" ]; then
       return 0
   fi

   # continue convert files in directories recursively
   for dir in ${dir_names}
   do
       convert_rescursive "${dir_path}/${dir}"
   done 
}

# defines
from_code="GB2312"
to_code="UTF-8"

case "$1" in
"-R")
    ls $2 &> /dev/null
    if [ $? != 0 -o "$2X" == "X" ]; then
        echo "#### error: please check the directory name following the '-R' option!"
        exit 1
    fi
    convert_rescursive $2
    ;;
"")
    show_help
    ;;
*)
    iconv -f ${from_code} -t ${to_code} $1 &> /dev/null
    if [ $? == 0 ]; then
        iconv -f ${from_code} -t ${to_code} < $1 > $@.$$$$
        cp $@.$$$$ $1
        rm -f $@.$$$$
        echo "File $1 is formatted."
    else
        echo "Convert wrong!"
    fi
    ;;
esac
```
