// 路径管理

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path_lib;

import 'util/logger.dart';
import 'web_payload_models.dart';

class FilePathUtility {
  static late String _appDocumentsPath;
  static const String _defaultDirName = 'default';
  static const String _currentDirName = 'current';
  static const String _downloadDirName = 'download';
  static const String _corruptDirName = 'corrupt';

  static Future<void> initialize() async {
    // 使用 ApplicationSupportDirectory，避免在低存储时被系统 Cache 清理机制静默抹除
    final documentsDir = await getApplicationSupportDirectory();
    _appDocumentsPath = documentsDir.path;

    // 确保所有基础目录存在
    await _ensureBaseDirectoriesExist();
  }

  static Future<void> _ensureBaseDirectoriesExist() async {
    for (final dirName in [
      _defaultDirName,
      _currentDirName,
      _downloadDirName,
      _corruptDirName
    ]) {
      await ensureDirectoryExists(path_lib.join(_appDocumentsPath, dirName));
    }
  }

  // ============ Directory Paths ============

  /// 获取 default 目录路径 (兜底资源)
  static String getModuleDefaultDir() =>
      path_lib.join(_appDocumentsPath, _defaultDirName);

  /// 获取 current 目录路径 (当前使用)
  static String getModuleCurrentDir() =>
      path_lib.join(_appDocumentsPath, _currentDirName);

  /// 获取 download 目录路径 (下载中)
  static String getModuleDownloadDir() =>
      path_lib.join(_appDocumentsPath, _downloadDirName);

  /// 获取 corrupt 目录路径 (损坏的文件)
  static String getModuleCorruptDir() =>
      path_lib.join(_appDocumentsPath, _corruptDirName);

  // ============ File Paths ============

  /// 获取 ZIP 文件路径
  static String getZipFilePath(String zipFileName) =>
      path_lib.join(getModuleDownloadDir(), zipFileName);

  /// 获取 ZIP 临时文件路径 (用于断点续传)
  static String getZipTempFilePath(String zipFileName) =>
      '${getZipFilePath(zipFileName)}.temp';

  /// 获取 ZIP 锁文件路径
  static String getZipLockFilePath(String zipFileName) =>
      '${getZipFilePath(zipFileName)}.lock';

  /// 获取 version.json 文件路径
  static String getVersionJsonPath() =>
      path_lib.join(getModuleCurrentDir(), 'version.json');

  // ============ Directory Operations ============

  /// 确保目录存在
  static Future<void> ensureDirectoryExists(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 清理目录 (删除所有内容)
  static Future<void> cleanupDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await ensureDirectoryExists(dirPath);
  }

  /// 删除目录
  static Future<void> deleteDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 回滚当前目录（当新版本发生运行时严重白屏或错误时调用，自动降级至 default 目录）
  static Future<bool> rollbackCurrentToDefault() async {
    try {
      final currentDir = Directory(getModuleCurrentDir());
      if (await currentDir.exists()) {
        final corruptDir = Directory(getModuleCorruptDir());
        await ensureDirectoryExists(corruptDir.path);
        final backupPath = path_lib.join(
          corruptDir.path,
          'rollback_${DateTime.now().millisecondsSinceEpoch}',
        );
        await currentDir.rename(backupPath);
        logger.w('Rolled back faulty current directory to $backupPath');
        return true;
      }
    } catch (e) {
      logger.e('Failed to rollback current directory: $e');
    }
    return false;
  }

  /// 获取目录大小 (字节)
  static Future<int> getDirectorySize(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;

    int size = 0;
    await for (final file in dir.list(recursive: true)) {
      if (file is File) {
        size += await file.length();
      }
    }
    return size;
  }

  /// 获取本地版本信息
  /// 从 current 或 default 目录读取 version.json
  /// - [dirType]: 如果为 null，优先读取 current，没有则读取 default；如果指定了 dirType（'current' 或 'default'），则读取对应目录
  static Future<VersionJsonBean?> getLocalVersionInfo({String? dirType}) async {
    try {
      // 如果 dirType 不为空，直接读取指定目录
      if (dirType != null) {
        final versionJsonPath = dirType == 'current'
            ? FilePathUtility.getVersionJsonPath()
            : path_lib.join(
                FilePathUtility.getModuleDefaultDir(), 'version.json');

        final file = File(versionJsonPath);
        if (!await file.exists()) {
          return null;
        }

        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return VersionJsonBean.fromJson(json);
      }

      // dirType 为 null，优先读取 current
      final currentVersionPath = FilePathUtility.getVersionJsonPath();
      final currentFile = File(currentVersionPath);
      if (await currentFile.exists()) {
        try {
          final content = await currentFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          return VersionJsonBean.fromJson(json);
        } catch (e) {
          logger.e('Error reading current version info: $e');
          // 如果读取 current 失败，继续尝试读取 default
        }
      }

      // current 不存在或读取失败，读取 default
      final defaultVersionPath =
          path_lib.join(FilePathUtility.getModuleDefaultDir(), 'version.json');
      final defaultFile = File(defaultVersionPath);
      if (!await defaultFile.exists()) {
        return null;
      }

      final content = await defaultFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return VersionJsonBean.fromJson(json);
    } catch (e) {
      logger.e('Error reading local version info: $e');
      return null;
    }
  }

  // ============ Path Validation ============

  /// 验证路径是否安全 (防止路径遍历)
  static bool isPathSafe(String requestPath, String basePath) {
    try {
      // 规范化路径
      final normalized = path_lib.normalize(requestPath);
      final absolute = path_lib.absolute(basePath, normalized);
      final base = path_lib.absolute(basePath);

      // 检查绝对路径是否在 basePath 内
      return path_lib.isWithin(base, absolute);
    } catch (e) {
      return false;
    }
  }

  // ============ Utilities ============

  /// 获取文件名
  static String getFileName(String filePath) => path_lib.basename(filePath);

  /// 获取文件扩展名
  static String getFileExtension(String filePath) =>
      path_lib.extension(filePath);
}
