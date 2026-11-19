# 本地 mock 工具

一套自包含的本地开发环境，用于演示 `web_payload_manager` 的完整链路。

**依赖**：Flutter SDK 自带的 `dart`（开发本插件时已安装，**无需 Python**）。启动脚本会按顺序选用：`fvm dart` → Flutter 同目录 `dart` → 系统 `PATH` 中的 `dart`。

## 目录说明

| 路径              | 说明                                                 |
| ----------------- | ---------------------------------------------------- |
| `mock_assets/`    | 演示用 Web 资源源文件                                |
| `pubspec.yaml`    | tool 独立 Dart 包（与插件主包依赖隔离）              |
| `bin/server.dart` | 构建与服务核心逻辑                                   |
| `bin/server.sh`   | macOS / Linux 启动脚本                               |
| `bin/server.bat`  | Windows 启动脚本                                     |
| `dist/`           | 构建产物（`payload_v*.zip`、`server_manifest.json`） |

## 使用方法

在项目根目录执行：

```bash
# macOS / Linux
./tool/bin/server.sh --build

# Windows
tool\bin\server.bat --build
```

常用参数：

```bash
./tool/bin/server.sh              # 按需自动构建后启动
./tool/bin/server.sh --build      # 强制构建后启动
./tool/bin/server.sh --build-only # 仅构建
./tool/bin/server.sh --help
```

构建完成后自动 **清理旧 zip，仅保留最新 5 个**。

## 启动日志

服务启动后会打印**完整 URL**（可直接复制到 Example 的 `UPDATE_URL`），例如：

```text
检查更新（本机）:
  http://127.0.0.1:8080/check-update
局域网（真机调试）:
  检查更新: http://192.168.x.x:8080/check-update
Example 可设置:
  --dart-define=UPDATE_URL=http://192.168.x.x:8080/check-update
```

默认端口 **8080**；被占用时自动尝试后续端口。

## 运行 Example

```bash
# 终端 1（项目根目录）
./tool/bin/server.sh --build

# 终端 2 — 地址以终端 1 打印的为准
cd example
flutter run --dart-define=UPDATE_URL=http://127.0.0.1:8080/check-update
```

Android 模拟器访问宿主机请用终端打印的 `http://10.0.2.2:<port>/check-update`。
