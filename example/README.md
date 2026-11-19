# web_payload_manager_example

`web_payload_manager` 的能力展示型 Example：资源更新面板、多模块本地 URL、WebView 与 JS Bridge 演示。

## 快速开始

```bash
# 终端 1：项目根目录
./tool/bin/server.sh --build

# 终端 2
flutter pub get
flutter run --dart-define=UPDATE_URL=http://127.0.0.1:8080/check-update
```

未配置真实更新地址时，使用占位 URL，仅加载 **内置资源**。

- **module_one**：静态页 + H5 Bridge 按钮（DemoEcho / DemoHostInfo / DemoToast）
- **module_two**：第二个静态模块

首页下拉选择模块和 **WebView 引擎**（`flutter_inappwebview` / `webview_flutter`），点击 **打开模块页面**。WebView 右上角可 **推送演示事件**（App → H5）。

两套插件仅在 `host/web_host_widget.dart` 内实现，业务依赖最小 `WebViewPort`；核心包不依赖任何 WebView 插件。Bridge 共用 JSON 信封（`channel` / `callbackId` / `documentId` / `data`），Dart 主动执行 JS 回传，保持旧页面双 JSON 回调兼容；推荐监听 `payloadBridgeReady`，旧 `flutterInAppWebViewPlatformReady` 事件仍保留。H5 调用 35 秒超时，Dart 业务 30 秒超时并回传错误。鉴权 UA 在首次加载前设置到 WebView 本身，因此子资源也携带 token。

新增原生插件后须完整重新构建（不能仅 hot reload）：iOS 在 `example/ios` 执行 `pod install`，再从 `example` 执行 `flutter run`。两套 iOS 配置均允许行内/免手势媒体播放、禁用历史侧滑、仅 Debug 开启检查，并处理 WebContent 进程终止重载。Android 均禁用缩放、允许混合内容、免手势媒体播放并采用 Hybrid Composition。

## Android 构建与环境说明

工程使用 Gradle 9.3.1、AGP 9.1.1、Kotlin 2.4.10，标准编译环境为 **Java 17 (LTS)**。

从 `example` 目录执行标准构建：
```bash
flutter build apk --debug
```

- **JDK 17 配置**：请确保系统环境变量 `JAVA_HOME` 指向 JDK 17，或在全局 `~/.gradle/gradle.properties` 中指定。项目内不硬编码个人机器路径，确保在 CI 及不同平台无缝兼容。
- **AGP 9 兼容性**：项目在 `example/android/build.gradle` 中内置了针对老版插件的轻量自愈规则，保持 100% 外部纯净依赖，无需本地拷贝插件源码。
- **详细构建指南**：参见 [android/README.md](android/README.md)。

## 更新地址

| 方式                           | 说明                              |
| ------------------------------ | --------------------------------- |
| `--dart-define=UPDATE_URL=...` | 编译时传入（真实地址优先）        |
| 面板「保存地址」               | 写入缓存，**完全重启 App** 后生效 |
| 占位 URL                       | 不请求远程、不同步，仅用内置资源  |

真机联调 mock 服务示例：

```bash
flutter run --dart-define=UPDATE_URL=http://192.168.x.x:8080/check-update
```

Android 模拟器访问宿主机请使用 `10.0.2.2` 而非 `127.0.0.1`。

## 目录结构

```
lib/
├── config/           # dart-define / 默认配置
├── payload/          # 插件能力展示（默认路径）
└── host/             # 可选 WebView / Bridge 参考
```

## 测试

```bash
flutter test
```

集成测试（需连接设备或模拟器）：

```bash
flutter test integration_test/app_test.dart
```

## 相关文档

- [插件 README](../README.md)
- [集成指南](../doc/integration.zh-CN.md)
- [mock 工具](../tool/README.md)
