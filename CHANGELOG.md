## 0.1.0

- 加固下载与更新链路：支持断点续传、指数退避重试（`retryDelayMs`）、HTTPS 校验及不可变快照前缀（`activateAvailableUpdate()` 安全激活）
- 升级 `archive` 至 `^4.7.1`，严格校验 ZIP 解压条目数、体积上限、路径穿越与文件级 MD5 清单
- 支持 `hostAppVersion` 与远端 `minAppVersion` 宿主兼容性校验，支持空 `updateUrl` 纯内置离线模式
- 兼容字符串与整型模块版本号（`Modules.versionStr` / `Modules.version`），提升 `version.json` 解析容错性
- 移除无用的 Android/iOS 原生插件空壳，转为纯 Flutter Package，天然兼容 iOS Swift Package Manager 与新版 Android Gradle
- 规范开源与发布目录结构：文档目录重命名为 `doc/`，新增 `.pubignore` 排除本地开发调试工具

## 0.0.1

- 初始发布：Web 资源版本检查、zip 下载校验、本地 HTTP 服务与 User-Agent 鉴权
- 提供自包含 Example，含 WebView 宿主与 JS Bridge 演示
- 提供本地 mock 资源构建与更新服务（`tool/`）
- 补充插件单测、Example 测试与集成文档
