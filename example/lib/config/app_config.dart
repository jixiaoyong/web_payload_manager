/// Example 应用配置（可通过 --dart-define 覆盖）。
class AppConfig {
  AppConfig._();

  /// 占位更新地址：未配置真实地址时仅使用 App 内置资源，不发起远程同步。
  static const String placeholderUpdateUrl = 'https://example.com/check-update';

  /// 远程更新检测地址（可被用户修改并缓存，重启后生效）。
  static const String defaultUpdateUrl = String.fromEnvironment(
    'UPDATE_URL',
    defaultValue: placeholderUpdateUrl,
  );

  static const String cachedUpdateUrlKey = 'example.cached_update_url';

  /// 写入 User-Agent 的宿主标识，便于 H5 识别运行环境。
  static const String hostAppId = String.fromEnvironment(
    'HOST_APP_ID',
    defaultValue: 'web_payload_example',
  );

  static const String webAssetBaseDir = 'assets/web_modules';

  static const List<ModuleOption> moduleOptions = [
    ModuleOption(key: 'module_one', label: '模块一'),
    ModuleOption(key: 'module_two', label: '模块二'),
  ];

  static const String defaultModuleKey = 'module_one';

  /// 是否为已配置的真实更新地址（非占位 URL）。
  static bool isRemoteUpdateConfigured(String url) {
    final trimmed = url.trim();
    return trimmed.isNotEmpty && trimmed != placeholderUpdateUrl;
  }
}

class ModuleOption {
  const ModuleOption({required this.key, required this.label});

  final String key;
  final String label;
}
