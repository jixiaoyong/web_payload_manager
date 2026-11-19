# 集成指南

本插件只负责 **Web 资源管理**；`example/lib/host/` 提供的是 **可选宿主参考实现**（演示用通道，可按需裁剪），不是插件 API，也不是接入本插件的必选项。

## 5 分钟跑通

### 1. 启动本地 mock 更新服务

在项目根目录执行：

```bash
flutter pub get
./tool/bin/server.sh --build
```

服务默认监听 `http://127.0.0.1:8080`，提供 `/check-update` 与 zip 下载。更多参数见 [../tool/README.md](../tool/README.md)。

### 2. 运行 Example

```bash
cd example
flutter pub get
flutter run --dart-define=UPDATE_URL=http://127.0.0.1:8080/check-update
```

未配置真实更新地址时，Example 使用占位 URL（`https://example.com/check-update`），**仅加载 App 内置资源**。也可在面板保存局域网地址后重启 App。

默认选择模块 `module_one`（含 JS Bridge 演示按钮），用于验证资源更新、本地 URL、UA 鉴权与 Bridge。

### 3. 自定义更新地址

```bash
flutter run --dart-define=UPDATE_URL=http://192.168.x.x:8080/check-update
```

面板保存地址后会弹出重启确认；确认后将重新初始化插件并刷新首页。

## 架构分层

```
lib/（插件）
  ├── 版本检测 / 下载 / 本地 HTTP / UA 鉴权
  ├── payloadSyncState / payloadSyncStateStream
  ├── reLoad() / cancelAllDownloads()
  └── getModuleStateStream(key) → Data(url)

example/lib/payload/（Example 默认路径）
  ├── ModuleLoaderPage       版本面板、同步/取消下载、打开 WebView
  └── PayloadModuleController

example/lib/host/（可选宿主参考）
  ├── WebHostController / WebHostWidget   WebView + Bridge 注入
  ├── JsChannelAdapter                    callHandler + __BRIDGE_META__
  ├── HostEventBus                        App → H5 事件
  └── demo_channels.dart                  演示通道（可替换）
```

## 复制到你的 App

推荐先按“最小接入”完成插件集成；只有当你也需要 WebView / Bridge 样板时，再复用 `example/lib/host/`。

### 最小接入（推荐）

1. **初始化插件**（App 启动处）

```dart
await WebPayloadManager.getInstance().initialize(
  updateUrl: 'https://your-api/check-update',
  webAssetBaseDir: 'assets/web_modules',
  syncOnStart: true,
  syncOnEachModuleStart: false,
);
```

2. **监听资源包同步状态**（可选）

```dart
WebPayloadManager.getInstance().payloadSyncStateStream.listen((state) {
  // SyncChecking / SyncDownloading / SyncCompleted / SyncFailed ...
});
```

3. **监听模块状态**

```dart
WebPayloadManager.getInstance()
    .getModuleStateStream('your_module_key')
    .listen((state) { /* Loading / Data / Error */ });
```

4. **拿到 `Data(url)` 后，用你自己的 WebView 打开这个 URL**

5. **User-Agent（必须）**

```dart
final ua = '${platformDefaultUa} YourAppId ${manager.getAuthUserAgent()}';
```

6. **手动同步 / 取消下载**（可选）

```dart
await WebPayloadManager.getInstance().reLoad();
await WebPayloadManager.getInstance().cancelAllDownloads();
```

7. **App 恢复前台**

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    WebPayloadManager.getInstance().ensureLocalWebServerHealthy();
  }
}
```

## 可选：复用 Example 宿主参考

可拷贝 `example/lib/host/` 与 `payload_module_controller.dart`，替换 demo 通道为你自己的 handler。若只需要资源更新 + 本地 URL + 鉴权，不必复制 Bridge 部分。

## Example 演示的能力

| 能力            | 说明                                                      |
| --------------- | --------------------------------------------------------- |
| 资源热更新      | mock server → 下载 zip → 本地 HTTP 加载                   |
| 版本对比        | 内置 / 离线 / 远程版本 + 「检查版本」                     |
| 手动同步        | `reLoad()` + 「立即同步」                                 |
| 取消下载        | `cancelAllDownloads()` + 「取消下载」                     |
| 同步状态流      | `payloadSyncStateStream` 驱动面板进度                     |
| 远程失败回退    | 未配置或 mock 不可达时仍用内置/离线资源                   |
| UA 鉴权         | `getAuthUserAgent()` 拼接到 WebView                       |
| 多模块          | `module_one` / `module_two` 下拉选择                      |
| H5 → App Bridge | `module_one` 按钮调用 DemoEcho / DemoHostInfo / DemoToast |
| App → H5 事件   | WebView 页「推送演示事件」→ `HostEventBus`                |
| Bridge 失败重试 | WebView 遮罩 + `retryBridge()`                            |

## 演示通道（Example 内置）

| 通道            | 作用                      |
| --------------- | ------------------------- |
| `DemoEcho`      | 回显 H5 传入数据          |
| `DemoHostInfo`  | 返回 platform / hostAppId |
| `DemoToast`     | 宿主 SnackBar             |
| `DemoClosePage` | 关闭当前页                |
| `AppBridgeMeta` | 返回通道元数据            |

## 平台配置

### Android

`example/android/app/src/main/res/xml/network_security_config.xml` 已允许 `localhost` / `127.0.0.1` / `10.0.2.2` 明文 HTTP。真机联调需为局域网 IP 增加配置；**模拟器访问宿主机 mock 请用 `10.0.2.2`**。

### iOS

`example/ios/Runner/Info.plist` 已为 `localhost` / `127.0.0.1` 配置 ATS 例外。真机调试若 mock server 在局域网 IP，需临时增加 ATS 例外（仅开发环境）。
