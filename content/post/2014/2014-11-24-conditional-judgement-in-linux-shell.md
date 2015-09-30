---
categories:
    - "技术文章"
tags:
    - "linux"
    - "shell"
date: 2014-11-24
title: "linux shell中的条件判断"
url: "/2014/11/24/conditional-judgement-in-linux-shell"
---

在日常开发中经常需要编写一些简单的部署或者测试统计之类的脚本，直接用shell来编写几条命令就可以实现一些较为复杂的功能，十分方便。不过 linux shell 中的条件判断和其他编程语言略有不同，有一些需要特别注意的地方。

<!--more-->

### 退出状态

在Linux系统中，每当一条命令执行完成后，系统都会返回一个退出状态，这个状态被存放在$? 这个变量中，是一个整数值，我们可以根据这个值来判断命令运行的结果是否正确。

通常情况下，退出状态值为0，表示执行成功，不为0的时候表示执行失败。

>**POSIX规定的退出状态和退出状态的含义**

>0 （运行成功）

>1-255 （运行失败，脚本命令、系统命令错误或参数传递错误）

>126 （找到了该命令但无法执行）

>127 （未找到要运行的命令）

>128 （命令被系统强行结束）

### 测试命令

```bash
test expression
```

用test命令进行测试，expression是一个表达式

```bash
[ expression ]
```

为了提高可读性，可以使用简化的这种格式

**需要注意的是大括号和表达式之间需要有一个空格，不能省略。这种方式和if、case、while等语句结合，可以作为shell脚本中的判断条件。**

### 整数比较运算符

在shell中对两个数进行比较，不像在C/C++中可以使用 ">" 之类的运算符，而是使用类似参数选项的格式。

```bash
-eq  # 如果等于则为真
-ge  # 如果大于或等于则为真
-gt  # 如果大于则为真
-le  # 如果小于或等于则为真
-lt  # 如果小于则为真
-ne  # 如果不等于则为真
```

**其中的参数可以这样理解e(equal)，g(greater)，t(than)，l(less)，n(not)，这样方便记忆。**

### 字符串相关运算符

```bash
-n string            # 字符串不为空则为真
-z string            # 字符串为空则为真
string1 = string2    # 字符串相等则为真 （或者 == 也可以）
string1 != string2   # 字符串不等则为真
```

**这里有一个需要注意的地方，就是使用 -n 这个运算符进行判断的时候需要注意在变量两边加上双引号。**

**例如 if [ -n $string ] 应该写成 if [ -n “$string” ] ，不然该表达式总是会返回真，因为当string变量为空的时候就相当于是 if [ -n ]。** 

### 文件操作符

```bash
-d file # 测试file是否为目录
-e file # 测试file是否存在
-f file # 测试file是否为普通文件
-r file # 测试file是否是进程可读文件
-s file # 测试file的长度是否不为0
-w file # 测试file是否是进程可写文件
-x file # 测试file是否是进程可执行文件
-L file # 测试file是否符号化链接
```

### 逻辑运算符

```bash
! expression                # 非
expression1 -a expression2  # 与
expression1 -o expression2  # 或
```

多重的嵌套

```bash
if [ $a == 1 ] && [ $b == 1 -o $b == 3 ]
```
