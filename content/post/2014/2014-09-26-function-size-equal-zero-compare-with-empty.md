---
categories:
    - "��������"
tags:
    - "c/cpp"
    - "Linux"
    - "STL"
date: 2014-09-26
title: "size() == 0��empty()�ıȽ�"
url: "/2014/09/26/function-size-equal-zero-compare-with-empty"
---

���������˾��Ŀ��ʱ���ִ����õ���STLģ��⣬���Һܶ�ط�����Ҫ�ж�һ�������Ƿ�Ϊ�գ�����������д�����ֱ�ʹ���������� size() ������ empty()������

�Ҿ��úܺ��棬������д����ʲô�����أ������ϲ�����һЩ���ϣ�����˵empty()Ч�ʸ��ߵ�ռ��������ֲ鿴��SGI STL�İ����ĵ���������һ�仰��

<!--more-->
>  If you are testing whether a container is empty, you should always write c.empty()instead of c.size() == 0. The two expressions are equivalent, but the formermay be much faster.

�����ϵ���˼�����ڼ�������Ƿ�Ϊ�յ�ʱ���Ƽ���empty()����ʹ��size() == 0�����ߵĺ�������ȵģ�����ǰ�߿��ܻ����һЩ��

֮������stackoverflow�Ͽ�����������һ�����Ƶ����⣬����������STL��ʵ��Դ�룺

```cpp
bool empty()const
    {return(size() == 0); }
```

������Ҹ������ˣ������Ļ�empty()���size() == 0����Ч��

ʵ���Ǽ��������Ψһ��׼����ô���Ǿ�����������һ�°ɡ�

Ϊ�˹�ƽ�����ҲΪ�˲��Է��㣬�ҷֱ�������ƽ̨�Ͻ��в��ԣ��ֱ���Aix5.3�Լ�Centos6.5��

�����������ڲ�ʵ�ֵĲ�ͬ�����ǲ������ֱȽϵ���Ҳ�õĽ϶��������vector��list�Լ�map��

���ԵĴ������£���Ϊ��������ϲ�𲻴�����ֻ��һ�²���vector�Ĵ��룺

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

    //��ʼ��tmpList��Ԫ�ظ���Ϊ��number
    tmpList.resize(number);

    //��size() == 0��ʱ
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

    //��empty()��ʱ
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

�����õ���gettimeofday�������������ʱ������Ҫ��ʱ�ĵط��ֱ�������θú���֮��õ���ʱ��������ɻ�øô����ִ�е�ʱ�䡣

timeval�ṹ�������������ֱ���tv_sec��tv_usec�ֱ��Ǿ�ȷ�����΢�뼶��

��Ϊ���������������ʱ̫�̣����������ʱ�䣬���Բ�ȡ�ظ������ټ�ʱ�ķ�����

### vector

#### Aix

```code
��1�������
vector:
size() msec:2736
empty() msec:4820

��2�������
vector:
size() msec:2762
empty() msec:4877
```

#### Centos

```code
��1�������
vector:
size() msec: 298
empty() msec:1541

��2�������
vector:
size() msec: 283
empty() msec:1530
```

### list

#### Aix

```code
��1�������
vector:
size() msec: 13
empty() msec: 22

��2�������
vector:
size() msec: 13
empty() msec: 22
```

#### Centos

```code
��1�������
vector:
size() msec: 241696
empty() msec: 1

��2�������
vector:
size() msec: 242109
empty() msec: 1
```

### map

#### Aix

```code
��1�������
vector:
size() msec: 1337
empty() msec: 1733

��2�������
vector:
size() msec: 1339
empty() msec: 1733
```

#### Centos

```code
��1�������
vector:
size() msec: 291
empty() msec: 267

��2�������
vector:
size() msec: 290
empty() msec: 304
```

���Կ��������������������empty()��Ч�ʶ�������size()�ġ������Ч�ʻ�����ʹ�õ�ƽ̨��أ�׼ȷ��˵�Ǻ�STLԴ���ʵ�ַ�ʽ�йء�

�������Ǿ�һ������һ������ϵͳ��STLԴ�벿�������ʵ��size()��empty()�ġ�

### vectorԴ��

#### Aix

```cpp
size_type size() const
	{return (_Size); }
 
bool empty() const
	{return (size() == 0); }
```

���Կ���Aix��vector��empty()����ʵ�����ǵ�����size()���������жϣ�size()�������ص��Ǳ�ʾ��ǰ����������һ�����������ԣ���Ȼ��size() == 0��Ч����Ҫ����empty()�ģ���Ϊ���˺������ò��ֵĺ�ʱ��

#### Centos

```cpp
size_type size() const
	{ return size_type(this->_M_impl._M_finish -this->_M_impl._M_start); }
 
bool empty() const
	{ return begin() == end(); }
```

����size()��βָ���ȥͷָ��õ��ģ���empty()�ǱȽ�ͷָ���βָ���Ƿ���ȡ���empty()����˺��������Լ���ʱ������ֵ�Ȳ�����

### listԴ��

#### Aix

```cpp
size_type size() const
	{return (_Size); }
 
bool empty() const
	{return (size() == 0); }
```

Aix�϶�����list�еĴ���ʽ��Ȼ��vectorһ����ά����һ��_Size������empty()����һ�㺯�����ã�Ч�ʽϵ͡�

#### Centos

```cpp
size_type size() const
	{ return std::distance(begin(), end()); }
 
bool empty() const
	{ return this->_M_impl._M_node._M_next ==&this->_M_impl._M_node; }
```

size()����������distance�����ñ����ķ���ȡ������ָ����Ԫ�ظ�����Ȼ�󷵻ء���empty()���������ж�ͷָ�����һ���ڵ��Ƿ����Լ�����ֻ��Ҫ����һ���жϡ����ԣ���list����Ԫ�ظ����϶��ʱ�������empty()Ч��Զ����size() == 0��

### mapԴ��

#### Aix

```cpp
size_type size() const
	{return (_Size); }
 
bool empty() const
	{return (size() == 0); }
```

�������⣬���Կ���Aix����Ȼά����һ��_Size���������жϵ�ʱ����������������жϣ�����empty()����һ�㺯�����ã�����Ч���ϻ���΢��һЩ��

#### Centos

```cpp
bool empty() const
	{ return _M_impl._M_node_count == 0; }
 
size_type size() const
	{ return _M_impl._M_node_count; }
```

�����map�õ��˺�������Ͳ���ϸ�����ˣ�����Ȥ��ͬѧ�����Լ�����������ϡ�������empty()��size()�õ��Ķ��Ǳ��������Ľڵ����ı��������Կ���empty()��size() == 0������ʵ�ǵȼ۵ġ�

### �ܽ�

���������е�ʱ����empty()��Ч�ʶ���size() == 0Ҫ�ߡ�

������Aix�ϣ��������е�������ά����һ������Ԫ�ظ�����ֵ������size()��ʱ��ֱ�ӷ��أ�������empty()��ʱ����Ҫȥ����size()���������Ի��һ�κ������õĿ�������Aix�ϣ���Ȼʹ��size() == 0���empty()����ʹ����Ч�ʸ��ߡ�

����Centos�ϣ�����STLԴ���ʵ�ַ�ʽ��ͬ����Ҫ���ǵ�ʹ�õ���������ͬ����������size()��empty()�Ŀ���Ҳ��ͬ�����ǣ������˵��ʹ��empty()��Ч�ʸ���ƽ����������ʹ��list������ʱ������������ϴ�size()�Ŀ���̫�󣬶�empty()�򲻻�������ּ��������

������ǵ�ƽ̨Ǩ�ƵȵȽ������ܳ��ֵ�״������Ȼ��empty()��size() == 0���Ӻ��ʣ�����ȷ����ĳ��򲻻����̫����������⡣