---
categories:
    - "技术文章"
tags:
    - "golang"
date: 2020-03-28
title: "Golang 中使用 JWT 做用户认证"
url: "/2020/03/28/golang-jwt"
---

借助 JWT 做用户认证是比较简单的一种方式。

<!--more-->

### 常见的认证方式

一般用户认证主流的方式大致上分为基于 session 和基于 token 这两种。

#### 基于 sesion 的认证方式

> 1. 用户向服务器发送用户名和密码。
> 2. 服务器验证通过后，在当前对话(sesion）里面保存相关数据，比如用户角色、登录时间等等。
> 3. 服务器向用户返回一个 session_id，写入用户的 Cookie 或其他存储。
> 4. 用户随后的每一次请求，都会通过 Cookie，将 session_id 传回服务器。
> 5. 服务器收到 session_id，找到前期保存的数据，由此得知用户的身份。
> 6. 用户退出登录，服务器将对应 session_id 的数据清除。

这种方式服务端需要将 session_id 及相关的数据保存起来，在接收到用户请求时进行校验，比如可以存储到 Redis 中。

#### 基于 token 的认证方式

> 1. 用户向服务器发送用户名和密码。
> 2. 服务器将相关数据，比如用户 ID，认证有效期等信息签名后生成 token 返回给客户端。
> 3. 客户端将 token 写入本地存储。
> 4. 用户随后的每一次请求，都将 token 附加到 header 中。
> 5. 服务端获取到用户请求的 header，拿到用户数据并且做签名校验，如果校验成功则说明数据没有被篡改，是有效的，确认 token 在有效期内，用户数据就是有效的。

jwt 是基于 token 的认证方式的一种。这里我们使用 [jwt-go](https://github.com/dgrijalva/jwt-go) 在 Golang 项目中使用 jwt。以下代码均为示例代码，部分内容有所删减，仅供参考。

### 生成 Token

服务器端需要提供一个登录接口用于用户登录。客户端提供用户名和密码，服务器端进行校验，如果校验通过，则生成 Token 返回给客户端。

```golang
import (
    jwt "github.com/dgrijalva/jwt-go"
)

func GenerateToken(uid string, role int, expireDuration time.Duration) (string, error) {
    expire := time.Now().Add(expireDuration)
    // 将 uid，用户角色， 过期时间作为数据写入 token 中
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, util.LoginClaims{
        Uid:  uid,
        Role: role,
        StandardClaims: jwt.StandardClaims{
            ExpiresAt: expire.Unix(),
        },
    })
    // SecretKey 用于对用户数据进行签名，不能暴露
    return token.SignedString([]byte(util.SecretKey))
}

func (ctl *LoginController) Login(rw http.ResponseWriter, req *http.Request) {
    var u loginRequest
    json.NewDecoder(req.Body).Decode(&u)

    // 将用户传入的用户名和密码和数据库中的进行比对
    user, err := ctl.db.GetUserByName(req.Context(), u.User)
    if err != nil {
        log.Warn("get user from db by name error: %v", err)
        httputil.Error(rw, errors.ErrInternal)
        return
    }

    if common.EncodePassowrd(u.Password, u.User) != user.Password {
        log.Warn("name [%s] password incorrent", u.User)
        httputil.Error(rw, errors.ErrLoginFailed)
        return
    }

    // 生成返回给用户的 token
    token, err := GenerateToken(user.UID, user.Role, 3*24*time.Hour)
    if err != nil {
        log.Warn("name [%s] generateToken error: %v", u.User, err)
        httputil.Error(rw, errors.ErrInternal)
        return
    }

    res := struct {
        Token string `json:"token"`
    }{
        Token: token,
    }
    httputil.Reply(rw, &res)
}
```

### 校验 Token

这里要求客户端每次将通过登录接口获取到的 token 设置在发送请求的 `Authorization` header 中。

```golang
func (a *AuthFilter) Filter(next http.Handler) http.Handler {
    return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
        tokenStr := req.Header.Get("Authorization")
        token, err := jwt.ParseWithClaims(tokenStr, &util.LoginClaims{}, func(token *jwt.Token) (interface{}, error) {
            return []byte(util.SecretKey), nil 
        }   
        if err != nil {
            httputil.Error(rw, errors.ErrUnauthorized)
            return
        }   

        if claims, ok := token.Claims.(*util.LoginClaims); ok && token.Valid {
            log.Infof("uid: %s, role: %v", claims.Uid, claims.Role)
        } else {
            httputil.Error(rw, errors.ErrUnauthorized)
            return
        }   
        next.ServeHTTP(rw, req)
    }   
}
```

### 注意点

* 由于 jwt 返回的 Token 中的数据仅做了 Base64 处理，没有加密，所以不应放入重要的信息。
* jwt Token 由于是无状态的，任何获取到此 Token 的人都可以访问，所以为了减少盗用，可以将 Token 有效期设置短一些。对一些重要的操作，尽量再次进行认证。
* 网站尽量使用 HTTPS，可以减少 Token 的泄漏。
