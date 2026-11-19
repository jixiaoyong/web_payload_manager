# Android 构建配置与兼容性指南

本文档说明 `web_payload_manager_example`（同时集成 `flutter_inappwebview` 与 `webview_flutter`）在 macOS / Linux / Windows 以及 GitHub Actions CI 中的 Android 构建配置要点。

---

## 环境与版本矩阵

| 构件 / 依赖项 | 版本 | 说明 | 配置文件位置 |
| :--- | :--- | :--- | :--- |
| **Flutter SDK** | `3.50.0` | 项目根目录 `.fvmrc` 锁定 | `/.fvmrc` |
| **Gradle Wrapper** | `9.3.1` | 满足新版 Flutter Android 工具链要求 | `gradle/wrapper/gradle-wrapper.properties` |
| **Android Gradle Plugin (AGP)** | `9.1.1` | 配合 Gradle 9.3+ 的官方构建插件 | `settings.gradle` |
| **Kotlin (KGP)** | `2.4.10` | 与 AGP 9.1+ 兼容的 Kotlin 编译器 | `settings.gradle` |
| **Compile SDK / Target SDK** | `flutter.compileSdkVersion` | 随 Flutter 环境动态匹配 | `app/build.gradle` |
| **Min SDK** | `flutter.minSdkVersion` | 随 Flutter 环境动态匹配 | `app/build.gradle` |
| **JDK 版本** | **Java 17+ (LTS)** | Gradle 9 / AGP 9 推荐运行时 | 环境变量 `JAVA_HOME` |

---

## AGP 9 与 `flutter_inappwebview_android` 兼容处理

* **根因**：AGP 9 移除了旧版 `proguard-android.txt`（统一为 `proguard-android-optimize.txt`），而 `flutter_inappwebview_android` 部分版本仍在其 `build.gradle` 中引用 `proguard-android.txt`，导致配置期失败。
* **实现方式**：在 [`example/android/build.gradle`](build.gradle) 的 `subprojects` 块中，构建期自动检测 `flutter_inappwebview_android` 的 `build.gradle` 并将 `proguard-android.txt` 替换为 `proguard-android-optimize.txt`，无需在仓库内 vendor 完整插件源码。

---

## 本地构建规范

1. **JDK 配置**：不要在仓库追踪的 `gradle.properties` 中写死本机绝对路径（例如 `org.gradle.java.home=/Users/...`），请通过环境变量 `JAVA_HOME` 或用户级 `~/.gradle/gradle.properties` 配置。
2. **网络镜像**：仓库默认使用官方 Gradle 与 Maven 源以保证全球开发者和 GitHub Actions 稳定构建；如本地网络受限，可按需通过 `--init-script` 临时注入镜像。

---

## GitHub Actions 构建参考

```yaml
- name: Set up JDK 17
  uses: actions/setup-java@v4
  with:
    java-version: '17'
    distribution: 'zulu'

- name: Set up Flutter
  uses: subosito/flutter-action@v2
  with:
    channel: 'stable'
    cache: true

- name: Build Debug APK
  run: |
    cd example
    flutter pub get
    flutter build apk --debug
```

产物输出路径：`example/build/app/outputs/flutter-apk/app-debug.apk`。
