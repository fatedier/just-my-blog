---
categories:
    - "技术文章"
tags:
    - "kubernetes"
date: 2020-04-17
title: "Kubernetes 挂载 subpath 的容器在 configmap 变更后重启时挂载失败"
url: "/2020/04/17/pod-loopcrash-of-k8s-subpath"
---

Kubernetes 对于挂载了 subpath 的容器，在 configmap 或其他 volume 变更后，如果容器因为意外退出后，就会持续 crash，无法正常启动。

当前 Kubernetes 已经发布了 1.18 版本，这个问题仍然存在。

<!--more-->

社区相关 issue [#68211](https://github.com/kubernetes/kubernetes/issues/68211)

### 复现步骤

```yaml
---
apiVersion: v1
kind: Pod 
metadata:
  name: test-pod
spec:
  volumes:
  - configMap:
      name: extra-cfg
    name: extra-cfg
  containers:
  - name: test
    image: ubuntu:bionic
    command: ["sleep", "30"]
    resources:
      requests:
        cpu: 100m
    volumeMounts:
      - name: extra-cfg
        mountPath: /etc/extra.ini
        subPath: extra.ini
---
apiVersion: v1
data:
  extra.ini: |
    somedata
kind: ConfigMap
metadata:
  name: extra-cfg
```

Apply 此配置，Pod 启动完成后，修改 configmap 的内容，等待 30 秒后容器自动退出，kubelet 重启容器，此时观察到容器持续 mount 失败。

```
Error: failed to start container "test": Error response from daemon: OCI runtime create failed: container_linux.go:345: starting container process caused "process_linux.go:424: container init caused \"rootfs_linux.go:58: mounting \\\"/var/lib/kubelet/pods/e044883a-48da-4d28-b304-1a57dcb32203/volume-subpaths/extra-cfg/test/0\\\" to rootfs \\\"/var/lib/docker/overlay2/31b076d0012aad47aa938b482de24ecda8b41505489a22f63b8a3e4ce39b43ba/merged\\\" at \\\"/var/lib/docker/overlay2/31b076d0012aad47aa938b482de24ecda8b41505489a22f63b8a3e4ce39b43ba/merged/etc/extra.ini\\\" caused \\\"no such file or directory\\\"\"": unknown
```

### 原因分析

#### Configmap Volume 的更新

当容器第一次启动前，kubelet 先将 configmap 中的内容下载到 Pod 对应的 Volume 目录下，例如  `/var/lib/kubelet/pods/{Pod UID}/volumes/kubernetes.io~configmap/extra-cfg`。

同时为了保证对此 volume 下内容的更新是原子的(更新目录时)，所以会通过软链接的方式进行更新，目录中文件如下。

```
drwxrwxrwx 3 root root 4.0K Mar 29 03:12 .
drwxr-xr-x 3 root root 4.0K Mar 29 03:12 ..
drwxr-xr-x 2 root root 4.0K Mar 29 03:12 ..2020_03_29_03_12_44.788930127
lrwxrwxrwx 1 root root   31 Mar 29 03:12 ..data -> ..2020_03_29_03_12_44.788930127
lrwxrwxrwx 1 root root   16 Mar 29 03:12 extra.ini -> ..data/extra.ini
```

`extra.ini` 是 `..data/extra.ini` 的软链，`..data` 是 `..2020_03_29_03_12_44.788930127` 的软链，命名为时间戳的目录存放真实内容。

当 configmap 更新后，会生成新的时间戳的目录存放更新后的内容。

创建新的软链 `..data_tmp` 指向新的时间戳目录，之后重命名为 `..data`，重命名是一个原子操作。

最后删除旧的时间戳目录。

#### 容器挂载 subpath Volume 的准备

当 configmap Volume 准备完成后，kubelet 会将 configmap 中 subpath 指定的文件 bind mount 到一个特殊的目录下: `/var/lib/kubelet/pods/{Pod UID}/volume-subpaths/extra-cfg/{container name}/0`。

```
cat /proc/self/mountinfo|grep extra
2644 219 8:1 /var/lib/kubelet/pods/{Pod UID}/volumes/kubernetes.io~configmap/extra-cfg/..2020_03_29_03_12_13.444136014/extra.ini /var/lib/kubelet/pods/{Pod UID}/volume-subpaths/extra-cfg/test/0 rw,relatime shared:99 - ext4 /dev/sda1 rw,data=ordered
```

可以看出，bind mount 的文件其实是真实文件的时间戳目录下的内容。

当 Configmap 更新后，此时间戳目录会被删除，源文件加上了 `//deleted`。

```
cat /proc/self/mountinfo|grep extra
2644 219 8:1 /var/lib/kubelet/pods/{Pod UID}/volumes/kubernetes.io~configmap/extra-cfg/..2020_03_29_03_12_13.444136014/extra.ini//deleted /var/lib/kubelet/pods/{Pod UID}/volume-subpaths/extra-cfg/test/0 rw,relatime shared:99 - ext4 /dev/sda1 rw,data=ordered
```

#### Bind Mount

当容器启动时，需要将 `/var/lib/kubelet/pods/{Pod UID}/volume-subpaths/extra-cfg/test/0` 挂载到容器中。

如果原来的时间戳目录被删除，则 mount 会出错: `mount: mount(2) failed: No such file or directory`。

通过简单的命令模拟这个问题:

```
# touch a b c
# mount --bind a b
# rm -f a
# mount --bind b c
mount: mount(2) failed: No such file or directory
```

可以看到，当 a 删除后，b 挂载点无法再被 mount。所以，当容器异常退出需要重启后，如果 configmap 被更新，原先的时间戳文件被删除，这个 subpath 就无法再被 mount 到容器中。

### 解决方案

#### Configmap 变更后 Unmount

社区相关 PR: https://github.com/kubernetes/kubernetes/pull/82784

在容器重启前，检查 subpath 挂载点的源文件和新的目标 subpath 文件是否一致。

当 configmap 被更新后，时间戳目录变更，则检查到不一致。将 `/var/lib/kubelet/pods/{Pod UID}/volume-subpaths/extra-cfg/test/0` Unmount，再重新 Bind Mount 当前最新的时间戳目录下的对应文件。

根据社区 PR 中的 comments 来看，此方案可能存在一定风险，尚不明确(有人指出在 4.18 以下内核是不安全的 [链接](https://github.com/es-container/kubernetes/pull/24/files#diff-f0ba2b2ac6f7b574258c97a4001460b2R829))，所以很长时间都没有进展。

通过一段时间的测试，尚未发现明显的问题。

#### 不使用 subpath

使用其他方式绕过这个问题。

例如可以将 Configmap 整个 Mount 到容器的其他目录下，再在容器启动时通过软链的方式链接到对应的路径下。

### 为什么使用间接 Bind Mount 而不是直接 Mount 软链接

参考 https://kubernetes.io/blog/2018/04/04/fixing-subpath-volume-vulnerability/ 这篇文章。

可以看出原先使用的就是直接 Mount 软链接的方式，但是存在安全漏洞，[symlink race](https://en.wikipedia.org/wiki/Symlink_race) 。恶意程序可以通过构造一个软链接，使特权程序(kubelet) 将超出权限范围之外的文件内容挂载到用户容器中。

```yaml
apiVersion: v1
kind: Pod
metadata:
name: my-pod
spec:
  initContainers:
  - name: prep-symlink
    image: "busybox"
    command: ["bin/sh", "-ec", "ln -s / /mnt/data/symlink-door"]
    volumeMounts:
    - name: my-volume
      mountPath: /mnt/data
  containers:
  - name: my-container
    image: "busybox"
    command: ["/bin/sh", "-ec", "ls /mnt/data; sleep 999999"]
    volumeMounts:
    - mountPath: /mnt/data
      name: my-volume
      subPath: symlink-door
  volumes:
  - name: my-volume
  emptyDir: {}
```

使用如上的配置，通过 emptyDir，在 initContainer 中在挂载的 Volume 目录中创建了一个指向根目录的软链接。

之后正常的容器启动，但是指定了 subpath，如果 kubelet 直接 Mount 软链接，会将宿主机的根目录 Mount 到用户容器中。

为了解决这个问题，需要解析出软链接对应的真实文件路径，并且判断此路径是否是在 Volume 目录下，校验通过后才能挂载到容器中。但是由于校验和挂载之间存在时间差，此文件还是有可能会被篡改。

社区讨论后，通过引入中间 Bind Mount 的机制，相当于给这个文件加锁，将原文件的路径固化，之后再 Mount 到容器中时，只会 Mount 当时创建挂载点时的源文件。
