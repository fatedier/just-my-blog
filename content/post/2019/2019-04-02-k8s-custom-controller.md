---
categories:
    - "技术文章"
tags:
    - "kubernetes"
date: 2019-04-02
title: "kubernetes 自定义控制器"
url: "/2019/04/02/k8s-custom-controller"
---

kubernetes 的 controller-manager 通过 APIServer 实时监控内部资源的变化情况，通过各种操作将系统维持在一个我们预期的状态上。比如当我们将 Deployment 的副本数增加时，controller-manager 会监听到此变化，主动创建新的 Pod。

对于通过 CRD 创建的资源，也可以创建一个自定义的 controller 来管理。

<!--more-->

### 目的

在 [kubernetes 自定义资源(CRD)](/2019/03/20/k8s-crd/) 一文中我们创建了自己的 Scaling 资源，如果我们想要通过监听该资源的变化来实现实时的弹性伸缩，就需要自己写一个控制器，通过 APIserver watch 该资源的变化。

当我们创建了一个 Scaling 对象，自定义控制器都能获得其参数，之后执行相关的检查，根据结果决定是否需要扩容或缩容相关的实例。

### 实现

[client-go](https://github.com/kubernetes/client-go) 这个 repo 封装了对 k8s 内置资源的一些常用操作，包括了 clients/listers/informer 等对象和函数，可以 通过 Watch 或者 Get List 获取对应的 Object，并且通过 Cache，可以有效避免对 APIServer 频繁请求的压力。

但是对于我们自己创建的 CRD，没有办法直接使用这些代码。

通过 [code-generator](https://github.com/kubernetes/code-generator) 这个 repo，我们可以提供自己的 CRD 相关的结构体，轻松的生成 client-go 中类似的代码，方便我们编写自己的控制器。

### 在自己的项目中使用 code-generator

这里主要参考了 [sample-controller](https://github.com/kubernetes/sample-controller) 这个项目。

#### 创建自定义 CRD 结构体

假设我们有一个 `test` repo，在根目录创建一个 `pkg` 目录，用于存放我们自定义资源的 Spec 结构体。

这里我们要知道自己创建的自定义资源的相关内容:

* API Group: 我们使用的是 `control.example.com`。
* Version: 我们用的是 `v1`，但是可以同时存在多个版本。
* 资源名称: 这里是 `Scaling`。

接着创建如下的目录结构:

`mkdir -p pkg/apis/control/v1`

在 `pkg/apis/control` 目录下创建一个 register.go 文件。内容如下:

```golang
package control

const (
    GroupName = "control.example.com"
)
```

创建 `pkg/apis/control/v1/types.go` 文件，内容如下:

```golang
package v1

import (
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// +genclient
// +genclient:noStatus
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

type Scaling struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`

    Spec ScalingSpec `json:"spec"`
}

type ScalingSpec struct {
    TargetDeployment string `json:"targetDeployment"`
    MinReplicas      int    `json:"minReplicas"`
    MaxReplicas      int    `json:"maxReplicas"`
    MetricType       string `json:"metricType"`
    Step             int    `json:"step"`
    ScaleUp          int    `json:"scaleUp"`
    ScaleDown        int    `json:"scaleDown"`
}

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

type ScalingList struct {
    metav1.TypeMeta `json:",inline"`
    metav1.ListMeta `json:"metadata,omitempty"`

    Items []Scaling `json:"items"`
}
```

这个文件中我们定义了 `Scaling` 这个自定义资源的结构体。

其中，类似 `// +<tag_name>[=value]` 这样格式的注释，可以控制代码生成器的一些行为。

* **+genclient**: 为这个 package 创建 client。
* **+genclient:noStatus**: 当创建 client 时，不存储 status。
* **+k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object**: 为结构体生成 deepcopy 的代码，实现了 runtime.Object 的 Interface。

创建 doc 文件，`pkg/apis/control/v1/doc.go`:

```golang
// +k8s:deepcopy-gen=package
// +groupName=control.example.com

package v1
```

最后 client 对于自定义资源结构还需要一些接口，例如 `AddToScheme` 和 `Resource`，这些函数负责将结构体注册到 schemes 中去。

为此创建 `pkg/apis/control/v1/register.go` 文件:

```golang
package v1

import (
    "test/pkg/apis/control"

    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/runtime/schema"
)

var SchemeGroupVersion = schema.GroupVersion{
    Group:   control.GroupName,
    Version: "v1",
}

func Resource(resource string) schema.GroupResource {
    return SchemeGroupVersion.WithResource(resource).GroupResource()
}

var (
    // localSchemeBuilder and AddToScheme will stay in k8s.io/kubernetes.
    SchemeBuilder      runtime.SchemeBuilder
    localSchemeBuilder = &SchemeBuilder
    AddToScheme        = localSchemeBuilder.AddToScheme
)

func init() {
    // We only register manually written functions here. The registration of the
    // generated functions takes place in the generated files. The separation
    // makes the code compile even when the generated files are missing.
    localSchemeBuilder.Register(addKnownTypes)
}

// Adds the list of known types to api.Scheme.
func addKnownTypes(scheme *runtime.Scheme) error {
    scheme.AddKnownTypes(SchemeGroupVersion,
        &Scaling{},
        &ScalingList{},
    )
    metav1.AddToGroupVersion(scheme, SchemeGroupVersion)
    return nil
}
```

至此，初期的准备工作已近完成，可以通过代码生成器来自动帮助我们生成相关的 client, informer, lister 的代码。

#### 生成代码

通常我们通过创建一个 `hack/update-codegen.sh` 脚本来固化生成代码的步骤。

```sh
$GOPATH/src/k8s.io/code-generator/generate-groups.sh all \
test/pkg/client \
test/pkg/apis \
control:v1
```

可以看到，执行这个脚本，需要使用 code-generator 中的的脚本，所以需要先通过 go get 将 code-generator 这个 repo 的内容下载到本地，并且编译出相关的二进制文件(client-gen, informer-gen, lister-gen)。

执行完成后，可以看到 `pkg` 目录下多了一个 `client` 目录，其中就包含了 informer 和 lister 相关的代码。

并且在 `pkg/apis/control/v1` 目录下，会多一个 `zz_generated.deepcopy.go` 文件，用于 deepcopy 相关的处理。

#### 创建自定义控制器代码

这里只创建一个 `main.go` 文件用于简单示例，通过我们刚刚自动生成的代码，每隔一段时间，自动通过 lister 获取所有的 Scaling 对象。

```golang
package main

import (
    "fmt"
    "log"
    "os"
    "time"

    "k8s.io/apimachinery/pkg/labels"
    "k8s.io/client-go/tools/clientcmd"
    clientset "test/pkg/client/clientset/versioned"
    informers "test/pkg/client/informers/externalversions"
)

func main() {
    client, err := newCustomKubeClient()
    if err != nil {
        log.Fatalf("new kube client error: %v", err)
    }

    factory := informers.NewSharedInformerFactory(client, 30*time.Second)
    informer := factory.Control().V1().Scalings()
    lister := informer.Lister()

    stopCh := make(chan struct{})
    factory.Start(stopCh)

    for {
        ret, err := lister.List(labels.Everything())
        if err != nil {
            log.Printf("list error: %v", err)
        } else {
            for _, scaling := range ret {
                log.Println(scaling)
            }
        }

        time.Sleep(5 * time.Second)
    }
}

func newCustomKubeClient() (clientset.Interface, error) {
    kubeConfigPath := os.Getenv("HOME") + "/.kube/config"

    config, err := clientcmd.BuildConfigFromFlags("", kubeConfigPath)
    if err != nil {
        return nil, fmt.Errorf("failed to create out-cluster kube cli configuration: %v", err)
    }

    cli, err := clientset.NewForConfig(config)
    if err != nil {
        return nil, fmt.Errorf("failed to create custom kube client: %v", err)
    }
    return cli, nil
}
```

编译并执行此代码，每隔 5 秒钟，会在标准输出中输出我们创建的所有 Scaling 对象的具体内容。

需要注意的是，这里生成的 kube client 只能用于操作我们自己的 Scaling 对象。如果需要操作 Deployment 这一类的内置的资源，仍然需要使用 `client-go` 中的代码，因为不同的 `clientset.Interface` 实现的接口也是不同的。
