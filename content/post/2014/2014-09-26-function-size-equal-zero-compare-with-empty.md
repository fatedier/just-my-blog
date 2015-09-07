---
categories:
    - "技术文章"
tags:
    - "c/cpp"
    - "Linux"
    - "STL"
date: 2014-09-26
title: "size() == 0和empty()的比较"
url: "/2014/09/26/function-size-equal-zero-compare-with-empty"
---

最近开发公司项目的时候发现大量用到了STL模板库，而且很多地方都需要判断一个容器是否为空，看到了两种写法，分别使用了容器的 size() 函数和 empty()函数。

我觉得很好奇，这两种写法有什么区别呢？在网上查阅了一些资料，发现说empty()效率更高的占大多数。又查看了SGI STL的帮助文档，里面有一句话：

<!--more-->
>  If you are testing whether a container is empty, you should always write c.empty()instead of c.size() == 0. The two expressions are equivalent, but the formermay be much faster.

大致上的意思就是在检测容器是否为空的时候，推荐用empty()代替使用size() == 0，两者的含义是相等的，但是前者可能会更快一些。

之后又在stackoverflow上看到有人提了一个类似的问题，并且贴出了STL的实现源码：

```cpp
bool empty()const
    {return(size() == 0); }
```

这就让我更诧异了，这样的话empty()会比size() == 0更高效吗？

实践是检验真理的唯一标准，那么我们就亲自来测试一下吧。

为了公平起见，也为了测试方便，我分别在两个平台上进行测试，分别是Aix5.3以及Centos6.5。

由于容器的内部实现的不同，我们测试三种比较典型也用的较多的容器：vector、list以及map。

测试的代码如下，因为代码基本上差别不大，这里只贴一下测试vector的代码：

```cpp
#include <iostream>
#include <sys/time.h>
#include <stdlib.h>
#include <vector>
using namespace std;

class A
{
public:
    int a;
};

int main()
{
	cout << "vector:" << endl;

	long number = 20000000;
    vector<A> tmpList;
    A temp;
    temp.a = 1;

    struct timeval tv_begin, tv_end;

    //初始化tmpList中元素个数为：number
    tmpList.resize(number);

    //对size() == 0计时
    int flag = 0;
    gettimeofday(&tv_begin, NULL);
    for(long i=0; i<number*5; i++)
    {
    	if(tmpList.size() == 0)
    	{
    	}
    }
    gettimeofday(&tv_end, NULL);
    cout << "size() msec: " << (tv_end.tv_sec - tv_begin.tv_sec)*1000 + (tv_end.tv_usec - tv_begin.tv_usec)/1000 << endl;

    //对empty()计时
    gettimeofday(&tv_begin, NULL);
    for(long i=0; i<number*5; i++)
    {
    	if(tmpList.empty())
    	{
    	}
    }
    gettimeofday(&tv_end, NULL);
    cout << "empty() msec: " << (tv_end.tv_sec - tv_begin.tv_sec)*1000 + (tv_end.tv_usec - tv_begin.tv_usec)/1000 << endl;
    return 0;
}
```

这里用到了gettimeofday这个函数用来计时，在需要计时的地方分别调用两次该函数之后得到的时间相减即可获得该代码段执行的时间。

timeval结构体有两个变量分别是tv_sec和tv_usec分别是精确到秒和微秒级别。

因为这两个函数本身耗时太短，不方便测算时间，所以采取重复调用再计时的方法。

### vector

#### Aix

```code
第1次输出：
vector:
size() msec:2736
empty() msec:4820

第2次输出：
vector:
size() msec:2762
empty() msec:4877
```

#### Centos

```code
第1次输出：
vector:
size() msec: 298
empty() msec:1541

第2次输出：
vector:
size() msec: 283
empty() msec:1530
```

### list

#### Aix

```code
第1次输出：
vector:
size() msec: 13
empty() msec: 22

第2次输出：
vector:
size() msec: 13
empty() msec: 22
```

#### Centos

```code
第1次输出：
vector:
size() msec: 241696
empty() msec: 1

第2次输出：
vector:
size() msec: 242109
empty() msec: 1
```

### map

#### Aix

```code
第1次输出：
vector:
size() msec: 1337
empty() msec: 1733

第2次输出：
vector:
size() msec: 1339
empty() msec: 1733
```

#### Centos

```code
第1次输出：
vector:
size() msec: 291
empty() msec: 267

第2次输出：
vector:
size() msec: 290
empty() msec: 304
```

可以看出，并非在所有情况下empty()的效率都是优于size()的。具体的效率还和所使用的平台相关，准确的说是和STL源码的实现方式有关。

下面我们就一起来看一下两个系统中STL源码部分是如何实现size()和empty()的。

### vector源码

#### Aix

```cpp
size_type size() const
	{return (_Size); }
 
bool empty() const
	{return (size() == 0); }
```

可以看出Aix上vector的empty()函数实际上是调用了size()函数进行判断，size()函数返回的是表示当前容器数量的一个变量，所以，显然，size() == 0的效率是要高于empty()的，因为少了函数调用部分的耗时。

#### Centos

```cpp
size_type size() const
	{ return size_type(this->_M_impl._M_finish -this->_M_impl._M_start); }
 
bool empty() const
	{ return begin() == end(); }
```

这里size()是尾指针减去头指针得到的，而empty()是比较头指针和尾指针是否相等。在empty()里多了函数调用以及临时变量赋值等操作。

### list源码

#### Aix

```cpp
size_type size() const
	{return (_Size); }
 
bool empty() const
	{return (size() == 0); }
```

Aix上对于在list中的处理方式依然和vector一样，维护了一个_Size变量，empty()多了一层函数调用，效率较低。

#### Centos

```cpp
size_type size() const
	{ return std::distance(begin(), end()); }
 
bool empty() const
	{ return this->_M_impl._M_node._M_next ==&this->_M_impl._M_node; }
```

size()函数调用了distance函数用遍历的方法取得两个指针间的元素个数，然后返回。而empty()函数则是判断头指针的下一个节点是否是自己本身，只需要进行一次判断。所以，当list容器元素个数较多的时候，这里的empty()效率远大于size() == 0。

### map源码

#### Aix

```cpp
size_type size() const
	{return (_Size); }
 
bool empty() const
	{return (size() == 0); }
```

不出意外，可以看出Aix上依然维护了一个_Size变量，在判断的时候都是用这个变量来判断，但是empty()多了一层函数调用，所以效率上会稍微低一些。

#### Centos

```cpp
bool empty() const
	{ return _M_impl._M_node_count == 0; }
 
size_type size() const
	{ return _M_impl._M_node_count; }
```

这里的map用到了红黑树，就不详细解释了，有兴趣的同学可以自己查阅相关资料。代码中empty()和size()用到的都是保存红黑树的节点数的变量，可以看出empty()和size() == 0两者其实是等价的。

### 总结

并不是所有的时候用empty()的效率都比size() == 0要高。

例如在Aix上，由于所有的容器都维护了一个保存元素个数的值，调用size()的时候直接返回，而调用empty()的时候还是要去调用size()函数，所以会多一次函数调用的开销。在Aix上，显然使用size() == 0替代empty()将会使程序效率更高。

而在Centos上，由于STL源码的实现方式不同，需要考虑到使用的容器，不同的容器调用size()和empty()的开销也不同，但是，相对来说，使用empty()的效率更加平均，例如在使用list容器的时候，如果数据量较大，size()的开销太大，而empty()则不会出现这种极端情况。

如果考虑到平台迁移等等将来可能出现的状况，显然，empty()比size() == 0更加合适，可以确保你的程序不会出现太大的性能问题。
