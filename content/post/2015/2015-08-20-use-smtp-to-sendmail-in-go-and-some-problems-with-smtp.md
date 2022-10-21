---
categories:
    - "技术文章"
tags:
    - "golang"
date: 2015-08-20
title: "go语言中使用smtp发送邮件及smtp协议的相关问题"
url: "/2015/08/20/use-smtp-to-sendmail-in-go-and-some-problems-with-smtp"
---

go 的标准库中有一个 smtp 包提供了一个可以非常方便的使用 smtp 协议发送邮件的函数，通常情况下使用起来简单方便，不过我在使用中却意外遇到了一个会导致邮件发送出错的情况。

<!--more-->

### smtp 协议发送邮件

#### sendmail 函数

go 标准库的 net/smtp 包提供了一个 SendMail 函数用于发送邮件。

```go
func SendMail(addr string, a Auth, from string, to []string, msg []byte) error
```

**SendMail**： 连接到 **addr** 指定的服务器；如果支持会开启 **TLS**；如果支持会使用 **a(Auth)** 认证身份；然后以 **from** 为邮件源地址发送邮件 **msg** 到目标地址 **to**。（可以是多个目标地址：群发）

**addr**： 邮件服务器的地址。

**a**： 身份认证接口，可以由 `func PlainAuth(identity, username, password, host string) Auth` 函数创建。

#### 简单发送邮件示例

```go
package main

import (
    "fmt"
    "net/smtp"
    "strings"
)

func main() {
    auth := smtp.PlainAuth("", "username@qq.com", "passwd", "smtp.qq.com")
    to := []string{"to-user@qq.com"}
    nickname := "test"
    user := "username@qq.com"
    subject := "test mail"
    content_type := "Content-Type: text/plain; charset=UTF-8"
    body := "This is the email body."
    msg := []byte("To: " + strings.Join(to, ",") + "\r\nFrom: " + nickname +
        "<" + user + ">\r\nSubject: " + subject + "\r\n" + content_type + "\r\n\r\n" + body)
    err := smtp.SendMail("smtp.qq.com:25", auth, user, to, msg)
    if err != nil {
        fmt.Printf("send mail error: %v", err)
    }
}
```

**autu**： 这里采用简单的明文用户名和密码的认证方式。

**nickname**： 发送方的昵称。

**subject**： 邮件主题。

**content_type**： 可以有两种方式，一种 text/plain，纯字符串，不做转义。一种 text/html，会展示成 html 页面。

**body**： 邮件正文内容。

**msg**： msg 的内容需要遵循 smtp 协议的格式，参考上例。

### 特定邮件服务器出错

```bash
certificate signed by unknown authority
```

在通过公司内部自己搭建的邮件服务器发送邮件时报了上述错误，看上去是因为认证不通过的问题，检查了一下用户名和密码没有问题。

我通过抓包以及手动 telnet 执行了一遍 smtp 的过程，发送问题出现在是否加密和身份验证上。

#### SMTP 协议

smtp 协议开始时客户端主动向邮件服务器发送 `EHLO`，服务器会返回支持的所有命令，例如

```bash
250-PIPELINING
250-SIZE 10240000
250-VRFY
250-ETRN
250-STARTTLS
250-AUTH PLAIN LOGIN
250-AUTH=PLAIN LOGIN
250-ENHANCEDSTATUSCODES
250-8BITMIME
250 DSN
```

如果有 **STARTTLS**，说明支持加密传输，golang 的标准库中会进行判断然后决定是否选择使用 **STARTTLS** 加密传输。

如果没有 **AUTH=PLAIN LOGIN**，说明不支持 **PLAIN** 方式。

一共有3种验证方式，可以参考这篇 blog： http://blog.csdn.net/mhfh611/article/details/9470599

#### STARTTLS 引起的错误

公司内部的邮件服务器返回了 **STARTTLS**，但是实际上却不支持加密传输的认证方式，所以就导致了身份认证失败。

大部分国内的邮件服务器都支持 **LOGIN** 和 **PLAIN** 方式，所以我们可以在代码中直接采用 **PLAIN** 的方式，不过安全性就降低了。

想要强制使用 **PLAIN** 方式也不是这么容易的，因为涉及到修改 **net/smtp** 的 `SendMail` 函数，当然标准库我们修改不了，所以只能重新实现一个 `SendMail` 函数。

标准库中 `SendMail` 函数代码如下：

```go
func SendMail(addr string, a Auth, from string, to []string, msg []byte) error {
    c, err := Dial(addr)
    if err != nil {
        return err
    }
    defer c.Close()
    if err = c.hello(); err != nil {
        return err
    }
    if ok, _ := c.Extension("STARTTLS"); ok {
        config := &tls.Config{ServerName: c.serverName}
        if testHookStartTLS != nil {
            testHookStartTLS(config)
        }
        if err = c.StartTLS(config); err != nil {
            return err
        }
    }
    if a != nil && c.ext != nil {
        if _, ok := c.ext["AUTH"]; ok {
            if err = c.Auth(a); err != nil {
                return err
            }
        }
    }
    if err = c.Mail(from); err != nil {
        return err
    }
    for _, addr := range to {
        if err = c.Rcpt(addr); err != nil {
            return err
        }
    }
    w, err := c.Data()
    if err != nil {
        return err
    }
    _, err = w.Write(msg)
    if err != nil {
        return err
    }
    err = w.Close()
    if err != nil {
        return err
    }
    return c.Quit()
}
```

重点就在于下面这一段

```go
if ok, _ := c.Extension("STARTTLS"); ok {
    config := &tls.Config{ServerName: c.serverName}
    if testHookStartTLS != nil {
        testHookStartTLS(config)
    }
    if err = c.StartTLS(config); err != nil {
        return err
    }
}
```

逻辑上就是检查服务器端对于 **EHLO** 命令返回的所支持的命令中是否有 **STARTTLS**，如果有，则采用加密传输的方式。我们自己实现的函数中直接把这部分去掉。

我们仿照 `SendMail` 函数实现一个 `NewSendMail` 函数

```go
func NewSendMail(addr string, a smtp.Auth, from string, to []string, msg []byte) error {
    c, err := smtp.Dial(addr)
    if err != nil {
        return err 
    }   
    defer c.Close()
    if err = c.Hello("localhost"); err != nil {
        return err 
    }   
    err = c.Auth(a)
    if err != nil {
        return err 
    }   

    if err = c.Mail(from); err != nil {
        fmt.Printf("mail\n")
        return err 
    }   
    for _, addr := range to {
        if err = c.Rcpt(addr); err != nil {
            return err 
        }   
    }
    w, err := c.Data()
    if err != nil {
        return err
    }
    _, err = w.Write(msg)
    if err != nil {
        return err
    }
    err = w.Close()
    if err != nil {
        return err
    }
    return c.Quit()
}
```

通过这个函数发送邮件，则身份认证时不会采用加密的方式，而是直接使用 **PLAIN** 方式。
