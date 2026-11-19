import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path_lib;

import '../file_path_utility.dart';
import 'logger.dart';

class AssetSyncUtility {
  /// 自动发现所指定目录下的 asset 文件
  /// return 相对于 assetBaseDir 的相对路径列表
  static Future<List<String>> discoverAssetFiles(String assetBaseDir) async {
    List<String> assetKeys = <String>[];
    try {
      //  Flutter 3.10.0+ 提供了新的 AssetManifest API，可以直接获取所有 asset 列表，无需解析 JSON
      final AssetManifest manifest =
          await AssetManifest.loadFromAssetBundle(rootBundle);
      assetKeys = manifest.listAssets();
    } catch (_) {
      // Fallback for older runtimes where AssetManifest API may be unavailable.
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifest = json.decode(manifestContent);
      assetKeys = manifest.keys.toList();
    }

    // 统一去掉 assetBaseDir 末尾的斜杠（如果有）
    String normalizedBaseDir = assetBaseDir.endsWith('/')
        ? assetBaseDir.substring(0, assetBaseDir.length - 1)
        : assetBaseDir;

    final files = assetKeys
        .where(
            (k) => k.startsWith(normalizedBaseDir) && !k.endsWith('.DS_Store'))
        .toList();

    return files.map((e) {
      return e.substring(normalizedBaseDir.length + 1);
    }).toList();
  }

  /// 对比 asset 文件和本地 default 文件，返回 true表示需覆盖
  static Future<bool> needOverride(String assetFile, String localFile) async {
    try {
      final assetBytes = await rootBundle.load(assetFile);
      final assetMd5 = md5.convert(assetBytes.buffer.asUint8List()).toString();
      final f = File(localFile);
      if (!await f.exists()) return true;
      final localMd5 = md5.convert(await f.readAsBytes()).toString();
      return assetMd5 != localMd5;
    } catch (_) {
      return true;
    }
  }

  /// 批量拷贝 asset -> default
  static Future<void> batchCopyAssetsToDefault(
    List<String> assetFiles,
    String defaultDir,
    String assetModulePrefix,
  ) async {
    final dir = Directory(defaultDir);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    for (final assetFile in assetFiles) {
      // 拼接完整 asset 路径
      final assetFullPath = path_lib.join(assetModulePrefix, assetFile);
      final targetPath = path_lib.join(defaultDir, assetFile);
      final bytes = await rootBundle.load(assetFullPath);
      final f = File(targetPath);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes.buffer.asUint8List());
    }
  }

  static Future<void> syncAllAssetsToDefault(String assetBaseDir) async {
    final assetFilePaths =
        await AssetSyncUtility.discoverAssetFiles(assetBaseDir);

    final defaultDir = FilePathUtility.getModuleDefaultDir();

    bool needOverride = false;
    for (final assetFile in assetFilePaths) {
      // 源文件完整路径，需要拼接 assetBaseDir 和 assetFile
      final sourceFile = path_lib.join(assetBaseDir, assetFile);
      final defaultFile = path_lib.join(defaultDir, assetFile);
      if (await AssetSyncUtility.needOverride(sourceFile, defaultFile)) {
        needOverride = true;
        break;
      }
    }
    if (needOverride) {
      try {
        await AssetSyncUtility.batchCopyAssetsToDefault(
            assetFilePaths, defaultDir, assetBaseDir);
        logger.i('同步 asset -> default 完成: $assetFilePaths');
      } catch (e) {
        logger.e('同步 asset -> default 失败: $e');
      }
    }
  }
}
