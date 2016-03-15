---
categories:
    - "技术文章"
tags:
    - "linux"
    - "c/cpp"
date: 2015-01-25
title: "epoll使用说明"
url: "/2015/01/25/introduction-of-using-epoll"
---

在《UNIX网络编程》一书中介绍了如何使用select/poll来实现I/O多路复用，简而言之就是通过内核的一种机制，监视多个文件描述符，一旦某个文件描述符处于就绪状态，就通知用户程序进行相应的读写操作，这样用户程序就不用阻塞在每一个文件描述符上。

<!--more-->

epoll相对于select/poll来说有很大优势：

* **不再需要每次把fd集合从用户态拷贝到内核态。**

* **不再需要在每次就绪时遍历fd集合中的所有fd来检查哪些fd处于就绪状态，epoll只返回就绪的fd集合。**

* **select一般只支持1024个文件描述符，而epoll没有类似的限制。**

### epoll相关函数

使用epoll只需要记住3个系统调用函数。

#### int epoll_create(int size)

创建一个epoll实例，从2.68的Linux内核开始，size参数不再生效，内核会动态分配所需的数据结构。失败返回-1，成功则该函数会返回一个文件描述符，并占用一个fd值，所以在使用完之后要记得close该文件描述符。

#### int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event)

用于对epoll实例执行不同的操作的函数。

**epfd**

使用epoll_create()返回的文件描述符

**op**

用三个宏表示不同的操作

* EPOLL_CTL_ADD：注册新的fd到epfd中；

* EPOLL_CTL_MOD：修改已经注册的fd的监听事件；

* EPOLL_CTL_DEL：从epfd中删除指定fd；

**fd**

要监听的文件描述符

**event**

event 是与指定fd关联的epoll_event结构，包含了监听事件，附加数据
    
**struct epoll_event** 的结构如下

```cpp
typedef union epoll_data {
    void        *ptr;
    int          fd;
    __uint32_t   u32;
    __uint64_t   u64;
}epoll_data_t;
 
struct epoll_event {
    __uint32_t  events;      /* Epoll events */
    epoll_data_t data;       /* User data variable */
};
```

**这里需要特别注意的是epoll_data_t是一个union结构，fd和ptr指针只能使用一个，通常我们使用void *ptr存储需要附加的用户数据结构，然后在用户数据结构中存储int型的fd，这样在epoll_wait调用后就仍然能获得该注册事件对应的文件描述符。**

events可以是如下值的集合

```bash
EPOLLIN ：表示对应的文件描述符可以读（包括对端SOCKET正常关闭）
EPOLLOUT：表示对应的文件描述符可以写
EPOLLPRI：表示对应的文件描述符有紧急的数据可读（这里应该表示有带外数据到来）
EPOLLERR：表示对应的文件描述符发生错误
EPOLLHUP：表示对应的文件描述符被挂断
EPOLLET： 将EPOLL设为边缘触发(EdgeTriggered)模式，这是相对于水平触发(Level Triggered)来说的
EPOLLONESHOT：只监听一次事件，当监听完这次事件之后，如果还需要继续监听这个socket的话，需要再次把这个socket加入到EPOLL队列里
```

#### int epoll_wait(int epfd, struct epoll_event * events, int maxevents,int timeout)

该函数等待epoll实例中的fd集合有就绪事件。

```bash
epfd：使用epoll_create()返回的文件描述符
events：指向处于就绪状态的事件集合
maxevents：最多maxevents数量的事件集合会被返回
timeout：超时时间，单位为毫秒；指定为-1没有超时时间，指定为0则立即返回并返回0
```

如果成功，返回已就绪的事件的个数；如果达到超时时间仍然没有就绪事件，返回0；如果出现错误，返回-1并置errno值

### LT和ET两种工作方式

epoll 默认使用LT的工作方式，当指定事件就绪时，内核通知用户进行操作，如果你只处理了部分数据，只要对应的套接字缓冲区中还有剩余数据，下一次内核仍然还会继续通知用户去进行处理，所以使用这种模式来写程序较为简单。

ET工作方式是一种高速工作方式，只能使用非阻塞socket，它的效率要比LT方式高。当一个新事件就绪时，内核通知用户进行操作，如果这时用户没有处理完缓冲区的数据，缓冲区中剩余的数据就会丢失，用户无法从下一次epoll_wait调用中获取到这个事件。

举个例子，可以指定事件为 EPOLLIN| EPOLLET 来使用ET工作方式获取指定文件描述符的可读事件。

**在该事件就绪后，需要不断调用read函数来获取缓冲区数据，直到产生一个EAGAIN错误或者read函数返回的读取到的数据长度小于请求的数据长度时才认为此事件处理完成。write也是一样的处理方式。**
