---
categories:
    - "技术文章"
tags:
    - "linux"
    - "c/cpp"
date: 2014-12-16
title: "如何处理僵尸进程"
url: "/2014/12/16/how-to-deal-with-zombie-process"
---

在使用c/c++开发过程中经常会用到多进程，需要fork一些子进程，但是如果不注意的话，就有可能导致子进程结束后变成了僵尸进程。从而逐渐耗尽系统资源。

<!--more-->

### 什么是僵尸进程

如果父进程在子进程之前终止，则所有的子进程的父进程都会改变为init进程，我们称这些进程由init进程领养。这时使用ps命令查看后可以看到子进程的父进程ppid已经变为了1。

而当子进程在父进程之前终止时，**内核为每个终止子进程保存了一定量的信息，所以当终止进程的父进程调用wait或waitpid时**，可以得到这些信息。这些信息至少包括进程ID、该进程的终止状态、以及该进程使用的CPU时间总量。其他的进程所使用的存储区，打开的文件都会被内核释放。

**一个已经终止、但是其父进程尚未对其进行善后处理（获取终止子进程的有关信息，释放它仍占用的资源）的进程被称为僵尸进程。** ps命令将僵尸进程的状态打印为Z。

可以设想一下，比如一个web服务器端，假如每次接收到一个连接都创建一个子进程去处理，处理完毕后结束子进程。假如在父进程中没有使用wait或waitpid函数进行善后，这些子进程将全部变为僵尸进程，Linux系统的进程数一般有一个固定限制值，僵尸进程将会逐渐耗尽系统资源。

### 查看僵尸进程的例子

```cpp
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
 
int main(int argc, char **argv)
{
    pid_t pid;
    for (int i=0; i<5; i++) {
        if ((pid = fork()) < 0) {
            printf("fork error,%s\n", strerror(errno));
            return -1;
        }
        
        /* child */
        if (pid == 0) {
            sleep(1);
            exit(0);
        }
    }  
    /* parent */
    sleep(20);
    return 0;
}
```

编译完成后，在执行程序的命令后加上 "&" 符号，表示让当前程序在后台运行。

之后输入

```bash
ps –e –o pid,ppid,stat,command|grep [程序名]
```

可以看到如下的结果

```bash
2915  1961 S    ./dd
2917  2915 Z    [dd] <defunct>
2918  2915 Z    [dd] <defunct>
2919  2915 Z    [dd] <defunct>
2920  2915 Z    [dd] <defunct>
2921  2915 Z    [dd] <defunct>
```

可以看到5个子进程都已经是僵尸进程了。

### SIGCHLD信号和处理僵尸进程

当子进程终止时，内核就会向它的父进程发送一个SIGCHLD信号，父进程可以选择忽略该信号，**也可以提供一个接收到信号以后的处理函数**。对于这种信号的系统默认动作是忽略它。

我们不希望有过多的僵尸进程产生，所以当父进程接收到SIGCHLD信号后就应该调用 wait 或 waitpid 函数对子进程进行善后处理，释放子进程占用的资源。

下面是一个捕获SIGCHLD信号以后使用wait函数进行处理的简单例子：

```cpp
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
 
void deal_child(int sig_no)
{
    wait(NULL);
}
 
int main(int argc, char **argv)
{
    signal(SIGCHLD, deal_child);
 
    pid_t pid;
    for (int i=0; i<5; i++) {
        if ((pid = fork()) < 0) {
            printf("fork error,%s\n",strerror(errno));
            return -1;
        }  
 
        /* child */
        if (pid == 0) {
            sleep(1);
            exit(0);
        }  
    }  
    /* parent */
    for(int i=0; i<100000; i++) {
        for (int j=0; j<100000; j++) {
            int temp = 0;
        }  
    }  
    return 0;
}
```

同样在后台运行后使用ps命令查看进程状态，结果如下：

```bash
6622  1961 R    ./dd
6627  6622 Z    [dd] <defunct>
6628  6622 Z    [dd] <defunct>
```

发现创建的5个进程，有3个已经被彻底销毁，但是还有2个仍然处于僵尸进程的状态。

**这是因为当5个进程同时终止的时候，内核都会向父进程发送SIGCHLD信号，而父进程此时有可能仍然处于信号处理的deal_child函数中，那么在处理完之前，中间接收到的SIGCHLD信号就会丢失，内核并没有使用队列等方式来存储同一种信号。**

### 正确地处理僵尸进程的方法

为了解决上面出现的这种问题，我们需要使用waitpid函数。

函数原型

```cpp
pid_t waitpid(pid_t pid, int *statloc, int options);
```

若成功则返回进程ID，如果设置为非阻塞方式，返回0表示子进程状态未改变，出错时返回-1。

**options参数可以设置为WNOHANG常量，表示waitpid不阻塞，如果由pid指定的子进程不是立即可用的，则立即返回0。**

只需要修改一下SIGCHLD信号的处理函数即可:

```cpp
void deal_child(int sig_no)
{
    for (;;) {
        if (waitpid(-1, NULL, WNOHANG) == 0)
            break;
    }  
}
```

再次执行程序后使用ps命令查看，发现已经不会产生僵尸进程了。