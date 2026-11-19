# web_payload_manager

[English](README.md) | 简体中文

[![Flutter 3.x](https://img.shields.io/badge/Flutter-3.x-blue.svg)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

开箱即用、完全解耦的开源级 **Flutter 内嵌 H5 离线包动态热更新与本地容器管理系统**。

专为解决 Hybrid 混合开发中最严苛的性能与稳定性痛点而设计：
1. **本地优先**：优先加载已有离线包，网络更新在后台进行；不保证业务页面不存在白屏或运行时异常；
2. **本地静态托管**：内置环回 HTTP 服务，不是远程代理，不能绕过 CORS；跨域 API 仍需后端允许本地页面 Origin。SPA 推荐 hash 路由，不提供 history 路由回退；
3. **后台解压校验**：ZIP 解压与包内逐文件 MD5 校验在 Isolate 执行；下载、快照创建及整包摘要仍有 I/O 和 CPU 成本；
4. **失败保留旧包**：临时目录解压校验后通过同文件系统重命名替换；最终替换失败时尝试恢复备份，但不承诺断电/进程被杀时的事务持久性；
5. **解耦通用化**：支持任意静态托管（GitHub Pages / OSS / S3）的 `version.json` 根对象，也完美向后兼容企业级 `{code: 0, data: {...}}` 业务回包；
6. **宿主集成示例**：Example 展示 WebContent 终止回调重载、手势配置与 SPA 返回协商；这些 WebView 行为需要宿主显式接入，并非管理器自动提供。

---

## 目录
- [架构特性](#架构特性)
- [快速开始](#快速开始)
- [版本检测与静态契约规范](#版本检测与静态契约规范)
- [SPA 返回键双向协商协议 (Back Navigation)](#spa-返回键双向协商协议-back-navigation)
- [iOS 避坑与稳定性保障](#ios-避坑与稳定性保障)
- [开箱即用 UI 构建器 (WebPayloadBuilder)](#开箱即用-ui-构建器-webpayloadbuilder)
- [平台安全配置](#平台安全配置)
- [Example 与本地联调](#example-与本地联调)
- [相关文档](#相关文档)

---

## 架构特性

```text
┌────────────────────────────────────────────────────────┐
│                   Flutter Host App                     │
├──────────────────────────┬─────────────────────────────┤
│  WebPayloadBuilder       │  WebNavigationNegotiator    │
│  (Loading / Data / Error)│  (window.__tryGoBack 协商)  │
├──────────────────────────┴─────────────────────────────┤
│                 WebPayloadManager (Facade)             │
├──────────────────────────┬─────────────────────────────┤
│   VersionCheckService    │      DownloadService        │
│   (VersionInfoParser)    │  (Isolate 解压 + 原子替换)  │
├──────────────────────────┴─────────────────────────────┤
│             LocalWebServer (127.0.0.1:port)            │
│       流式传输 + ETag 304 + 安全沙盒 + UA 动态鉴权     │
└────────────────────────────────────────────────────────┘
```

---

## 快速开始

### 1. 添加依赖

```yaml
dependencies:
  web_payload_manager: ^0.1.0
```

### 2. 初始化插件

在应用启动时（`main.dart`）初始化管理器：

```dart
import 'package:flutter/widgets.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WebPayloadManager.getInstance().initialize(
    // 远程更新检测清单地址（支持 GitHub Pages、OSS、S3 静态 JSON 或企业后端）
    updateUrl: 'https://jixiaoyong.github.io/web_payload_manager/version.json',
    // 本地内置兜底离线包的 assets 目录路径
    webAssetBaseDir: 'assets/web_modules',
    // 启动时后台静默同步（不阻塞主流程）
    syncOnStart: true,
  );

  runApp(const MyApp());
}
```

### 3. 获取模块本地 URL 并加载

```dart
final stream = WebPayloadManager.getInstance().getModuleStateStream('module_one');

stream.listen((state) {
  switch (state) {
    case Loading(:final progress):
      debugPrint('下载解压进度: ${(progress != null ? progress * 100 : 0).toStringAsFixed(0)}%');
    case Data(:final data):
      debugPrint('模块就绪，本地 HTTP 地址: $data');
    case Error(:final message):
      debugPrint('加载失败，可提示重试: $message');
  }
});
```

### 更新与激活契约

- 根包与 tool 使用 `archive: ^4.7.1`，不使用 archive override；解压使用严格模式并读取每个普通文件，触发惰性 CRC 和实际尺寸检查。
- `initialize(updateUrl: '', syncOnStart: false, syncOnEachModuleStart: false, ...)` 支持纯内置模式，订阅及手动 `reLoad()` 均不请求远端。
- 管理器依赖 `dart:io`，不支持 Flutter Web；多平台宿主应条件导入。平台插件声明不等于已验证所有桌面或其他平台。
- `initialize(hostAppVersion: '1.2.0', ...)` 显式提供宿主版本。远端声明 `minAppVersion` 时，缺少宿主版本或版本不足会拒绝更新并保留旧包；`forceUpdate` 仅为元数据，不强制阻塞旧页面。
- 模块首先派发本地 `Data`，后台进度只通过 `payloadSyncStateStream` 发布，不把已有页面切成 Loading。`SyncCompleted` 表示校验并安装就绪，`availableVersion` 给出版本；宿主在安全时机调用 `activateAvailableUpdate()`，根据新 `Data.data` 重载 WebView。`Data.version` 为会话版本。
- 每个 URL 带不可变快照前缀；旧 URL 不切根。前端资源必须使用相对路径（不使用 `/assets/...` 等站点根绝对路径），否则无法保证会话版本一致。快照暂保留在应用支持目录，宿主应控制更新频率与磁盘空间。
- 服务恢复导致端口或 Token 变化时会重新派发 `Data`，宿主应重新读取 `getAuthUserAgent()` 并更新 WebView UA 与 URL。
- 更新清单与包地址要求 HTTPS（本机 loopback HTTP 仅用于开发），宿主必须信任清单和下载源。MD5 仅用于传输完整性，不是签名或来源认证。清单有 `md5` 时验证整包；包内版本必须与远端完全相同。
- 旧包可省略文件清单和 MD5；声明文件清单时必须完整列出除根 `version.json` 外的所有文件，声明的模块入口必须存在。默认限制 ZIP 64 MiB、10000 条目、解压总量 256 MiB、单文件 64 MiB，拒绝链接、特殊类型和不安全路径。

### 4. WebView 鉴权 User-Agent（重要）

为防止本地端口被本机其他未经授权的应用探测，本地 HTTP 服务受动态 Token 保护。请将鉴权 UA 拼入 WebView 中：

```dart
final manager = WebPayloadManager.getInstance();
final authUserAgent = manager.getAuthUserAgent(); // e.g. "WebPayloadManager/{token}"
final userAgent = 'YourApp/1.0.0 $authUserAgent';
```

---

## 版本检测与静态契约规范

### 1. 标准通用静态清单 (`version.json`)
任何开发者只要将打包后的静态 ZIP 和如下 `version.json` 丢到 GitHub Pages、OSS 或 S3 上即可完成热更新部署：

```json
{
  "version": "1.2.0",
  "downloadUrl": "https://cdn.example.com/bundles/finance_report_1.2.0.zip",
  "md5": "e10adc3949ba59abbe56e057f20f883e",
  "buildLabel": "v1.2.0-prod",
  "minAppVersion": "1.0.0",
  "forceUpdate": false,
  "description": "2026 Q4 优化离线加载速度"
}
```

- 版本号支持**语义化版本（SemVer，如 `1.2.0 > 1.1.9`）**以及**时间戳/整型递增（如 `1792649467655`）**；
- 下载地址字段自适应识别 `downloadUrl`、`zipUrl` 或 `url`。

### 2. 企业业务回包与自定义适配器
如果公司服务端统一封装了 `{ code: 0, msg: "...", data: { ... } }`，无需修改任何代码，插件默认的 `StandardVersionParser` 会**自动识别并解包**：

```dart
// 若公司有特殊的签名加密或特殊协议，可传入自定义解析器：
await WebPayloadManager.getInstance().initialize(
  updateUrl: 'https://api.company.com/v1/h5/latest',
  webAssetBaseDir: 'assets/web_modules',
  versionParser: CustomVersionParser((raw) {
    final map = raw as Map<String, dynamic>;
    return WebVersionInfoBean(
      versionStr: map['payload_version'],
      zipUrl: map['cdn_url'],
      md5: map['checksum'],
    );
  }),
);
```

---

## SPA 返回键双向协商协议 (Back Navigation)

解决单页应用（Vue/React Router）在混合开发中按返回键“直接误关闭原生容器”或“无法退出死循环”的痛点：

### 1. 前端 H5 注册协商函数
```javascript
// 在 Vue/React 路由全局中挂载
window.__tryGoBack = function () {
  // 如果前端处于子路由状态，由前端路由内部返回
  if (router && router.currentRoute && router.currentRoute.path !== '/') {
    router.back();
    return true; // 告知 Flutter：前端已消费返回事件，不要退出原生页面！
  }
  return false; // 告知 Flutter：已在根路由，可以退出原生容器！
};
```

### 2. Flutter 原生端使用 `WebNavigationNegotiator`
```dart
PopScope(
  canPop: false,
  onPopInvokedWithResult: (didPop, result) async {
    if (didPop) return;

    // 优先与 H5 协商（带 500ms 超时保护，防 JS 异常卡死返回键）
    final handled = await WebNavigationNegotiator.tryGoBack(
      runJavaScriptReturningResult: (script) async {
        return await webViewController.evaluateJavascript(source: script);
      },
      canGoBackFallback: () async => await webViewController.canGoBack(),
      goBackFallback: () async => await webViewController.goBack(),
    );

    if (!handled && context.mounted) {
      Navigator.of(context).pop(result);
    }
  },
  child: Scaffold( ... ),
)
```

---

## iOS 避坑与稳定性保障

详细排查历程与技术实现请阅读专著：**[`doc/ios_troubleshooting.zh-CN.md`](doc/ios_troubleshooting.zh-CN.md)**。

1. **WebContent 内存被杀 (Jetsam) 导致永久白屏**：
   WebKit 的 WebContent 是独立进程，在 iOS 低内存压力下常被系统静默杀死。在 WebView 中接入 `onWebContentProcessDidTerminate: (controller) => controller.reload()` 可尝试恢复；持续崩溃时仍应提供重试/降级 UI。
2. **原生 Modal 弹窗遮盖后手势完全锁死**：
   坚决不要在 WebView 根树上套全局 `PointerInterceptor`；给 WebView 绑定 `EagerGestureRecognizer` 确保其手势优先权。
3. **大文件流式传输**：
   本地服务使用 `File.openRead().pipe(response)` 替代一次性读取，大幅降低运行时内存峰值。

---

## 开箱即用 UI 构建器 (WebPayloadBuilder)

```dart
WebPayloadBuilder(
  moduleKey: 'module_one',
  builder: (context, localUrl) {
    // 资源就绪，直接将 localUrl 传递给 InAppWebView 或 WebViewWidget
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(localUrl)),
      initialSettings: InAppWebViewSettings(
        userAgent: '$myAppUa ${WebPayloadManager.getInstance().getAuthUserAgent()}',
      ),
      onWebContentProcessDidTerminate: (c) => c.reload(),
    );
  },
  loadingBuilder: (context, progress, currentBytes) {
    return Center(child: CircularProgressIndicator(value: progress));
  },
  errorBuilder: (context, message, severity, onRetry) {
    return Center(
      child: Column(
        children: [
          Text('加载失败: $message'),
          ElevatedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  },
)
```

---

## 平台安全配置

### Android
在 `android/app/src/main/res/xml/network_security_config.xml` 中放行本地环回地址：
```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">127.0.0.1</domain>
        <domain includeSubdomains="true">localhost</domain>
    </domain-config>
</network-security-config>
```

### iOS
在 `Info.plist` 中允许 `127.0.0.1` 与 `localhost` 本地 HTTP 访问：
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>127.0.0.1</key>
    <dict>
      <key>NSIncludesSubdomains</key><true/>
      <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
    </dict>
    <key>localhost</key>
    <dict>
      <key>NSIncludesSubdomains</key><true/>
      <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
    </dict>
  </dict>
</dict>
```

---

## Example 与本地联调

本项目配有高保真 Example 演示工程，覆盖多模块切换、版本检测面板、断点续传、JSBridge 通信、原生弹窗防死锁与返回键拦截。

```bash
cd example
flutter pub get
flutter run
```

---

## 相关文档
- [集成指南与最小接入规范](doc/integration.zh-CN.md)
- [iOS Hybrid 混合开发避坑宝典](doc/ios_troubleshooting.zh-CN.md)
- [架构设计思路与设计边界](doc/architecture.zh-CN.md)
- [本地 Mock 调试工具使用说明](https://github.com/jixiaoyong/web_payload_manager/blob/master/tool/README.md)
