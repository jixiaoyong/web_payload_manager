# iOS Hybrid 混合开发踩坑与避坑宝典 (Troubleshooting Guide)

本文档系统整理在多个大规模商业级 App 线上生产环境中沉淀的 **Flutter + Web 离线包混合开发实战踩坑经验与终极解决方案**。

---

## 目录
1. [陷阱一：iOS WebContent 进程崩溃（Jetsam）与永久白屏](#1-ios-webcontent-进程崩溃jetsam与永久白屏)
2. [陷阱二：原生弹窗 (Dialog / BottomSheet) 遮盖后手势完全失效](#2-原生弹窗-dialog--bottomsheet-遮盖后手势完全失效)
3. [陷阱三：SPA 单页路由与原生返回键冲突（回退穿透与死循环）](#3-spa-单页路由与原生返回键冲突回退穿透与死循环)
4. [陷阱四：第三方支付（Apple Pay / 支付宝 / 微信支付）差异化回调与切后台防杀](#4-第三方支付apple-pay--支付宝--微信支付差异化回调与切后台防杀)
5. [陷阱五：大文件解压与同步阻塞 UI 主线程掉帧](#5-大文件解压与同步阻塞-ui-主线程掉帧)
6. [陷阱六：本地 Local HTTP Server 端口冲突与自愈](#6-本地-local-http-server-端口冲突与自愈)
7. [架构与安全专题：本地 Localhost 局域网隔离与本机防探测保障](#7-架构与安全专题本地-localhost-局域网隔离与本机防探测保障)

---

## 1. iOS WebContent 进程崩溃（Jetsam）与永久白屏

### 现象描述
在 iOS 设备（尤其是 RAM ≤ 3GB 的机型，如 iPhone 8/SE/XR/11/12）上：
- 用户在 H5 页面中点击拍照、上传图片或拉起系统相册；
- 或者 App 切换到后台片刻再切回前台；
- 或者在包含多个 Web Tab 的首页频繁切 Tab；
- **WebView 突然变成纯白屏或灰色，页面上的所有 DOM 元素全部消失，无论点击或滑动均没有任何响应**。

### 深度根因分析
在 iOS 架构中，WebKit 的 `WKWebView` 并不运行在宿主 App 进程内部，而是由系统独立的 `com.apple.WebKit.WebContent` 独立进程负责渲染。

当 iOS 设备遭遇内存压力时，系统的 **Jetsam 机制** 会优先杀死占用大内存的辅助进程（WebContent），而宿主 Flutter App 并不会收到崩溃通知。一旦 WebContent 进程被杀，WKWebView 就会变成空白占位画布，若宿主 App 不主动处理，WebView 将永久停滞在白屏状态。

### 解决方案

#### 1. 监听 `onWebContentProcessDidTerminate` 自动重载自愈
在 `InAppWebView` 或 `WebViewWidget` 中配置重载回调：

```dart
InAppWebView(
  // ... 其他配置
  // iOS 核心避坑：当系统杀掉 WebContent 进程时，主动 reload 自愈
  onWebContentProcessDidTerminate: (controller) async {
    debugPrint('[WebHost] onWebContentProcessDidTerminate triggered! Reloading...');
    await controller.reload();
  },
)
```

#### 2. 本地服务器使用流式传输（Streaming）+ ETag 缓存
传统本地服务一次性读取几兆到十几兆的 Bundle / 图片至内存中再返回，极易瞬间推高内存峰值触发 Jetsam。
`web_payload_manager` 的 `LocalWebServer` 采用流式传输与 304 缓存：
```dart
// 使用 Dart File.openRead().pipe(request.response) 流式传输
await file.openRead().pipe(request.response);
```

#### 3. 低配机多 Web Tab 动态卸载策略（针对复杂多 Tab 首页架构）
如果你的 App 首页底部导航栏有多个 Tab 内嵌了 WebView，在物理内存 ≤ 3GB 的 iOS 设备上，**切走该 Tab 时坚决不要使用 `Offstage` 隐藏常驻**，而应直接替换为 `SizedBox.shrink()` 彻底释放其 WebContent 进程：
```dart
// 物理 RAM ≤ 3GB 时仅挂载当前激活的 Web Tab，切走即销毁 WebContent
if (_isLowRamIosDevice && !isActiveTab) {
  return const SizedBox.shrink();
}
```

---

## 2. 原生弹窗 (Dialog / BottomSheet) 遮盖后手势完全失效

### 现象描述
- 用户在 WebView 中触发某项操作，宿主 Flutter 弹出了一个原生对话框（如 `showDialog`、权限申请弹窗或 `showModalBottomSheet`）；
- 弹窗关闭后，**WebView 上的所有按钮、链接、滚动完全被“冻结”，怎么点击都无法触发任何事件**；
- 但如果将 App 切入后台再切回前台，或者旋转屏幕，手势又突然恢复。

### 深度根因分析
1. **PlatformView 的层级与命中测试 (Hit-Test)**：
   Flutter 在 iOS 上嵌入的原生视图通过 `PlatformView`（`UiKitView`）渲染。
2. **`PointerInterceptor` 的死锁滥用陷阱**：
   历史上，曾有开发者为了防止触摸事件“穿透”到下层的 PlatformView，在 WebView 外部或者全屏加了一层 `PointerInterceptor`。然而，在 Flutter 的路由生命周期中，当 Dialog 销毁时，如果该层拦截器未及时刷新状态或脱离渲染树，其底层注册在 iOS 平台通道上的覆盖 View 并未销毁，导致后续的所有手势都被空遮罩吞噬，引发点击永久死锁！
3. **Flutter 引擎历史手势识别器状态机缺陷**：
   在 Flutter 3.16 之前的引擎中，`FlutterDelayingGestureRecognizer` 在宿主 Modal 弹层关闭后未能正常重置，导致一直将后续点击判定为手势冲突并拦截。

### 解决方案

#### 1. 坚决不要在 WebView 上挂载全局 `PointerInterceptor`
Flutter 现代版本的 `showDialog` / `showModalBottomSheet` 自身具备完备的 `ModalBarrier`，在弹窗存续期间足以阻挡触摸。

#### 2. 绑定 `EagerGestureRecognizer`
确保 WebView 自身获得手势调度的最高优先级，在按下第一瞬即交由 iOS 原生 UIKit 处理，从根源上避开 Flutter 手势竞技场的死锁：
```dart
InAppWebView(
  gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
    Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
  },
  // ...
)
```

---

## 3. SPA 单页路由与原生返回键冲突（回退穿透与死循环）

### 现象描述
现代前端应用通常是 SPA 单页架构（Vue Router 或 React Router）：
- 用户在 H5 内部从首页点击进入了商品详情页 `/detail`，再点击进入了订单确认页 `/confirm`；
- 用户按下 Android 物理返回键或点击 AppBar 左上角返回箭头：
  - **现象 A（回退穿透）**：原生直接执行 `Navigator.pop(context)`，把整个 WebView 容器关闭了，用户直接退出了混合功能模块！
  - **现象 B（死循环卡死）**：如果原生只判断 `controller.canGoBack()`，由于 SPA 的 `#hash` 或 HTML5 History API 在某些重定向/初始页面也记录了历史，`canGoBack()` 始终返回 `true`，用户在当前页面不停循环刷新，永远退不出 App！

### 深度根因分析
原生 WebView 的浏览器历史栈（History API）无法精准感知前端单页框架（如 Vue Router 的路由守卫、动态重定向或模态层）。原生容器必须与前端页面建立**双向返回协商机制**。

### 解决方案：`WebNavigationNegotiator` 协商协议

本插件内置了 `WebNavigationNegotiator` 工具类与协商协议标准：

#### 1. 前端实现：挂载 `window.__tryGoBack`
在 Vue/React 路由全局中挂载协商函数：
```javascript
window.__tryGoBack = function () {
  // 如果前端当前不在根路由，由前端内部 router.back() 消费回退
  if (router && router.currentRoute && router.currentRoute.path !== '/') {
    router.back();
    return true; // 告知 Native：前端已消费，不要关闭原生页面！
  }
  return false; // 告知 Native：已在根路由，可以关闭原生容器！
};
```

#### 2. Flutter 原生端：使用 `PopScope` 拦截并协商
```dart
PopScope(
  canPop: false,
  onPopInvokedWithResult: (didPop, result) async {
    if (didPop) return;

    // 优先与 H5 协商回退（内置 500ms 超时保护，防止前端死锁导致返回键卡死）
    final handled = await WebNavigationNegotiator.tryGoBack(
      runJavaScriptReturningResult: (script) async {
        return await webViewController.evaluateJavascript(source: script);
      },
      canGoBackFallback: () async => await webViewController.canGoBack(),
      goBackFallback: () async => await webViewController.goBack(),
    );

    // 如果 H5 和 WebView 历史均无法回退，则安全关闭原生页面
    if (!handled && context.mounted) {
      Navigator.of(context).pop(result);
    }
  },
  child: Scaffold( ... ),
)
```

---

## 4. 第三方支付（Apple Pay / 支付宝 / 微信支付）差异化回调与切后台防杀

在混合开发中，网页呼起支付是一个极为典型、却极其脆弱的交互链路。不同支付渠道的底层机制差异极大：

| 支付渠道 | 呈现形式与交互链路 | 回调接收机制 | 常见致命隐患 |
| :--- | :--- | :--- | :--- |
| **Apple Pay** | **应用内原生授权层**（`PKPaymentAuthorizationViewController` / StoreKit 半屏） | 直接在原生调用 Promise 中返回授权结果 | 弹窗遮盖后手势死锁（需 `EagerGestureRecognizer` 避免） |
| **支付宝** | **跳出至支付宝 App**（`alipays://` Universal Link） | 宿主 App 切后台 -> 返回前台 -> SDK MethodChannel 返回结果 | 切后台期间 WebContent 被系统 Jetsam 杀掉导致切回后白屏 |
| **微信支付** | **跳出至微信 App**（`weixin://` Universal Link） | **异步解耦委托**（通过全局 `WXApiDelegate.onResp` 派发） | 发起支付的方法仅返回“是否唤起成功”，真正支付结果必须通过异步事件推送 |

### 生产级端到端解决方案

#### 1. App 切回前台的白屏探活自愈 (`ensureAlive`)
在 Flutter 宿主页面中绑定 `WidgetsBindingObserver`：
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  // 当用户在支付宝/微信付完切回当前 App 时，触发白屏探活
  if (state == AppLifecycleState.resumed) {
    _controller.ensureAlive();
  }
}
```
`ensureAlive()` 内部通过执行 JS `document.body ? document.body.innerHTML.length : 0`（2 秒超时）探测页面。若探测到长度为 0 或异常，立即自动 `reload()` 自愈，绝不留白屏给用户。

#### 2. 原生通过事件总线向 H5 广播结果
无论是支付宝还是微信支付，支付完成后原生通过 `HostEventBus.emit(controller, 'PAY_RESULT', data)` 定向推给前端。前端在 `window.__AppEventBus.on('PAY_RESULT', ...)` 中局部更新订单状态，**严禁使用强制整页刷新**。

---

## 5. 大文件解压与同步阻塞 UI 主线程掉帧

### 现象描述
在弱网或启动检测到离线大包更新（如 10MB~50MB）时，点击页面动画掉帧甚至出现 ANR 假死。

### 根因与解决方案
1. **必须在独立 Isolate 中解压与校验**：
   `web_payload_manager` 的 `DownloadService` 将 ZIP 解压、逐文件 MD5 循环比对全部放在 `compute(_isolateProcessAndValidate, ...)` 独立 Isolate 中运行，UI 线程 0 阻塞、保持 60/120fps 流畅渲染。
2. **临时目录原子替换（Atomic Swap）**：
   下载解压先在 `.temp` 临时目录进行，只有当 100% 校验成功后才原子重命名替换 `current` 目录。更新中途哪怕断网或强杀进程，本地旧版本资源毫发无损。
3. **初始化非阻塞**：
   `initialize(syncOnStart: true)` 启动时在后台静默发起更新，绝不卡死 App 启动页或主页面初始化。

---

## 6. 本地 Local HTTP Server 端口冲突与自愈

### 现象描述
- App 进入后台时间较长后，系统杀死了端口绑定 socket；
- 或者其他进程占用了端口，导致加载静态资源失败。

### 解决方案
`web_payload_manager` 内置端口健康检测与自愈重连机制：
1. `LocalWebServer` 提供 `checkHealth()` 接口；
2. 当调用 `getModuleStateStream()` 或 App 从前台恢复时，执行 `ensureLocalWebServerHealthy()`；
3. 若发现原端口失效，会自动重启并在失败时自动回退到系统可用端口（`port: 0`），并实时更新资源分发映射，全流程对业务层完全透明。

---

## 7. 架构与安全专题：本地 Localhost 局域网隔离与本机防探测保障

针对本地 Localhost 运行在移动设备上的安全隔离机制说明：

### 1. 局域网物理隔离（100% 免疫外部访问）
* `LocalWebServer` 严格绑定在环回接口 `InternetAddress.loopbackIPv4`（即 `127.0.0.1`）；
* 在操作系统 TCP/IP 协议栈中，物理网卡（Wi-Fi / 蜂窝数据）接收到的外部数据包绝不可能路由至 `lo0` 环回接口，局域网内的任何其他设备绝对无法访问或探测该服务。

### 2. 本机流氓 App 端口扫描的四重防护体系
虽然本机不同 App 共享同一个环回网络命名空间，但我们实施了以下严密的防范体系：
1. **动态随机高位端口**：启动时使用 `port: 0` 让系统内核在 40000~65000 范围动态分配随机端口，消除固定端口特征；
2. **256 位高熵加密 Token 强鉴权**：启动时由 `Random.secure()` 生成 32 字节密码学 Token。缺少该 Token 的请求直接返回 401 拦截；
3. **Host Header 防 DNS 重绑定**：校验 `host` 头部必须为 `127.0.0.1` 或 `localhost`，阻断跨站请求；
4. **401/403 脱敏与静默拦截**：鉴权失败时不返回任何包含系统指纹或 JSON 特征的信息，让外部端口扫描工具无法识别服务类型；
5. **路径规范化与白名单**：杜绝 `../../` 路径穿越，仅允许提供受限的静态 Web 资源文件扩展名。

### 3. 持久化存储与容灾回滚
* 资源包解压存储已从易受系统低空间清理影响的 `CacheDirectory` 迁移至安全的 `ApplicationSupportDirectory`；
* 内置 `rollbackToDefault()` 容灾机制：当新版本资源在运行时发生异常时，可一键或自动回退至随 App 打包的稳定 `default/` 底包。
