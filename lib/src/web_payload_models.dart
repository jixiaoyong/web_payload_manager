/// 单个 H5 模块的加载状态机（密封类）。
sealed class ResourceState {
  /// 加载中状态，包含可选下载进度与已接收字节数。
  const factory ResourceState.loading({
    double? progress,
    int? currentBytes,
  }) = Loading;

  /// 就绪状态，包含本地不可变会话 HTTP URL 及当前包版本号。
  const factory ResourceState.data(String data, {String? version}) = Data;

  /// 错误状态，包含可读错误信息与严重程度。
  const factory ResourceState.error({
    required String message,
    required ErrorSeverity severity,
  }) = Error;
}

/// 模块加载中状态。
final class Loading implements ResourceState {
  /// 进度百分比（`0.0` 到 `1.0`），未知时为空。
  final double? progress;

  /// 当前已下载字节数。
  final int? currentBytes;

  /// 创建加载中状态。
  const Loading({
    this.progress,
    this.currentBytes,
  });
}

/// 模块资源就绪状态。
final class Data implements ResourceState {
  /// 本地 HTTP 服务提供的不可变会话入口 URL。
  final String data;

  /// 当前会话绑定的资源包版本。
  final String? version;

  /// [data] 是不可变会话 URL；[version] 是其包版本，可为空以兼容旧调用。
  const Data(this.data, {this.version});
}

/// 模块加载失败状态。
final class Error implements ResourceState {
  /// 错误提示描述。
  final String message;

  /// 错误严重程度级别。
  final ErrorSeverity severity;

  /// 创建错误状态。
  const Error({
    required this.message,
    required this.severity,
  });
}

// ============ Error Severity ============

/// 错误严重程度分级。
enum ErrorSeverity {
  /// 网络错误、超时等临时异常，支持重试。
  recoverable,

  /// 清单或文件 MD5 校验失败，通常会回退至内置包。
  validation,

  /// 磁盘满、权限不足等严重底层故障。
  critical,
}

// ============ Global Payload Sync State ============

/// 全局资源包同步状态（与单个模块加载状态 [ResourceState] 独立）。
sealed class PayloadSyncState {
  /// 创建同步状态基类。
  const PayloadSyncState();

  /// 空闲状态。
  const factory PayloadSyncState.idle() = SyncIdle;

  /// 正在检查远端新版本。
  const factory PayloadSyncState.checking() = SyncChecking;

  /// 正在后台下载或解压校验新版本离线包。
  const factory PayloadSyncState.downloading({
    double? progress,
    int? currentBytes,
  }) = SyncDownloading;

  /// 本地已是最新版本，无需下载。
  const factory PayloadSyncState.upToDate() = SyncUpToDate;

  /// 新版本已下载并校验就绪，等待宿主显式调用激活。
  const factory PayloadSyncState.completed() = SyncCompleted;

  /// 后台同步失败，不影响当前正在运行的本地旧包。
  const factory PayloadSyncState.failed({required String message}) = SyncFailed;
}

/// 全局同步空闲状态。
final class SyncIdle implements PayloadSyncState {
  /// 创建空闲状态。
  const SyncIdle();
}

/// 正在请求远端检查更新状态。
final class SyncChecking implements PayloadSyncState {
  /// 创建检查更新状态。
  const SyncChecking();
}

/// 正在后台下载新版本离线包状态。
final class SyncDownloading implements PayloadSyncState {
  /// 下载进度（`0.0` 到 `1.0`）。
  final double? progress;

  /// 已下载字节数。
  final int? currentBytes;

  /// 创建下载中状态。
  const SyncDownloading({this.progress, this.currentBytes});
}

/// 本地已是最新版本状态。
final class SyncUpToDate implements PayloadSyncState {
  /// 创建已是最新状态。
  const SyncUpToDate();
}

/// 新版本下载校验完成、等待激活状态。
final class SyncCompleted implements PayloadSyncState {
  /// 创建同步完成状态。
  const SyncCompleted();
}

/// 后台同步失败状态。
final class SyncFailed implements PayloadSyncState {
  /// 失败原因描述。
  final String message;

  /// 创建同步失败状态。
  const SyncFailed({required this.message});
}

// ============ Web Module Metadata ============

/// 后台服务器版本信息
class WebVersionInfoBean {
  String? zipUrl;
  int? version;
  String? versionStr;
  String? md5;
  int? timestamp;
  int? fileSize;
  String? description;
  String? buildLabel;
  String? minAppVersion;
  bool? forceUpdate;
  String? entryFile;
  String? moduleKey;
  Map<String, dynamic>? extra;

  WebVersionInfoBean({
    this.zipUrl,
    this.version,
    this.versionStr,
    this.md5,
    this.timestamp,
    this.fileSize,
    this.description,
    this.buildLabel,
    this.minAppVersion,
    this.forceUpdate,
    this.entryFile,
    this.moduleKey,
    this.extra,
  });

  /// 兼容开源标准命名 downloadUrl
  String? get downloadUrl => zipUrl;
  set downloadUrl(String? val) => zipUrl = val;

  /// 获取用于比对的版本标识（优先返回 versionStr，否则返回 version 字符串）
  String get effectiveVersionStr =>
      versionStr ?? (version != null ? version.toString() : '');

  WebVersionInfoBean.fromJson(Map<String, dynamic> json) {
    zipUrl = json['zipUrl'] ?? json['downloadUrl'] ?? json['url'];
    final rawVersion = json['version'];
    if (rawVersion is int) {
      version = rawVersion;
      versionStr = rawVersion.toString();
    } else if (rawVersion != null) {
      versionStr = rawVersion.toString();
      version = int.tryParse(versionStr!);
    }
    if (json['versionStr'] != null) {
      versionStr = json['versionStr'].toString();
    }

    md5 = json['md5'];
    timestamp = json['timestamp'];
    fileSize = json['fileSize'] ?? json['size'];
    description = json['description'] ?? json['desc'];
    buildLabel = json['buildLabel'];
    minAppVersion = json['minAppVersion'];
    forceUpdate = json['forceUpdate'] == true;
    entryFile = json['entryFile'] ?? json['entryHtml'];
    moduleKey = json['moduleKey'] ?? json['key'];

    final knownKeys = {
      'zipUrl',
      'downloadUrl',
      'url',
      'version',
      'versionStr',
      'md5',
      'timestamp',
      'fileSize',
      'size',
      'description',
      'desc',
      'buildLabel',
      'minAppVersion',
      'forceUpdate',
      'entryFile',
      'entryHtml',
      'moduleKey',
      'key',
    };
    final extraMap = <String, dynamic>{};
    json.forEach((k, v) {
      if (!knownKeys.contains(k)) {
        extraMap[k] = v;
      }
    });
    if (extraMap.isNotEmpty) {
      extra = extraMap;
    }
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['zipUrl'] = zipUrl;
    if (downloadUrl != null && downloadUrl != zipUrl) {
      data['downloadUrl'] = downloadUrl;
    }
    data['version'] = version;
    if (versionStr != null) {
      data['versionStr'] = versionStr;
    }
    data['md5'] = md5;
    data['timestamp'] = timestamp;
    data['fileSize'] = fileSize;
    data['description'] = description;
    data['buildLabel'] = buildLabel;
    if (minAppVersion != null) data['minAppVersion'] = minAppVersion;
    if (forceUpdate != null) data['forceUpdate'] = forceUpdate;
    if (entryFile != null) data['entryFile'] = entryFile;
    if (moduleKey != null) data['moduleKey'] = moduleKey;
    if (extra != null) {
      data.addAll(extra!);
    }
    return data;
  }
}

/// 离线包清单中的单个业务模块描述。
class Modules {
  /// 模块展示名称。
  String? name;

  /// 模块唯一标识 Key。
  String? key;

  /// 模块入口 HTML 相对路径（如 `module_one/index.html`）。
  String? entryHtml;

  /// 整型版本号（若为纯数字版本）。
  int? version;

  /// 字符串版本号（兼容 SemVer 与整型字符串）。
  String? versionStr;

  /// 模块功能说明。
  String? description;

  /// 创建模块描述实例。
  Modules({
    this.name,
    this.key,
    this.entryHtml,
    this.version,
    this.versionStr,
    this.description,
  });

  Modules.fromJson(Map<String, dynamic> json) {
    name = json['name'];
    key = json['key'];
    entryHtml = json['entryHtml'];
    final rawVersion = json['version'];
    if (rawVersion is int) {
      version = rawVersion;
      versionStr = rawVersion.toString();
    } else if (rawVersion != null) {
      versionStr = rawVersion.toString();
      version = int.tryParse(versionStr!);
    }
    if (json['versionStr'] != null) {
      versionStr = json['versionStr'].toString();
    }
    description = json['description'];
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['name'] = name;
    data['key'] = key;
    data['entryHtml'] = entryHtml;
    data['version'] = version;
    if (versionStr != null) data['versionStr'] = versionStr;
    data['description'] = description;
    return data;
  }
}

/// zip 文件中的 version.json 文件信息
class VersionJsonBean {
  int? version;
  String? versionStr;
  String? buildLabel;
  WebFileInfo? fileInfo;
  List<Modules>? modules;

  VersionJsonBean({
    this.version,
    this.versionStr,
    this.buildLabel,
    this.fileInfo,
    this.modules,
  });

  /// 获取用于比对的版本标识
  String get effectiveVersionStr =>
      versionStr ?? (version != null ? version.toString() : '');

  VersionJsonBean.fromJson(Map<String, dynamic> json) {
    final rawVersion = json['version'];
    if (rawVersion is int) {
      version = rawVersion;
      versionStr = rawVersion.toString();
    } else if (rawVersion != null) {
      versionStr = rawVersion.toString();
      version = int.tryParse(versionStr!);
    }
    if (json['versionStr'] != null) {
      versionStr = json['versionStr'].toString();
    }

    buildLabel = json['buildLabel'];
    fileInfo = json['fileInfo'] != null
        ? WebFileInfo.fromJson(json['fileInfo'])
        : null;
    if (json['modules'] != null) {
      modules = <Modules>[];
      json['modules'].forEach((v) {
        modules!.add(Modules.fromJson(v));
      });
    }
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['version'] = version;
    if (versionStr != null) {
      data['versionStr'] = versionStr;
    }
    data['buildLabel'] = buildLabel;
    if (fileInfo != null) {
      data['fileInfo'] = fileInfo!.toJson();
    }
    if (modules != null) {
      data['modules'] = modules!.map((v) => v.toJson()).toList();
    }
    return data;
  }
}

/// 离线包内全部受校验文件的清单汇总。
class WebFileInfo {
  /// 清单声明的总文件数。
  int? totalFiles;

  /// 逐文件相对路径与 MD5 列表。
  List<WebAssetFile>? files;

  /// 创建文件清单信息。
  WebFileInfo({this.totalFiles, this.files});

  /// 从 JSON Map 反序列化。
  WebFileInfo.fromJson(Map<String, dynamic> json) {
    totalFiles = json['total_files'];
    if (json['files'] != null) {
      files = <WebAssetFile>[];
      json['files'].forEach((v) {
        files!.add(WebAssetFile.fromJson(v));
      });
    }
  }

  /// 序列化为 JSON Map。
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['total_files'] = totalFiles;
    if (files != null) {
      data['files'] = files!.map((v) => v.toJson()).toList();
    }
    return data;
  }
}

/// 离线包中单个静态资源文件的校验条目。
class WebAssetFile {
  /// 文件相对离线包根目录的路径。
  String? path;

  /// 文件的十六进制 MD5 摘要。
  String? md5;

  /// 创建文件校验条目。
  WebAssetFile({this.path, this.md5});

  /// 从 JSON Map 反序列化。
  WebAssetFile.fromJson(Map<String, dynamic> json) {
    path = json['path'];
    md5 = json['md5'];
  }

  /// 序列化为 JSON Map。
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = <String, dynamic>{};
    data['path'] = path;
    data['md5'] = md5;
    return data;
  }
}

// ============ Metrics ============

/// 单次离线包下载的性能与结果指标。
class DownloadMetric {
  /// 下载开始时间。
  final DateTime startTime;

  /// 累计下载字节数。
  int bytes = 0;

  /// 下载结束时间。
  DateTime? endTime;

  /// 发生的异常（成功时为空）。
  Exception? error;

  /// 创建下载指标对象。
  DownloadMetric({
    required this.startTime,
    required this.bytes,
    this.endTime,
    this.error,
  });

  /// 本次下载总耗时。
  Duration? get duration => endTime?.difference(startTime);

  /// 平均下载速率（字节/秒）。
  double get speedBytesPerSecond {
    final d = duration;
    if (d == null || d.inMilliseconds == 0) return 0;
    return bytes / d.inMilliseconds * 1000;
  }
}
