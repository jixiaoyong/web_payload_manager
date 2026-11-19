/// 打开模块 WebView 时携带的运行时上下文，供详情面板展示。
class ModuleRuntimeDetail {
  const ModuleRuntimeDetail({
    required this.moduleKey,
    required this.moduleLabel,
    required this.localUrl,
    required this.authUserAgent,
    required this.updateUrl,
    required this.resolveStatusLabel,
    this.activeVersion,
    this.activeBuildLabel,
    this.activeSource,
    this.remoteVersion,
    this.remoteBuildLabel,
    this.payloadSyncStatusLabel,
  });

  final String moduleKey;
  final String moduleLabel;
  final String localUrl;
  final String authUserAgent;
  final String updateUrl;
  final String resolveStatusLabel;
  final int? activeVersion;
  final String? activeBuildLabel;
  final String? activeSource;
  final int? remoteVersion;
  final String? remoteBuildLabel;
  final String? payloadSyncStatusLabel;
}
