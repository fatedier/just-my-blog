---
categories:
    - "技术文章"
tags:
    - "kubernetes"
date: 2019-03-25
title: "kubernetes CRD 权限管理"
url: "/2019/03/25/k8s-crd-authorization"
---

对于一个多个用户的集群而言，通常单个用户只有自己 namespace 的相关权限，而 kubernetes CRD 需要配置额外的权限才能使用。

<!--more-->

在 [kubernetes 自定义资源(CRD)](/2019/03/20/k8s-crd/) 一文中，我们尝试创建了一个 scalings 资源，对于拥有 Admin 权限的用户没有问题，但是对于普通用户，创建时则会提示

`
customresourcedefinitions.apiextensions.k8s.io "scalings.control.example.io" is forbidden: User "test" cannot get customresourcedefinitions.apiextensions.k8s.io at the cluster scope
`

### kubernetes 中的权限管理

当前 kubernetes 通常采用 RBAC(Role-Based Access Control) 的授权管理方式，可以很好的实现资源隔离效果。

这种方法引入了几个概念: Role, ClusterRole, RoleBinding, ClusterRoleBinding

Role 表示角色，每一个角色都可以定义一些规则表征这个角色对哪些资源有哪些操作的权限。Role 和 ClusterRole 的区别就在于 Role 是区分 Namespace 的，而 ClusterRole 则是整个集群的权限。

比如如下的配置表示 Role `pod-reader` 拥有对 `default` Namespace 的 `pods` 的只读权限。

```yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: default
  name: pod-reader
rules:
- apiGroups: [""] # 空字符串表明使用 core API group
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
```

接着我们需要将这个 Role 和具体的用户绑定起来使其生效。

```yaml
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: read-pods
  namespace: default
subjects:
- kind: User
  name: jane
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role # this must be Role or ClusterRole
  name: pod-reader # this must match the name of the Role or ClusterRole you wish to bind to
  apiGroup: rbac.authorization.k8s.io
```

通过这两个配置，jane 这个用户就具备了 `default` Namespace 的 `pods` 资源的只读权限。

ClusterRole 和 ClusterRoleBinding 的使用姿势没有太大区别，只是作用域是整个集群，不需要指定 Namespace。

### CRD 资源操作权限

CustomResourceDefinition 存在于所有 namespace 下，所以需要创建 ClusterRole 和 ClusterRoleBinding 来让普通用户拥有操作 CRD 的 admin 权限。

参考配置如下:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: crd-admin
rules:
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["create", "delete", "deletecollection", "patch", "update", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: test-crd-admin
subjects:
- kind: User
  name: test
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: crd-admin
  apiGroup: rbac.authorization.k8s.io
```

kubectl apply 该配置，则 test 用户具备了对 `customresourcedefinitions.apiextensions.k8s.io` 的所有操作权限，可以正常创建，删除，更新 CRD 资源。

但是对于我们通过 CRD 创建出来的自定义资源，例如 `scalings.control.example.com`，还没有任何权限，不能创建和查看对象。

### CRD 对象操作权限

对于 `scalings.control.example.com` 这样的我们自己创建出来的资源，也需要对普通用户授予权限，但是不需要是集群范围内的，只需要授予用户关联的 namespace 下的权限即可。所以可以通过创建新的 Role 和 RoleBinding 来实现这一能力。

参考配置如下:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: default-crd-object
  namespace: default
rules:
- apiGroups: ["control.example.com"]
  resources: ["scalings"]
  verbs: ["create", "delete", "deletecollection", "patch", "update", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: default-crd-object
  namespace: default
subjects:
- kind: User
  name: test
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: default-crd-object
  apiGroup: rbac.authorization.k8s.io
```

kubectl apply 该配置，则 test 用户可以正常创建和查看 scalings 资源对象。
