---
categories:
    - "技术文章"
tags:
    - "c/cpp"
date: 2015-08-24
title: "如何修改进程的名称"
url: "/2015/08/24/how-to-modify-process-name"
---

在开发 php 扩展的过程中，希望能创建一个独立的子进程做一些额外的处理工作，并且为子进程修改一个有意义的名称，发现还是有一些难度的。

<!--more-->

### 效果预览

要实现的效果就像 nginx 启动后通过 ps 查到的名称一样，这个名称就是自定义的，如下图

![nginx-process-name](http://image.fatedier.com/pic/2015/2015-08-24-how-to-modify-process-name-nginx-process-name.png)

### 方法一

```cpp
prctl(PR_SET_NAME, name);
```

通过这个函数可以将当前进程的名称修改为 `name` 的内容。

我测试了一下，发现只有使用 `ps -L` 才能看到，达不到想要的效果。

### 方法二

参考了 **nginx** 中的源码，主要是通过修改 **argv[0]** 的值来实现的，但是需要注意将后面跟着的 **environ** 环境表中的信息移到其他地方，避免被覆盖。

```c
void set_proctitle(char** argv, const char* new_name)
{
    int size = 0;
    int i;
    // 申请新的空间存放 environ 中内容
    for (i = 0; environ[i]; i++) {
        size += strlen(environ[i]) + 1;
    }
    char* p = (char*)malloc(size);
    char* last_argv = argv[0];
    for (i = 0; argv[i]; i++) {
        if (last_argv == argv[i]) {
            last_argv = argv[i] + strlen(argv[i]) + 1;
        }
    }  
    for (i = 0; environ[i]; i++) {
        if (last_argv == environ[i]) {
            size = strlen(environ[i]) + 1;
            last_argv = environ[i] + size;  
   
            memcpy(p, environ[i], size);
            environ[i] = (char*)p;
            p += size;
        }  
    }
    last_argv--;
    // 修改 argv[0]，argv剩余的空间全部填0
    strncpy(argv[0], new_name, last_argv - argv[0]);
    p = argv[0] + strlen(argv[0]) + 1;
    if (last_argv - p > 0) {
        memset(p, 0, last_argv - p);
    }  
}
```

稍微解释一下，每一个 c 程序都有个 main 函数，作为程序启动入口函数。main 函数的原型是 `int main(int argc , char *argv[])`，其中 **argc** 表示命令行参数的个数，**argv** 是一个指针数组，保存所有命令行字符串。Linux进程名称是通过命令行参数 **argv[0]** 来表示的。

而进程执行时的环境变量信息的存储地址就是紧接着 **argv** 之后，通过 `char **environ` 变量来获取，类似于下图

![argv-info](http://image.fatedier.com/pic/2015/2015-08-24-how-to-modify-process-name-argv-info.png)

由于我们需要修改 **argv[0]** 的值，有可能新的字符串的长度超过原来 **argv** 中所有字符串长度的总和，又因为 **environ** 在内存空间上是紧跟着 **argv** 的，我们如果直接修改 **argv[0]** 的值，有可能会覆盖掉 **environ** 的内存空间，所以需要先将 **environ** 的内容 copy 到一块新的内存空间，之后再将 **environ** 指针指向新的空间。

### php 扩展中遇到的困难

在修改 php 扩展中 fork 的子进程名称时遇到了问题，由于 php 扩展是注入的方式，提供的动态库，无法获取到从 **main** 函数传入过来的 **argv** 参数的地址。

经过测试，发现 **environ** 是一个全局变量，可以获取到它的地址，而 **argv** 中内容可以用另外一种方式取得，通过查看 `/proc/10000/cmdline` 中的值（10000是该进程的进程号），可以获取命令行启动参数的字符串（也就是 **argv** 中的内容，如果 **argv** 没有被其他代码修改过的话），所以用 **environ** 的地址减去 **cmdline** 中字符串的长度就可以得到 **argv[0]** 的地址。

**注：需要注意的是 cmdline 不是一个普通文件，不能用 stat 或者 ftell 等函数来获取长度，必须用 read 等读取文件的函数去读取。**

参考代码如下：

```c
void set_proctitle_unsafe(const char* new_name)
{
    // 获取该进程的启动参数字符串
    int pid = getpid();
    char file_name[100];
    snprintf(file_name, sizeof(file_name), "/proc/%d/cmdline", pid);

    int fd = open(file_name, O_RDONLY);
    if (fd < 0)
        return;

    char tempCmd[513];
    long cmd_length = read(fd, tempCmd, sizeof(tempCmd));
    close(fd);

    // 获取 argv[0] 的地址
    char *argv = environ[0];
    argv = argv - cmd_length;

    int size = 0;
    int i;
    // 申请新的空间存放 environ 中内容
    for (i = 0; environ[i]; i++) {
        size += strlen(environ[i]) + 1;
    }
    char* p = (char*)malloc(size);

    char* last_argv = argv;
    last_argv = argv + cmd_length;

    for (i = 0; environ[i]; i++) {
        if (last_argv == environ[i]) {
            size = strlen(environ[i]) + 1;
            last_argv = environ[i] + size;

            memcpy(p, environ[i], size);
            environ[i] = (char*)p;
            p += size;
        }
    }
    last_argv--;

    // 修改 argv[0] 的内容
    strncpy(argv, new_name, last_argv - argv);
    p = (argv) + strlen(argv) + 1;
    if (last_argv - p > 0) {
        memset(p, 0, last_argv - p);
    }
}
```

这个函数是不安全的，需要小心使用，因为不能确定 **environ** 的地址是否已经被其他人修改过了，比如在 php 扩展中，有可能已经被其他程序用同样的方法修改过，这样就会造成获取到的 **argv[0]** 的地址是未知的，执行的程序可能就会出现内存错误。
