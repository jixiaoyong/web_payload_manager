import 'dart:convert';

import 'exception_handler.dart';
import 'web_payload_models.dart';

/// 抽象版本解析器接口
///
/// 允许用户完全解耦服务端数据结构。
/// 无论是纯静态 JSON（GitHub Pages/OSS/S3/Nginx）、
/// 还是传统业务封装（`{code: 0, msg: "...", data: {...}}`），
/// 都可以通过统一的解析器转换为 [WebVersionInfoBean]。
abstract interface class VersionInfoParser {
  /// 将原始响应（`Map<String, dynamic>` 或原始 `String`）解析为 [WebVersionInfoBean]。
  WebVersionInfoBean parse(dynamic raw);
}

/// 标准多模式自适应版本解析器
///
/// 默认解析行为：
/// 1. 若响应包含 `code` 且包含 `data`（Map），按业务 Envelope 协议解析；
///    此时仅当 `code == 0` 或 `code == 200` 时视作成功并读取 `data`。
/// 2. 否则，直接将根对象作为标准静态清单解析（例如托管在 GitHub Pages 或 OSS 的 version.json）。
class StandardVersionParser implements VersionInfoParser {
  const StandardVersionParser();

  @override
  WebVersionInfoBean parse(dynamic raw) {
    Map<String, dynamic> json;
    if (raw is String) {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw ValidationException(
          message: 'Invalid response format: expected JSON Object',
        );
      }
      json = Map<String, dynamic>.from(decoded);
    } else if (raw is Map<String, dynamic>) {
      json = raw;
    } else if (raw is Map) {
      json = Map<String, dynamic>.from(raw);
    } else {
      throw ValidationException(
        message: 'Invalid response format: unexpected type ${raw.runtimeType}',
      );
    }

    // 模式 1: 业务 Envelope 格式 (包含 code 或 data)
    final hasCode = json.containsKey('code');
    final hasData = json.containsKey('data');

    if (hasCode || (hasData && json['data'] is Map)) {
      if (hasCode) {
        final code = json['code'];
        final codeInt = (code is int) ? code : int.tryParse(code.toString());
        final isSuccess = codeInt == 0 || codeInt == 200;
        if (!isSuccess) {
          final msg = json['msg']?.toString() ??
              json['message']?.toString() ??
              'Server business error (code: $code)';
          throw NetworkException(message: msg);
        }
      }

      final dataRaw = json['data'];
      if (dataRaw == null || dataRaw is! Map) {
        throw ValidationException(
          message: 'Invalid response format: missing or invalid data field',
        );
      }
      final data = Map<String, dynamic>.from(dataRaw);
      return WebVersionInfoBean.fromJson(data);
    }

    // 模式 2: 根 JSON 对象（标准静态托管 / RESTful 根对象）
    return WebVersionInfoBean.fromJson(json);
  }
}

/// 自定义函数适配器
class CustomVersionParser implements VersionInfoParser {
  final WebVersionInfoBean Function(dynamic raw) _parser;

  const CustomVersionParser(this._parser);

  @override
  WebVersionInfoBean parse(dynamic raw) => _parser(raw);
}

/// 版本号比对工具类
class VersionComparator {
  const VersionComparator._();

  /// 判断 remote 是否比 local 新，需要下载更新
  ///
  /// 支持：
  /// 1. 语义化版本比对（SemVer，如 `1.2.0 > 1.1.9`, `v2.0.1 > v2.0.0`）
  /// 2. 数值或时间戳递增比对（如 `1792649467655 > 1792649467000`, `12 > 10`）
  /// 3. 当本地版本为空时，返回 `true`（必须下载）
  static bool needsUpdate({
    dynamic localVersion,
    dynamic remoteVersion,
  }) {
    if (localVersion == null) return true;
    if (remoteVersion == null) return false;

    // 如果都是 int
    if (localVersion is int && remoteVersion is int) {
      return remoteVersion > localVersion;
    }

    final localStr = localVersion.toString().trim();
    final remoteStr = remoteVersion.toString().trim();

    if (localStr.isEmpty) return true;
    if (remoteStr.isEmpty) return false;

    // 尝试转成纯数字进行比较（避免时间戳字符串按字典序对比产生歧义）
    final localInt = int.tryParse(localStr);
    final remoteInt = int.tryParse(remoteStr);
    if (localInt != null && remoteInt != null) {
      return remoteInt > localInt;
    }

    // 语义化版本比较
    return compareSemVer(remoteStr, localStr) > 0;
  }

  /// 比较两个语义化版本字符串 (SemVer: major.minor.patch)
  /// 返回: > 0 如果 a > b; < 0 如果 a < b; 0 如果 a == b
  static int compareSemVer(String a, String b) {
    // 构建元数据不参与优先级；只在第一个连字符处分离预发布标识。
    final cleanA = _normalizeVersionString(a).split('+').first;
    final cleanB = _normalizeVersionString(b).split('+').first;
    final prereleaseIndexA = cleanA.indexOf('-');
    final prereleaseIndexB = cleanB.indexOf('-');
    final coreA =
        prereleaseIndexA < 0 ? cleanA : cleanA.substring(0, prereleaseIndexA);
    final coreB =
        prereleaseIndexB < 0 ? cleanB : cleanB.substring(0, prereleaseIndexB);
    final partsA = coreA.split('.');
    final partsB = coreB.split('.');

    final maxLen =
        partsA.length > partsB.length ? partsA.length : partsB.length;
    for (int i = 0; i < maxLen; i++) {
      final partA = i < partsA.length ? partsA[i] : '0';
      final partB = i < partsB.length ? partsB[i] : '0';

      final numA = int.tryParse(partA);
      final numB = int.tryParse(partB);

      if (numA != null && numB != null) {
        if (numA != numB) return numA.compareTo(numB);
      } else {
        final strComp = partA.compareTo(partB);
        if (strComp != 0) return strComp;
      }
    }

    // 同核心版本下，正式版高于任何预发布版本。
    if (prereleaseIndexA < 0 && prereleaseIndexB < 0) return 0;
    if (prereleaseIndexA < 0) return 1;
    if (prereleaseIndexB < 0) return -1;

    final prereleaseA = cleanA.substring(prereleaseIndexA + 1).split('.');
    final prereleaseB = cleanB.substring(prereleaseIndexB + 1).split('.');
    final numericIdentifier = RegExp(r'^\d+$');
    final minLen = prereleaseA.length < prereleaseB.length
        ? prereleaseA.length
        : prereleaseB.length;
    for (int i = 0; i < minLen; i++) {
      final partA = prereleaseA[i];
      final partB = prereleaseB[i];
      final numericA = numericIdentifier.hasMatch(partA);
      final numericB = numericIdentifier.hasMatch(partB);
      // 数字标识低于非数字标识，且按数值而非字典序比较。
      final comparison = numericA && numericB
          ? BigInt.parse(partA).compareTo(BigInt.parse(partB))
          : numericA != numericB
              ? (numericA ? -1 : 1)
              : partA.compareTo(partB);
      if (comparison != 0) return comparison;
    }
    return prereleaseA.length.compareTo(prereleaseB.length);
  }

  static String _normalizeVersionString(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1);
    }
    return s;
  }
}
