import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

const int _keepZipCount = 5;

Map<String, dynamic> serverManifest = {};

final String _toolDir =
    p.normalize(p.join(p.dirname(Platform.script.toFilePath()), '..'));
final String _projectRoot = p.normalize(p.join(_toolDir, '..'));

class _AssetFile {
  _AssetFile(this.path, this.md5);

  final String path;
  final String md5;

  Map<String, String> toJson() => {'path': path, 'md5': md5};
}

String _buildLabel(DateTime now) {
  final y = now.year.toString().padLeft(4, '0');
  final mo = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  final ss = now.second.toString().padLeft(2, '0');
  return '$y-$mo-$d $hh:$mm:$ss';
}

String _injectVersionInfo(
  String htmlContent,
  int assetVersion,
  String buildLabel,
) {
  final withoutStaleBadge = htmlContent.replaceAll(
    RegExp(
      r'\s*<div id="web-payload-version-info"[^>]*>[\s\S]*?</div>\s*',
      multiLine: true,
    ),
    '\n',
  );
  final versionInfoDiv = '''
    <div id="web-payload-version-info" style="position: fixed; bottom: 10px; right: 10px; background: rgba(0,0,0,0.75); color: white; padding: 6px 10px; border-radius: 6px; font-size: 12px; z-index: 9999;">
      资源版本：$assetVersion　构建时间：$buildLabel
    </div>
  ''';
  return withoutStaleBadge.replaceFirst('</body>', '$versionInfoDiv\n</body>');
}

Future<void> _cleanupOldZips(Directory distDir,
    {int keep = _keepZipCount}) async {
  final zips = <({int version, File file})>[];
  final pattern = RegExp(r'^payload_v(\d+)\.zip$');

  await for (final entity in distDir.list()) {
    if (entity is! File) {
      continue;
    }
    final name = p.basename(entity.path);
    final match = pattern.firstMatch(name);
    if (match == null) {
      continue;
    }
    zips.add((version: int.parse(match.group(1)!), file: entity));
  }

  zips.sort((a, b) => b.version.compareTo(a.version));
  if (zips.length <= keep) {
    return;
  }

  stdout.writeln('ℹ️  清理旧 zip，保留最新 $keep 个。');
  for (final entry in zips.skip(keep)) {
    await entry.file.delete();
    stdout.writeln('   - 已删除 payload_v${entry.version}.zip');
  }
}

/// 构建 ZIP 与清单；[assetsDirectory] 和 [outputDirectory] 可指定输入输出目录，
/// 缺省使用 tool/mock_assets 与 tool/dist，便于本地联调及临时目录往返测试。
Future<void> runPayloadBuild(
    {Directory? assetsDirectory, Directory? outputDirectory}) async {
  final assetsDir =
      assetsDirectory ?? Directory(p.join(_projectRoot, 'tool', 'mock_assets'));
  final distDirectory =
      outputDirectory ?? Directory(p.join(_projectRoot, 'tool', 'dist'));
  final manifestFile = File(p.join(distDirectory.path, 'server_manifest.json'));

  stdout.writeln('🚀 Starting build process...');

  if (!await distDirectory.exists()) {
    await distDirectory.create(recursive: true);
  }
  stdout.writeln('✅ Directories prepared.');

  var newVersion = 1;
  if (await manifestFile.exists()) {
    try {
      final manifestContent =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      newVersion = (manifestContent['version'] as int) + 1;
    } catch (_) {
      stdout
          .writeln('⚠️ Could not read old manifest, starting version from 1.');
    }
  }

  final label = _buildLabel(DateTime.now());
  stdout.writeln('ℹ️ Building version: $newVersion ($label)');

  final assetFiles = <_AssetFile>[];
  final allFiles =
      assetsDir.listSync(recursive: true).whereType<File>().toList();
  final generatedContents = <String, List<int>>{};

  for (final file in allFiles) {
    final relativePath = p.relative(file.path, from: assetsDir.path);
    late final List<int> bytes;
    if (relativePath.endsWith('.html')) {
      final source = await file.readAsString();
      bytes = utf8.encode(_injectVersionInfo(source, newVersion, label));
    } else {
      bytes = await file.readAsBytes();
    }
    generatedContents[relativePath] = bytes;
    assetFiles.add(_AssetFile(relativePath, md5.convert(bytes).toString()));
  }
  stdout.writeln('✅ Calculated MD5 for ${assetFiles.length} asset files.');

  final versionJson = {
    'version': newVersion,
    'buildLabel': label,
    'fileInfo': {
      'total_files': assetFiles.length,
      'files': assetFiles.map((f) => f.toJson()).toList(),
    },
    'modules': [
      {
        'name': 'Module One',
        'key': 'module_one',
        'entryHtml': 'module_one/index.html',
        'version': newVersion,
        'description': 'The first test module.',
      },
      {
        'name': 'Module Two',
        'key': 'module_two',
        'entryHtml': 'module_two/index.html',
        'version': newVersion,
        'description': 'The second test module.',
      },
    ],
  };

  final zipFileName = 'payload_v$newVersion.zip';
  final zipFilePath = p.join(distDirectory.path, zipFileName);
  final encoder = ZipFileEncoder()..create(zipFilePath);

  for (final entry in generatedContents.entries) {
    encoder.addArchiveFile(
      ArchiveFile(entry.key, entry.value.length, entry.value),
    );
  }

  final versionJsonBytes = utf8.encode(jsonEncode(versionJson));
  encoder.addArchiveFile(
    ArchiveFile('version.json', versionJsonBytes.length, versionJsonBytes),
  );
  await encoder.close();
  stdout.writeln('✅ Created ZIP archive: $zipFileName');

  final zipFile = File(zipFilePath);
  final zipBytes = await zipFile.readAsBytes();
  final zipMd5 = md5.convert(zipBytes).toString();
  final zipSize = await zipFile.length();
  stdout.writeln('✅ Calculated ZIP MD5: $zipMd5');

  final nextManifest = {
    'version': newVersion,
    'buildLabel': label,
    'zipFilename': zipFileName,
    'zipMd5': zipMd5,
    'zipSize': zipSize,
  };
  await manifestFile.writeAsString(jsonEncode(nextManifest));
  stdout.writeln('✅ Wrote server_manifest.json');

  await _cleanupOldZips(distDirectory);
  stdout.writeln('🎉 Build completed successfully!');
}

final _router = Router()
  ..get('/check-update', (Request request) async {
    print('ℹ️  Request received: /check-update');
    final manifestFile = File(p.join(_toolDir, 'dist', 'server_manifest.json'));
    if (await manifestFile.exists()) {
      await _loadManifest(manifestFile);
    }

    final host = request.headers['host'] ?? 'localhost:8080';
    final zipUrl = 'http://$host/${serverManifest['zipFilename']}';
    final version = serverManifest['version'];
    final buildLabel = serverManifest['buildLabel'];

    final responsePayload = {
      'code': 0,
      'message': 'Success',
      'data': {
        'zipUrl': zipUrl,
        'version': version,
        'md5': serverManifest['zipMd5'],
        'fileSize': serverManifest['zipSize'],
        'buildLabel': buildLabel,
        'description': 'Test payload version $version ($buildLabel)',
      },
    };

    return Response.ok(
      jsonEncode(responsePayload),
      headers: {'Content-Type': 'application/json'},
    );
  })
  ..get('/version.json', (Request request) async {
    print('ℹ️  Request received: /version.json (Static Root JSON format)');
    final manifestFile = File(p.join(_toolDir, 'dist', 'server_manifest.json'));
    if (await manifestFile.exists()) {
      await _loadManifest(manifestFile);
    }

    final host = request.headers['host'] ?? 'localhost:8080';
    final zipUrl = 'http://$host/${serverManifest['zipFilename']}';
    final version = serverManifest['version'];
    final buildLabel = serverManifest['buildLabel'];

    final responsePayload = {
      'version': version,
      'versionStr': version.toString(),
      'downloadUrl': zipUrl,
      'zipUrl': zipUrl,
      'md5': serverManifest['zipMd5'],
      'fileSize': serverManifest['zipSize'],
      'buildLabel': buildLabel,
      'description': 'Test static payload version $version ($buildLabel)',
    };

    return Response.ok(
      jsonEncode(responsePayload),
      headers: {'Content-Type': 'application/json'},
    );
  });

void _printUsage() {
  stdout.writeln('Usage: ./tool/bin/server.sh [options]');
  stdout.writeln('');
  stdout.writeln('本地 mock 服务：构建演示 zip、提供 /check-update 与静态下载。');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln('  --build       启动前强制构建（version +1，刷新 buildLabel）');
  stdout.writeln('  --build-only  仅构建后退出，不启动 HTTP 服务');
  stdout.writeln('  --help, -h    显示帮助');
  stdout.writeln('');
  stdout.writeln('默认启动时：若缺少 manifest，或 mock_assets/ 与本脚本');
  stdout.writeln('比上次构建更新，会自动先构建再启动。');
}

Future<DateTime?> _latestModifiedTime(Directory dir) async {
  if (!await dir.exists()) {
    return null;
  }

  DateTime? latest;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final modified = (await entity.stat()).modified;
    if (latest == null || modified.isAfter(latest)) {
      latest = modified;
    }
  }
  return latest;
}

Future<bool> _shouldAutoBuild({
  required File manifestFile,
  required File serverScript,
}) async {
  if (!await manifestFile.exists()) {
    stdout.writeln('ℹ️  server_manifest.json 不存在，将自动构建。');
    return true;
  }

  final manifestModified = (await manifestFile.stat()).modified;
  final mockAssetsDir = Directory(p.join(_projectRoot, 'tool', 'mock_assets'));

  final mockLatest = await _latestModifiedTime(mockAssetsDir);
  if (mockLatest != null && mockLatest.isAfter(manifestModified)) {
    stdout.writeln('ℹ️  mock_assets 有更新，将自动重新构建。');
    return true;
  }

  if (await serverScript.exists()) {
    final scriptModified = (await serverScript.stat()).modified;
    if (scriptModified.isAfter(manifestModified)) {
      stdout.writeln('ℹ️  tool/bin/server.dart 有更新，将自动重新构建。');
      return true;
    }
  }

  return false;
}

bool _isAddressInUse(Object error) {
  if (error is! SocketException) {
    return false;
  }
  final code = error.osError?.errorCode;
  if (code == 48 || code == 98 || code == 10048) {
    return true;
  }
  final message = error.message.toLowerCase();
  return message.contains('address already in use') ||
      message.contains('bind failed') ||
      message.contains('eaddrinuse');
}

Future<HttpServer> _serveOnAvailablePort(
  Handler handler, {
  int preferredPort = 8080,
  int maxAttempts = 100,
}) async {
  Object? lastError;
  for (var offset = 0; offset < maxAttempts; offset++) {
    final port = preferredPort + offset;
    try {
      return await io.serve(handler, InternetAddress.anyIPv4, port);
    } catch (error) {
      if (!_isAddressInUse(error)) {
        rethrow;
      }
      if (offset == 0) {
        print(
          '⚠️  Port $preferredPort is in use, trying next available port...',
        );
      }
      lastError = error;
    }
  }
  throw lastError ??
      StateError(
        'No available port in range $preferredPort-${preferredPort + maxAttempts - 1}',
      );
}

Future<void> _loadManifest(File manifestFile) async {
  serverManifest =
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
  print(
    '✅ Server manifest loaded for version: ${serverManifest['version']} (${serverManifest['buildLabel']})',
  );
}

void _printEndpointUrls({
  required int port,
  required String distDir,
  String? lanIp,
}) {
  final zipName = serverManifest['zipFilename'] as String;
  final loopbackCheck = 'http://127.0.0.1:$port/check-update';
  final localhostCheck = 'http://localhost:$port/check-update';
  final emulatorCheck = 'http://10.0.2.2:$port/check-update';
  final loopbackZip = 'http://127.0.0.1:$port/$zipName';
  final localhostZip = 'http://localhost:$port/$zipName';
  final emulatorZip = 'http://10.0.2.2:$port/$zipName';

  print('🚀 Server listening on port $port');
  print('   Static root: $distDir');
  print('');
  print('   检查更新（本机 - 业务 Envelope 模式）:');
  print('     $loopbackCheck');
  print('   检查更新（本机 - 静态 Root JSON 模式）:');
  print('     http://127.0.0.1:$port/version.json');
  print('   Zip 下载（本机）:');
  print('     $loopbackZip');
  print('     $localhostZip');
  print('');
  print('   Android 模拟器访问宿主机:');
  print('     检查更新: $emulatorCheck');
  print('     Zip 下载: $emulatorZip');

  if (lanIp != null) {
    final lanCheck = 'http://$lanIp:$port/check-update';
    final lanZip = 'http://$lanIp:$port/$zipName';
    print('');
    print('   局域网（真机调试，请与手机同一 Wi-Fi）:');
    print('     检查更新: $lanCheck');
    print('     Zip 下载: $lanZip');
    print('');
    print('   Example 可设置:');
    print('     --dart-define=UPDATE_URL=$lanCheck');
  }

  print('');
  print('   按 Ctrl+C 停止服务。');
}

Future<void> _startHttpServer(String distDir) async {
  final cascade = Cascade()
      .add(_router)
      .add(createStaticHandler(distDir, defaultDocument: 'index.html'))
      .handler;

  final pipeline =
      const Pipeline().addMiddleware(logRequests()).addHandler(cascade);

  String? lanIp;
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    if (interfaces.isNotEmpty) {
      lanIp = interfaces.first.addresses.first.address;
    }
  } catch (e) {
    print('⚠️ Could not discover LAN IP address: $e');
  }

  const preferredPort = 8080;
  final httpServer =
      await _serveOnAvailablePort(pipeline, preferredPort: preferredPort);
  final port = httpServer.port;
  if (port != preferredPort) {
    print('ℹ️  Using fallback port $port (preferred $preferredPort was busy).');
  }

  _printEndpointUrls(port: port, distDir: distDir, lanIp: lanIp);
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printUsage();
    return;
  }

  final distDir = p.join(_projectRoot, 'tool', 'dist');
  final manifestFile = File(p.join(distDir, 'server_manifest.json'));
  final serverScript = File(p.join(_toolDir, 'bin', 'server.dart'));
  final buildOnly = args.contains('--build-only');
  final forceBuild = args.contains('--build') || buildOnly;

  if (forceBuild && !buildOnly) {
    stdout.writeln('ℹ️  已指定 --build，将强制重新构建。');
  } else if (buildOnly) {
    stdout.writeln('ℹ️  仅构建模式（--build-only）。');
  }

  final needBuild = forceBuild ||
      (!buildOnly &&
          await _shouldAutoBuild(
            manifestFile: manifestFile,
            serverScript: serverScript,
          ));

  if (needBuild) {
    await runPayloadBuild();
  } else if (await manifestFile.exists()) {
    stdout.writeln(
      'ℹ️  使用已有构建产物（version 未变）。'
      ' 需要新版本请执行: ./tool/bin/server.sh --build',
    );
  }

  if (!await manifestFile.exists()) {
    stderr.writeln('❌ Error: server_manifest.json not found.');
    stderr.writeln('   Run: ./tool/bin/server.sh --build-only');
    exit(1);
  }

  if (buildOnly) {
    await _loadManifest(manifestFile);
    return;
  }

  await _loadManifest(manifestFile);
  await _startHttpServer(distDir);
}
