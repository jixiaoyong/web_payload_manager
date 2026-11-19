// 下载、解压、校验和原子更新服务

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_lib;

import 'exception_handler.dart';
import 'file_path_utility.dart';
import 'util/logger.dart';
import 'version_parser.dart';
import 'web_payload_models.dart';

/// Isolate 入口函数,用于处理解压和校验
/// 必须是顶层函数或静态方法
Future<VersionJsonBean> _isolateProcessAndValidate(
    Map<String, dynamic> params) async {
  final zipPath = params['zipPath']!;
  final targetDir = params['targetDir']!;

  try {
    // 1. 读取 ZIP 文件
    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      throw ValidationException(
        message: 'ZIP file not found: $zipPath',
      );
    }

    final bytes = await zipFile.readAsBytes();
    final directory = ZipDirectory()
      ..read(InputMemoryStream(bytes), verify: true);
    var declaredBytes = 0;
    if (directory.fileHeaders.length > params['maxEntries']) {
      throw ValidationException(message: 'ZIP entry limit exceeded');
    }
    final rawNames = <String>{};
    for (final header in directory.fileHeaders) {
      final name = header.filename.endsWith('/')
          ? header.filename.substring(0, header.filename.length - 1)
          : header.filename;
      if (!_safeRelativePath(name) || !rawNames.add(name)) {
        throw ValidationException(
            message: 'Unsafe or duplicate ZIP entry: $name');
      }
      final size = header.uncompressedSize;
      final localSize = header.file?.uncompressedSize ?? -1;
      final mode = header.externalFileAttributes >> 16;
      declaredBytes += size;
      if (size < 0 ||
          size != localSize ||
          size > params['maxFileBytes'] ||
          declaredBytes > params['maxExpandedBytes'] ||
          (mode & 0xf000 != 0 &&
              mode & 0xf000 != 0x8000 &&
              mode & 0xf000 != 0x4000)) {
        throw ValidationException(
            message: 'Unsafe ZIP header or expansion limit');
      }
    }
    final archive =
        ZipDecoder().decodeBytes(bytes, verify: true, throwOnError: true);

    // 在读取条目内容前检查路径、类型和声明尺寸，限制解压资源消耗。
    if (archive.files.length > params['maxEntries']) {
      throw ValidationException(message: 'ZIP entry limit exceeded');
    }
    final names = <String>{};
    var expandedSize = 0;
    for (final file in archive.files) {
      final name = file.name.endsWith('/')
          ? file.name.substring(0, file.name.length - 1)
          : file.name;
      if (!_safeRelativePath(name) ||
          !names.add(name) ||
          file.isSymbolicLink ||
          (file.mode & 0xf000 != 0 &&
              file.mode & 0xf000 != 0x8000 &&
              file.mode & 0xf000 != 0x4000)) {
        throw ValidationException(message: 'Unsafe ZIP entry: ${file.name}');
      }
      expandedSize += file.size;
      if (file.size > params['maxFileBytes'] ||
          expandedSize > params['maxExpandedBytes']) {
        throw ValidationException(message: 'ZIP expansion limit exceeded');
      }
    }

    // 2. 仅接受根目录清单，避免嵌套清单与实际解压根不一致。
    ArchiveFile? versionJsonFile;
    for (final file in archive.files) {
      if (file.name == 'version.json' && file.isFile) {
        versionJsonFile = file;
        break;
      }
    }

    if (versionJsonFile == null) {
      throw ValidationException(
        message: 'version.json not found in ZIP',
      );
    }

    // 3. 解析 version.json
    final versionJsonContent = utf8.decode(versionJsonFile.content);
    final versionJson = jsonDecode(versionJsonContent) as Map<String, dynamic>;
    final moduleVersion = VersionJsonBean.fromJson(versionJson);

    if (params['expectedVersion'] != null &&
        moduleVersion.effectiveVersionStr != params['expectedVersion']) {
      throw ValidationException(
          message: 'Payload version differs from remote manifest');
    }
    final entries = moduleVersion.fileInfo?.files;
    final actualFiles = archive.files
        .where((f) => f.isFile && f.name != 'version.json')
        .map((f) => f.name)
        .toSet();
    if (entries != null) {
      final listed = entries.map((f) => f.path).toSet();
      if (listed.length != entries.length ||
          listed.any((p) => p == null || !_safeRelativePath(p)) ||
          !listed.containsAll(actualFiles) ||
          listed.any((p) => !actualFiles.contains(p)) ||
          (moduleVersion.fileInfo?.totalFiles != null &&
              moduleVersion.fileInfo!.totalFiles != entries.length)) {
        throw ValidationException(
            message: 'Incomplete or invalid file manifest');
      }
    }
    final modules = moduleVersion.modules;
    if (modules != null) {
      if (modules.isEmpty) {
        throw ValidationException(
            message: 'Payload contains empty module declarations');
      }
      for (final module in modules) {
        if (module.key == null ||
            module.entryHtml == null ||
            !_safeRelativePath(module.entryHtml!) ||
            !actualFiles.contains(module.entryHtml)) {
          throw ValidationException(message: 'Missing or unsafe module entry');
        }
      }
    }

    // 4. 创建临时目录用于解压
    final tempDir = Directory('${targetDir}_temp');
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    await tempDir.create(recursive: true);

    // 5. 解压所有文件
    for (final file in archive.files) {
      if (file.isFile) {
        final outputPath = path_lib.join(tempDir.path, file.name);
        final outputFile = File(outputPath);
        await outputFile.parent.create(recursive: true);
        // archive4 的 CRC 为惰性校验，读取实际内容后才能接受该文件。
        final content = file.content;
        if (content.length != file.size) {
          throw ValidationException(
              message: 'ZIP actual size differs: ${file.name}');
        }
        await outputFile.writeAsBytes(content);
      }
    }

    // 6. MD5 校验每个文件
    await _validateAllFilesMd5(
        tempDir.path, moduleVersion.fileInfo?.files ?? []);

    // 7. 校验成功,将临时目录重命名为目标目录
    final targetDirObj = Directory(targetDir);
    if (await targetDirObj.exists()) {
      await targetDirObj.delete(recursive: true);
    }
    await tempDir.rename(targetDir);

    // logger 在 isolate 中不可用,但可以在主线程中 log
    return moduleVersion;
  } catch (e) {
    if (e is ValidationException) rethrow;
    throw ValidationException(
      message: 'Failed to process ZIP in isolate: $e',
      originalException: e as Exception?,
    );
  }
}

/// 校验所有文件的 MD5 (Isolate 内使用)
Future<void> _validateAllFilesMd5(
    String baseDir, List<WebAssetFile> fileEntries) async {
  for (final fileEntry in fileEntries) {
    if (fileEntry.path == null || !_safeRelativePath(fileEntry.path!)) {
      throw ValidationException(message: 'Unsafe manifest path');
    }
    final filePath = path_lib.join(baseDir, fileEntry.path);
    final file = File(filePath);

    if (!await file.exists()) {
      throw ValidationException(
        message: 'Expected file not found: ${fileEntry.path}',
      );
    }

    if (fileEntry.md5?.isEmpty ?? true) continue;
    final actualMd5 = await _calculateFileMd5(filePath);
    if (actualMd5 != fileEntry.md5) {
      throw ValidationException(
        message: 'MD5 mismatch for file: ${fileEntry.path}\n'
            'Expected: ${fileEntry.md5}\n'
            'Actual: $actualMd5',
      );
    }
  }
}

/// 计算单个文件的 MD5 (Isolate 内使用)
Future<String> _calculateFileMd5(String filePath) async {
  final file = File(filePath);
  final bytes = await file.readAsBytes();
  return md5.convert(bytes).toString();
}

bool _safeRelativePath(String value) =>
    value.isNotEmpty &&
    !value.contains('\\') &&
    !value.contains(':') &&
    !value.contains('\u0000') &&
    !path_lib.posix.isAbsolute(value) &&
    !value.split('/').any((p) => p == '..' || p == '.' || p.isEmpty);

/// 下载并验证离线包；限制针对压缩文件及解压后的条目总量。
class DownloadService {
  final Dio _dio;
  final int maxArchiveBytes;
  final int maxEntries;
  final int maxExpandedBytes;
  final int maxFileBytes;

  /// [dio] 可注入网络客户端；[timeoutMs] 为超时毫秒数。
  /// [maxArchiveBytes]、[maxEntries]、[maxExpandedBytes]、[maxFileBytes]
  /// 分别限制压缩字节、条目数量、解压总字节与单文件字节。
  DownloadService({
    Dio? dio,
    this.maxArchiveBytes = 64 * 1024 * 1024,
    this.maxEntries = 10000,
    this.maxExpandedBytes = 256 * 1024 * 1024,
    this.maxFileBytes = 64 * 1024 * 1024,
    int timeoutMs = 30000,
  }) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = Duration(milliseconds: timeoutMs);
    _dio.options.receiveTimeout = Duration(milliseconds: timeoutMs);
  }

  /// 启动下载流程
  /// 包括下载、ZIP 校验、解压、MD5 校验和原子更新。
  /// [downloadUrl] 为包地址；[saveDir] 为中间文件目录；[cancelToken] 控制取消。
  /// [expectedMd5] 与 [expectedVersion] 提供远端摘要及精确版本，缺省兼容旧调用。
  /// [publishExclusive] 可由宿主串行化最终替换与快照读取；[onReceiveProgress] 报告字节进度。
  Future<void> startDownload({
    required String downloadUrl,
    required String saveDir,
    required CancelToken cancelToken,
    String? expectedMd5,
    String? expectedVersion,
    Future<void> Function(Future<void> Function())? publishExclusive,
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    // 1. 准备目录
    await FilePathUtility.ensureDirectoryExists(saveDir);

    // 2. 获取文件名
    final uri = Uri.parse(downloadUrl);
    final fileName = uri.path.split('/').last;
    if (!_safeRelativePath(fileName) || fileName.contains('/')) {
      throw ValidationException(message: 'Unsafe download filename');
    }
    final key = fileName.replaceAll('.zip', '');

    // 3. 获取下载文件路径
    final zipPath = FilePathUtility.getZipFilePath(fileName);
    final tempPath = FilePathUtility.getZipTempFilePath(fileName);

    // 4. 检查是否可以断点续传
    int startBytes = 0;
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      startBytes = await tempFile.length();
      logger.i('Resume download from byte: $startBytes');
    }

    // 5. 下载文件
    await _downloadWithProgress(
      url: downloadUrl,
      savePath: tempPath,
      startBytes: startBytes,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );

    // 6. 校验 ZIP 完整性
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    if (!await _hasZipDirectory(tempPath)) {
      // 损坏的完整文件不能再作为续传前缀，否则每次重试都会得到 416。
      await tempFile.delete();
      throw IntegrityException(message: 'Downloaded ZIP file is corrupted');
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;

    if (expectedMd5 != null &&
        expectedMd5.isNotEmpty &&
        (await _calculateFileMd5(tempPath)).toLowerCase() !=
            expectedMd5.toLowerCase()) {
      await tempFile.delete();
      throw IntegrityException(message: 'Remote ZIP MD5 mismatch');
    }

    // 7. 将 .temp 文件重命名为正式文件
    await tempFile.rename(zipPath);

    // 8. 处理并校验 (在后台 Isolate 中执行)
    logger.i('Starting ZIP processing in background isolate...');
    await compute(_isolateProcessAndValidate, {
      'zipPath': zipPath,
      'targetDir': '$saveDir/extracted',
      'expectedVersion': expectedVersion,
      'maxEntries': maxEntries,
      'maxExpandedBytes': maxExpandedBytes,
      'maxFileBytes': maxFileBytes,
    });
    logger.i('Successfully validated and extracted ZIP to: $saveDir');
    // 解压期间取消不发布新资源；compute 本身无法中断。
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;

    // 9. 原子更新 current 目录
    Future<void> publish() async {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      await _atomicallyUpdateCurrent(sourceDir: '$saveDir/extracted');
    }

    if (publishExclusive == null) {
      await publish();
    } else {
      await publishExclusive(publish);
    }

    // 10. 清理下载产物 (包括 .zip, .temp, .lock)
    await _cleanupDownloadArtifacts(fileName);

    logger.i('Download completed successfully for key: $key');
  }

  /// 带进度报告的下载
  Future<void> _downloadWithProgress({
    required String url,
    required String savePath,
    required int startBytes,
    required CancelToken cancelToken,
    void Function(int, int)? onReceiveProgress,
  }) async {
    final file = File(savePath);
    var offset = startBytes;
    // 416 的长度不匹配时仅重试一次完整请求，避免错误服务端造成死循环。
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          headers: {
            'Range': offset > 0 ? 'bytes=$offset-' : null,
            // Range 和磁盘偏移必须使用同一种字节表示。
            'Accept-Encoding': 'identity',
          },
          receiveDataWhenStatusError: false,
          validateStatus: (status) =>
              status == 200 || status == 206 || status == 416,
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      final body = response.data!;
      // 即使拒绝响应头，也要取消流以释放连接与 Dio 的超时计时器。
      final iterator = StreamIterator(body.stream);
      RandomAccessFile? output;
      try {
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        if (response.statusCode == 416) {
          final match = RegExp(r'^bytes \*/(\d+)$')
              .firstMatch(response.headers.value('content-range') ?? '');
          final total = match == null ? null : int.tryParse(match[1]!);
          if (offset > 0 && total == offset) {
            onReceiveProgress?.call(offset, total!);
            return; // startDownload 仍会校验 ZIP/CRC，而非盲信 416。
          }
          if (offset > 0 && attempt == 0) {
            offset = 0;
            continue; // 在得到有效 200/206 前保留旧片段。
          }
          throw IntegrityException(message: 'Invalid range response (416)');
        }

        final encoding = response.headers.value('content-encoding');
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          throw IntegrityException(
              message: 'Encoded download is not resumable');
        }
        final contentLength = response.headers.value('content-length');
        int? expected =
            contentLength == null ? null : int.tryParse(contentLength);
        if (contentLength != null && (expected == null || expected < 0)) {
          throw IntegrityException(message: 'Invalid Content-Length');
        }
        int total;
        if (response.statusCode == 206) {
          final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
              .firstMatch(response.headers.value('content-range') ?? '');
          final start = match == null ? null : int.tryParse(match[1]!);
          final end = match == null ? null : int.tryParse(match[2]!);
          final size = match == null ? null : int.tryParse(match[3]!);
          if (start != offset ||
              end == null ||
              size == null ||
              end < offset ||
              end >= size ||
              end != size - 1 ||
              (expected != null && expected != end - offset + 1)) {
            throw IntegrityException(message: 'Invalid Content-Range');
          }
          expected = end - offset + 1;
          total = size;
        } else {
          // 服务端忽略 Range：完整响应必须覆盖，不能追加。
          offset = 0;
          total = expected ?? -1;
        }

        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        output = await file.open(mode: FileMode.append);
        await output.truncate(offset);
        await output.setPosition(offset);
        var received = 0;
        var lastLoggedPercent = -1;
        while (await iterator.moveNext()) {
          if (cancelToken.isCancelled) throw cancelToken.cancelError!;
          final chunk = iterator.current;
          if (offset + received + chunk.length > maxArchiveBytes) {
            await output.truncate(0);
            throw IntegrityException(
                message: 'ZIP download size limit exceeded');
          }
          if (expected != null && received + chunk.length > expected) {
            // 非法响应的已写入部分不应污染下一次续传。
            await output.truncate(offset);
            throw IntegrityException(
                message: 'Download exceeds declared length');
          }
          await output.writeFrom(chunk);
          received += chunk.length;
          final current = offset + received;
          if (total > 0) {
            final percent = (current / total * 100).round();
            if (percent >= lastLoggedPercent + 10 || percent >= 100) {
              logger.i('Download progress: $current / $total ($percent%)');
              lastLoggedPercent = percent;
            }
          }
          onReceiveProgress?.call(current, total);
        }
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        if (expected != null && received != expected) {
          // 短响应仍是有效前缀，下一次从实际落盘长度继续。
          throw IntegrityException(message: 'Incomplete download');
        }
        return;
      } finally {
        await output?.close();
        await iterator.cancel();
      }
    }
  }

  /// 仅做目录结构初筛；真正完整性检查必须等待 isolate 读取全部普通文件。
  Future<bool> _hasZipDirectory(String zipPath) async {
    try {
      final file = File(zipPath);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return false;
      try {
        // 这里只检查目录结构，完整 CRC 验证在受边界检查保护的 isolate 内进行。
        final directory = ZipDirectory()
          ..read(InputMemoryStream(bytes), verify: true);
        return directory.fileHeaders.isNotEmpty;
      } catch (e) {
        logger.e('Error validating ZIP: $e');
        return false;
      }
    } catch (e) {
      logger.e('Error checking ZIP integrity: $e');
      return false;
    }
  }

  /// 原子更新 current 目录
  Future<void> _atomicallyUpdateCurrent({
    required String sourceDir,
  }) async {
    try {
      final currentDir = FilePathUtility.getModuleCurrentDir();
      final currentDirObj = Directory(currentDir);

      if (await currentDirObj.exists()) {
        final corruptDir = Directory(FilePathUtility.getModuleCorruptDir());
        if (await corruptDir.exists()) {
          await corruptDir.delete(recursive: true);
        }
        await corruptDir.create(recursive: true);
        await currentDirObj.rename(path_lib.join(corruptDir.path, 'backup'));
      }

      final sourceDirectory = Directory(sourceDir);
      try {
        await sourceDirectory.rename(currentDir);
      } catch (_) {
        final backup = Directory(
            path_lib.join(FilePathUtility.getModuleCorruptDir(), 'backup'));
        if (!await currentDirObj.exists() && await backup.exists()) {
          await backup.rename(currentDir);
        }
        rethrow;
      }

      logger.i('Atomically updated current directory');
    } catch (e) {
      throw StorageException(
        message: 'Failed to atomically update current directory: $e',
        originalException: e as Exception?,
      );
    }
  }

  /// 清理下载产物
  Future<void> _cleanupDownloadArtifacts(String fileName) async {
    try {
      final zipPath = FilePathUtility.getZipFilePath(fileName);
      final tempPath = FilePathUtility.getZipTempFilePath(fileName);
      final lockPath = FilePathUtility.getZipLockFilePath(fileName);

      for (final path in [zipPath, tempPath, lockPath]) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      logger.w('Warning: Failed to cleanup download artifacts: $e');
    }
  }

  /// 比较版本,返回 true 表示需要更新
  /// 支持 int、时间戳与语义化版本字符串 (SemVer: 1.2.0 > 1.1.9)
  bool compareVersions({
    required dynamic localVersion,
    required dynamic remoteVersion,
  }) {
    return VersionComparator.needsUpdate(
      localVersion: localVersion,
      remoteVersion: remoteVersion,
    );
  }

  /// 销毁资源
  void dispose() {
    _dio.close();
  }
}
