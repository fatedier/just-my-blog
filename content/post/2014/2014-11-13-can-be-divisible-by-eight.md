---
categories:
    - "技术文章"
tags:
    - "c/cpp"
    - "算法"
date: 2014-11-13
title: "能否被8整除"
url: "/2014/11/13/can-be-divisible-by-eight"
---

题目：给定一个非负整数，问能否重排它的全部数字，使得重排后的数能被8整除。 输入格式： 多组数据，每组数据是一个非负整数。非负整数的位数不超过10000位。 输出格式 每组数据输出一行,YES或者NO，表示能否重排它的全部数字得到能被8整除的数。注意：重排可以让0开头。

<!--more-->

### 思路

* 考虑到64位整型可以直接取余8求得结果，所以当输入非负整数位数小于20位的时候，可以直接转换成64位整型进行计算。

* 对于一个非负整数，最后四位相当于是 p*1000 + x*100 + y*10 + z ，可以很显然的看出p*1000必然能被8整除，所以一个非负整数只需要后三位能被8整除，那么这个数就一定能被8整除。所以如果我们能从这个数中任意取出三位，作为最后三位，其值能被8整除，就输出YES，否则NO。

* 没必要对可能的10000位做全排列，因为0-9每个数最多只能用3次，我们只需要遍历一遍每一位，将0-9出现的次数记录下来，最多允许记录3次。这样最坏的情况下需要对30个数进行全排列即可，效率会非常高。

### 代码

```cpp
#include <stdio.h>
#include <string.h>
#include <sys/types.h>

#define MAX 10001

int has_num[10];    //0-9在这个数中出现的次数

bool check()
{
    int deal_num[30];   //0-9每个数最多可以用3次，只需要30的空间
    int n = 0;
    //将所有出现过数依次存放在deal_num数组中
    for (int i=0; i<10; i++) {
        for (int j=0; j<has_num[i]; j++) {
            deal_num[n] = i;
            n++;
        }
    }

    //排列任意三个数组成一个整数，其值能被8整除，返回true，否则false
    for (int i=0; i<n; i++) {
        for (int j=0; j<n; j++) {
            if (j == i)
                continue;
            for (int k=0; k<n; k++) {
                if (k == i || k == j) {
                    continue;
                }
                if ((deal_num[i]*100 + deal_num[j]*10 + deal_num[k]) % 8 == 0)
                    return true;
            }
        }
    }
    return false;
}

int main()
{
    char str_num[MAX];  //用于保存不超过10000位的整数
    int n;
    long long temp = 0; //如果位数小于等于19，直接转换为64位整型

    for (;;) {
        memset(str_num, 0, sizeof(str_num));
        for (int i=0; i<10; i++) {
            has_num[i] = 0;
        }
        if (scanf("%s", &str_num) == 1) {
            n = strlen(str_num);
            //转换为64位整型
            if (n <= 19) {
                sscanf(str_num, "%lld", &temp);
                if ((temp % 8) == 0)
                    printf("YES\n");
                else
                    printf("NO\n");
                continue;
            }
            
            //将0-9出现的次数保存在has_num数组中，最多3次
            for (int i=0; i<n; i++) {
                if (has_num[(int)str_num[i] - 48] < 3)
                    has_num[(int)str_num[i] - 48]++;
            }
            if (check())
                printf("YES\n");
            else
                printf("NO\n");
            continue;

        } else {
            break;
        }
    }
    return 0;
}
```
