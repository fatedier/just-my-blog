---
categories:
    - "技术文章"
tags:
    - "c/cpp"
    - "设计模式"
date: 2015-03-04
title: "在C++中利用反射和简单工厂模式实现业务模块解耦"
url: "/2015/03/04/decoupling-by-using-reflect-and-simple-factory-pattern-in-cpp"
---

在设计一个系统框架的时候往往需要划分各个模块、组件，抽象出公共的部分，尽量避免耦合，以利于以后的扩展和复用。在这方面，JAVA的很多特性在利用各种设计模式的时候会非常容易，而在C++中就需要自己去一步步实现。

<!--more-->

### 业务说明

为了便于说明，举一个简单的例子。假设现在有一个项目需要建立一个和银行交互的平台，目前只接入工商银行，后续接入其他银行，每个银行的业务都有差异，报文格式可能也不一致。

这里只列举几个简要的流程，仅包括拼报文，发送报文，接收报文，解析报文，其余整体架构以及后续处理等内容省略。

### 初步设计

创建一个银行交互类 BankOpt，包括四个函数

```cpp
int setMsg();       // 拼报文
int sendMsg();      // 发送报文
int getMsg();       // 接收报文
int parseMsg();     // 解析报文
```

然后在每个函数中通过if-else来判断具体是哪一个银行，之后进行相应的处理。

这种设计在刚开发的时候非常方便，代码量少，但是如果后续需要接入另外一个银行时就需要改动 **BankOpt** 类，不符合设计模式中的开放-封闭原则。而且单个函数中将来可能会有大量的 **if-else**，使代码可读性下降。

### 简单工厂模式

通过简单工厂模式，我们可以创建一个专门的工厂类用于实例化一个合适的银行交互类，只需要这个银行交互类具有共同的接口即可。

首先，为了实现更好的复用，把各个银行交互类中相同的部分抽象出来，形成一个银行交互基类，代码如下：

```cpp
class BaseBank
{
public:
    virtual int setMsg() = 0;
    virtual int sendMsg() = 0;
    virtual int getMsg() = 0;
    virtual int parseMsg() = 0;
};
```

这里仅仅声明了四个纯虚函数，具体的业务逻辑在子类中实现。

创建两个银行交互子类GSBank（工商银行）和RMBank（人民银行），继承BaseBank，实现四个虚函数。

#### 创建一个工厂类

```cpp
class BankFactory
{
public:
    BaseBank* createBank(const string& bank_name) {
    if (bank_name == "SBank") 
        return new GSBank();
    else if (bank_name == "MBank")
        return new RMBank();
    }
};
```

工厂类中有一个 **createBank** 函数，用于根据银行编码创建相应的实例并返回其基类指针，这样我们只需要通过基类指针调用相关函数即可。

#### 在主流程中调用

```cpp
BankFactory bf;
BaseBank* t = (BaseBank*)bf.createBank(bank_name);
if (t == NULL) {
    cout << "银行编码错误！" << endl;
    return 2;
}
t->setMsg();
t->sendMsg();
t->getMsg();
t->parseMsg();
```

#### 优缺点

利用简单工厂模式，当我们后续接入另外的银行时，只需要添加具体的银行交互类，实现业务函数，然后在工厂类的 **createBank** 函数中添加一个 **else if** 子句。相对于原来的设计已经改进很多了，但是仍然需要修改原来的工厂类的代码，没有彻底实现解耦。

### 反射

反射在java的一些框架中使用的比较多，而且用起来非常方便。C++本身并不支持，但是我们可以模拟一些简单的特性。

我们需要一种能够根据字符串动态获取对应的银行交互类的实例的方法。这样在工厂类的 **createBank** 方法中就可以根据字符串直接获取对应银行交互类的实例，而不需要再每次通过新增 **else if** 子句来新增一个银行接口。

也就是说，利用反射和简单工厂模式，下次当我们需要新增一个银行接口的时候只需要新增一个银行交互类即可，不需要修改原来的任何代码，实现了业务上的解耦。

#### 如何在C++中实现反射 

1. 需要一个全局的map用于存储类的信息以及创建实例的函数

2. 需要反射的类需要提供一个用于创建自身实例的函数

3. 利用类的静态变量在程序启动的时候会进行初始化来在全局map中将类名及创建实例的函数存入map中

相关代码如下：

```cpp
typedef void* (*register_func)();

class Class
{
public:
static void* newInstance(const string& class_name) {
    map<string, register_func>::iterator it = m_register.find(class_name);
    if (it == m_register.end())
        return NULL;
    else
        return it->second();
}
static void registerClass(const string& class_name, register_func func) {
    m_register[class_name] = func;
}

private:
    /* key is class name and value is function to create instance of class */
    static map<string, register_func> m_register;
};


class Register
{
public:
    Register(const string& class_name, register_func func) {
        Class::registerClass(class_name, func);
    }
};

#define REGISTER_CLASS(class_name) \
    class class_name##Register { \
    public: \
        static void* newInstance() { \
            return new class_name; \
        } \
    private: \
        static const Register reg; \
    };\
const Register class_name##Register::reg(#class_name,class_name##Register::newInstance);
```

还需要修改工厂类的 **createBank** 函数，利用Class的 **newInstance** 函数来创建实例：

```cpp
BaseBank* createBank(const string& bank_name) {
    return (BaseBank*)Class::newInstance(bank_name);
}
```

Class类中的 **m_register** 变量是 **static** 类型的map，相当于全局变量。

**newInstance** 函数，传入类名，查找map，调用回调函数，返回一个对应类的实例。 

**registerClass** 函数传入类名和用于创建实例的回调函数并将信息存入全局的map中。

**Register** 类只有一个构造函数，会调用Class的 **registerClass** 函数完成注册。

利用宏定义，在每一个需要反射的类后面额外增加一个类，其中有一个 **Register** 类型的 **static const** 变量，这样在程序启动的时候就会完成初始化调用 **Register** 类的构造函数，完成注册。

之后只需要在需要反射的类，例如在工商银行交互类 GSBank 后面加上一条宏定义：

```cpp
REGISTER_CLASS(GSBank)
```

就可以通过工厂类传入 "GSBank" 字符串获得工商银行交互类的实例。

### 测试

![GSBANK](http://image.fatedier.com/pic/2015/2015-03-04-decoupling-by-using-reflect-and-simple-factory-pattern-in-cpp-gsbank.jpg)

![RMBANK](http://image.fatedier.com/pic/2015/2015-03-04-decoupling-by-using-reflect-and-simple-factory-pattern-in-cpp-rmbank.jpg)

通过传入不同的银行编码，会实例化不同的银行交互类，并且执行其对应的函数。

如果需要增加新的银行接口，例如农业银行，只需要新增一个 **NYBank** 类，实现具体的业务逻辑，不需要改动原来的任何代码，传入 **NYBank** 字符串，就会执行农业银行相关的处理流程。
