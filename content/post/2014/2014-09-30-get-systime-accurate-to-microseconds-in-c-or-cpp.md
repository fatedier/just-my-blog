---
categories:
    - "技术文章"
tags:
    - "c/cpp"
date: 2014-09-30
title: "C/C++获取精确到微秒级的系统时间"
url: "/2014/09/30/get-systime-accurate-to-microseconds-in-c-or-cpp"
---

最近要为自己的项目开发一个日志模块，需要获取精确到微秒级的系统时间，查阅了一些资料，发现在C/C++里面可以通过 gettimeofday(struct timeval * tv,struct timezone * tz) 和 localtime(const time_t * timep) 这两个函数的配合使用来得到我想要的结果。

<!--more-->

先贴一下这两个函数的说明

#### gettimeofday

头文件：`#include <sys/time.h>   #include <unistd.h>`

定义函数：`int gettimeofday (struct timeval * tv, struct timezone * tz);`

函数说明：gettimeofday()会把目前的时间有tv 所指的结构返回，当地时区的信息则放到tz 所指的结构中。时间是从公元 1970 年1 月1 日的UTC 时间从0 时0 分0 秒算起到现在所经过的时间。

timeval 结构定义为：

```cpp
struct timeval
{
    long tv_sec;     // 秒
    long tv_usec;    // 微秒
};
```

timezone 结构定义为：

```cpp
struct timezone
{
    int tz_minuteswest;  // 和格林威治时间差了多少分钟
    int tz_dsttime;      // 日光节约时间的状态
};
```

#### localtime

头文件：`#include <time.h>`

定义函数：`struct tm *localtime (const time_t *timep);`

函数说明：localtime()将参数timep 所指的time_t 结构中的信息转换成真实世界所使用的时间日期表示方法，然后将结果由结构tm 返回。

结构tm 的定义为：

```cpp
int tm_sec;   // 代表目前秒数, 正常范围为0-59, 但允许至61 秒
int tm_min;   // 代表目前分数, 范围0-59
int tm_hour;  // 从午夜算起的时数, 范围为0-23
int tm_mday;  // 目前月份的日数, 范围1-31
int tm_mon;   // 代表目前月份, 从一月算起, 范围从0-11
int tm_year;  // 从1900 年算起至今的年数
int tm_wday;  // 一星期的日数, 从星期一算起, 范围为0-6
int tm_yday;  // 从今年1 月1 日算起至今的天数, 范围为0-365
int tm_isdst; // 日光节约时间的旗标
```

使用localtime函数的时候需要注意计算年份的时候需要加上1900，计算月份的时候需要加1。

### 使用说明

我们先调用gettimeofday函数获取到从公元 1970年1 月1 日的UTC 时间从0 时0 分0 秒算起到现在所经过的秒数加上微秒数，然后将秒数作为参数再调用localtime函数，转换为本地时区的当前时间即可，之后可以使用localtime函数返回的tm结构体对象来获取具体的年月日时分秒等数据。

### 示例代码

```cpp
#include <iostream>
#include <string>
#include <stdio.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
using namespace std;
 
string fa_getSysTime()
{
    struct timeval tv;
    gettimeofday(&tv,NULL);
    struct tm* pTime;
    pTime = localtime(&tv.tv_sec);
    
    charsTemp[30] = {0};
    snprintf(sTemp, sizeof(sTemp), "%04d%02d%02d%02d%02d%02d%03d%03d", pTime->tm_year+1900, \
    pTime->tm_mon+1, pTime->tm_mday, pTime->tm_hour, pTime->tm_min, pTime->tm_sec, \
    tv.tv_usec/1000,tv.tv_usec%1000);
    return (string)sTemp;
}
 
int main()
{
    cout<< "当前时间：" << fa_getSysTime() << endl;
    return 0;
}
```

### 输出为

`当前时间：20140930110457794678`
