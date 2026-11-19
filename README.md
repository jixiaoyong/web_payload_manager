# web_payload_manager

[English](README.md) | [简体中文](README.zh-CN.md)

[![Flutter 3.x](https://img.shields.io/badge/Flutter-3.x-blue.svg)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A decoupled, pure Flutter package for **versioned offline web payload management, integrity verification, and local loopback HTTP hosting** for embedded WebViews.

## Highlights

- **Local-First Loading**: Serves bundled or previously verified offline assets immediately while checking for updates in the background without interrupting active pages.
- **Immutable Session Snapshots**: Each module URL is bound to an immutable snapshot prefix. Background updates install safely and emit `SyncCompleted`; hosts explicitly call `activateAvailableUpdate()` at a safe boundary.
- **Hardened Verification & Extraction**: Runs strict ZIP extraction (`archive` 4.x), entry/size limits, path-traversal checks, and file-level MD5 verification in background isolates.
- **Local Loopback HTTP Server**: Serves assets via `127.0.0.1` with streaming I/O, ETag `304`, and dynamic User-Agent token authorization to block unauthorized local processes.
- **Flexible Manifest Compatibility**: Works with static `version.json` files (GitHub Pages / OSS / S3 / Nginx), legacy `{code: 0, data: {...}}` API envelopes, or any `CustomVersionParser`.
- **SPA Back-Navigation Negotiation**: Provides `WebNavigationNegotiator` (`window.__tryGoBack`) with a 500 ms safety timeout to coordinate Flutter `PopScope` with Vue/React/SPA routes.
- **Pure Flutter Package**: No redundant native plugin shell—natively compatible with iOS Swift Package Manager (SPM), CocoaPods, and modern Android Gradle setups.

> Note: `web_payload_manager` relies on `dart:io` (loopback `HttpServer` and local filesystem) and does not support Flutter Web.

## Quick Start

### 1. Add Dependency

```yaml
dependencies:
  web_payload_manager: ^0.1.0
```

### 2. Initialize at App Startup

```dart
import 'package:flutter/widgets.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WebPayloadManager.getInstance().initialize(
    updateUrl: 'https://example.com/payloads/version.json',
    webAssetBaseDir: 'assets/web_modules',
    hostAppVersion: '1.0.0',
    syncOnStart: true,
  );

  runApp(const MyApp());
}
```

Pass `updateUrl: ''` with `syncOnStart: false` for a strictly offline built-in asset mode.

### 3. Subscribe to a Module Stream or Use `WebPayloadBuilder`

```dart
WebPayloadBuilder(
  moduleKey: 'module_one',
  builder: (context, localUrl) {
    final authUa = WebPayloadManager.getInstance().getAuthUserAgent();
    // Pass localUrl and "$yourAppUa $authUa" to webview_flutter or flutter_inappwebview
    return MyWebView(url: localUrl, userAgent: 'MyApp/1.0.0 $authUa');
  },
)
```

### 4. SPA Back Negotiation (`PopScope`)

```dart
final handled = await WebNavigationNegotiator.tryGoBack(
  runJavaScriptReturningResult: (script) => controller.runJavaScriptReturningResult(script),
  canGoBackFallback: controller.canGoBack,
  goBackFallback: controller.goBack,
);
if (!handled && context.mounted) {
  Navigator.of(context).pop();
}
```

## Manifest Contract (`version.json`)

```json
{
  "version": "1.2.0",
  "downloadUrl": "https://cdn.example.com/bundles/app_1.2.0.zip",
  "md5": "e10adc3949ba59abbe56e057f20f883e",
  "buildLabel": "v1.2.0-prod",
  "minAppVersion": "1.0.0",
  "forceUpdate": false,
  "description": "Offline bundle update"
}
```

Both semantic versions (`1.2.0 > 1.1.9`) and integer/timestamp versions (`1792649467655`) are supported.

## Platform Loopback Configuration

Allow clear-text HTTP strictly for loopback hosts (`127.0.0.1` / `localhost`) so the WebView can load assets from the local HTTP server while keeping external traffic HTTPS-only:

- **Android**: Add `network_security_config.xml` permitting cleartext only for `127.0.0.1` and `localhost`.
- **iOS**: Add `NSAppTransportSecurity` exceptions for `127.0.0.1` and `localhost` in `Info.plist`.

## Documentation & Example

- [简体中文完整文档 (README.zh-CN.md)](README.zh-CN.md)
- [Integration Guide (ZH)](doc/integration.zh-CN.md)
- [iOS Hybrid Troubleshooting (ZH)](doc/ios_troubleshooting.zh-CN.md)
- [Architecture Notes (ZH)](doc/architecture.zh-CN.md)
- [Local Mock Server Tooling](https://github.com/jixiaoyong/web_payload_manager/blob/master/tool/README.md)
