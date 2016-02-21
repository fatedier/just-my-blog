---
categories:
    - "技术文章"
tags:
    - "linux"
    - "python"
date: 2015-05-08
title: "python中使用pycurl库上传文件"
url: "/2015/05/08/upload-file-in-python-using-pycurl"
---

在对外提供各种语言SDK的时候经常会遇到需要上传文件的问题，例如在python中我们可以借助pycurl库实现这个功能。

<!--more-->

### 项目地址

https://github.com/pycurl/pycurl

### 示例代码

```python
import pycurl
import StringIO

# 用于执行http请求的通用函数
# post_data: post参数字符串
# upload_file: dict类型，需要有file_path(指定要上传的文件路径)和file_name(指定上传后的文件名)
def do_http_request(method, url, post_data='', upload_file=None): 
    ch = pycurl.Curl() 
    buf = StringIO.StringIO() 
    ch.setopt(ch.URL, url) 
    ch.setopt(ch.CUSTOMREQUEST, method) 
    if upload_file != None: 
        ch.setopt(ch.HTTPPOST, [('file', (ch.FORM_FILE, upload_file['file_path'], \ 
            ch.FORM_FILENAME, upload_file['file_name']))]) 
    else: 
        if method == self.METHOD_POST: 
            ch.setopt(ch.POSTFIELDS,  urlencode(post_data)) 

    ch.setopt(ch.TIMEOUT, 30) 
    ch.setopt(ch.WRITEFUNCTION, buf.write)
    ch.perform() 
    content = buf.getvalue()
    buf.close()
    ch.close()
    return content
```

上面的代码是一个用pycurl库写的调用http请求的通用函数，如果upload_file不为None，则表示需要上传文件，upload_file是一个dict类型，需要有两个key，file_path(指定要上传的文件路径)和file_name(指定上传后的文件名)。

**ch.FORM_FILE**：指定要上传文件的路径

**ch.FORM_FILENAME**：指定要上传文件的文件名
