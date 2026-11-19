# 设计思路

本文档记录 `web_payload_manager` 的核心设计目标，供维护者理解实现边界。

## 目标

插件聚焦于 **Web 资源管理**，不包含宿主 App 的通道注册、用户会话、支付或统计等能力。

职责包括：

- 检查远端资源版本
- 下载 zip 并校验完整性
- 将内置资源同步到默认目录作为兜底
- 通过本地 HTTP 服务提供静态资源访问
- 通过 User-Agent token 对资源请求做轻量鉴权
- 在 App 恢复前台时做服务自愈

## 分层

### 插件层：`lib/`

- `web_payload_manager.dart`：对外 Facade
- `version_check_service.dart`：版本检查
- `download_service.dart`：下载 / 解压 / 校验 / 切换
- `local_web_server.dart`：本地 HTTP 服务与访问控制
- `file_path_utility.dart`：目录与缓存路径管理

### 示例宿主层：`example/lib/host/`（可选参考）

这部分不是插件 API，而是 **可按需裁剪的宿主参考**：

- `WebHostWidget` / `WebHostController`：WebView 容器与 Bridge 注入
- JS Bridge transport（`JsChannelAdapter`）
- Bridge 元数据注入（`__BRIDGE_META__`）
- App → H5 事件总线（`HostEventBus`）

Example 在 `MinimalWebViewPage` 中接入上述能力，并配合 `module_one` 的 H5 按钮演示 Bridge。

## 为什么宿主层留在 example

宿主层通常会随集成方的页面栈、路由、UI、Bridge 协议而定制，不适合作为独立插件强行抽象成通用 API。

因此当前策略是：

- 插件只做资源管理能力
- 可复制宿主模式放在 example
- 集成方按需要裁剪 `example/lib/host/`

## 仓库定位

本仓库文档与 example 应可独立阅读与运行，不依赖其他私有仓库上下文。
