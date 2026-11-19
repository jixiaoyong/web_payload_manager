import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/download_service.dart';
import 'package:web_payload_manager/src/exception_handler.dart';
import 'package:web_payload_manager/src/file_path_utility.dart';

// 手工写 ZIP 结构，保留原始重复条目，不经过 Archive 的按名称去重。
List<int> rawZip(List<(String, List<int>)> entries) {
  final local = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int n) =>
      b.add((ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List());
  void u32(BytesBuilder b, int n) =>
      b.add((ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List());
  for (final (name, data) in entries) {
    final filename = utf8.encode(name);
    final offset = local.length;
    final crc = getCrc32(data);
    u32(local, 0x04034b50);
    for (final n in [20, 0, 0, 0, 0]) {
      u16(local, n);
    }
    for (final n in [crc, data.length, data.length]) {
      u32(local, n);
    }
    u16(local, filename.length);
    u16(local, 0);
    local.add(filename);
    local.add(data);
    u32(central, 0x02014b50);
    for (final n in [20, 20, 0, 0, 0, 0]) {
      u16(central, n);
    }
    for (final n in [crc, data.length, data.length]) {
      u32(central, n);
    }
    for (final n in [filename.length, 0, 0, 0, 0]) {
      u16(central, n);
    }
    u32(central, 0);
    u32(central, offset);
    central.add(filename);
  }
  final offset = local.length;
  final size = central.length;
  local.add(central.takeBytes());
  u32(local, 0x06054b50);
  u16(local, 0);
  u16(local, 0);
  u16(local, entries.length);
  u16(local, entries.length);
  u32(local, size);
  u32(local, offset);
  u16(local, 0);
  return local.takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 这些是本地 HttpServer 集成测试，不使用 binding 的 HTTP 400 stub。
  HttpOverrides.global = null;
  late Directory root;
  late HttpServer server;
  late DownloadService service;
  late List<int> zip;
  late Future<void> Function(HttpRequest) respond;
  late List<String?> ranges;

  File temp() => File(FilePathUtility.getZipTempFilePath('payload.zip'));
  Future<void> send(HttpRequest request, List<int> bytes,
      {int status = 200, String? range}) async {
    request.response.statusCode = status;
    if (range != null) request.response.headers.set('content-range', range);
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> download(
          {CancelToken? token, void Function(int, int)? onProgress}) =>
      service.startDownload(
        downloadUrl: 'http://127.0.0.1:${server.port}/payload.zip',
        saveDir: '${root.path}/staging',
        cancelToken: token ?? CancelToken(),
        onReceiveProgress: onProgress,
      );

  Future<void> expectInstalled() async {
    expect(
        await File('${FilePathUtility.getModuleCurrentDir()}/index.html')
            .readAsString(),
        'hello resume');
    expect(await temp().exists(), isFalse);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download_resume_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => root.path,
    );
    await FilePathUtility.initialize();
    service = DownloadService();
    final archive = Archive();
    for (final entry in {
      'version.json': jsonEncode({'version': 1}),
      'index.html': 'hello resume',
    }.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    zip = ZipEncoder().encode(archive);
    ranges = [];
    respond = (request) => send(request, zip);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      ranges.add(request.headers.value('range'));
      await respond(request);
    });
  });

  tearDown(() async {
    service.dispose();
    await server.close(force: true);
    await root.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
  });

  test('rejects remote digest and version mismatch without replacing current',
      () async {
    final old = File('${FilePathUtility.getModuleCurrentDir()}/old.txt');
    await old.writeAsString('old');
    for (final mismatch in [true, false]) {
      await expectLater(
          service.startDownload(
            downloadUrl: 'http://127.0.0.1:${server.port}/payload.zip',
            saveDir: '${root.path}/staging',
            cancelToken: CancelToken(),
            expectedMd5: mismatch ? '00000000000000000000000000000000' : null,
            expectedVersion: mismatch ? null : '99',
          ),
          throwsA(isA<ResourceException>()));
      expect(await old.readAsString(), 'old');
    }
  });

  test('rejects traversal, absolute and manifest paths', () async {
    for (final name in [
      '../escaped.js',
      '/absolute.js',
      r'C:\evil.js',
      'a/../../bad'
    ]) {
      final archive = Archive();
      final metadata = utf8.encode(jsonEncode({'version': 1}));
      archive.addFile(ArchiveFile('version.json', metadata.length, metadata));
      archive.addFile(ArchiveFile(name, 1, [1]));
      zip = ZipEncoder().encode(archive);
      await expectLater(download(), throwsA(isA<ValidationException>()));
    }
  });

  test('rejects missing entry and incomplete declared manifest', () async {
    for (final metadata in [
      {
        'version': 1,
        'modules': [
          {'key': 'one', 'entryHtml': 'missing.html'}
        ]
      },
      {
        'version': 1,
        'fileInfo': {'files': []}
      },
    ]) {
      final archive = Archive();
      final bytes = utf8.encode(jsonEncode(metadata));
      archive.addFile(ArchiveFile('version.json', bytes.length, bytes));
      archive.addFile(ArchiveFile('index.html', 1, [1]));
      zip = ZipEncoder().encode(archive);
      await expectLater(download(), throwsA(isA<ValidationException>()));
    }
  });

  test('enforces extraction count and byte limits', () async {
    service.dispose();
    service = DownloadService(maxEntries: 1);
    await expectLater(download(), throwsA(isA<ValidationException>()));
    service.dispose();
    service = DownloadService(maxExpandedBytes: 1);
    await expectLater(download(), throwsA(isA<ValidationException>()));
  });

  test('rejects symbolic link and special unix entry', () async {
    for (final mode in [0xa1ff, 0x11ff]) {
      final archive = Archive();
      final metadata = utf8.encode(jsonEncode({'version': 1}));
      archive.addFile(ArchiveFile('version.json', metadata.length, metadata));
      archive.addFile(ArchiveFile('special', 1, [1])..mode = mode);
      zip = ZipEncoder().encode(archive);
      await expectLater(download(), throwsA(isA<ValidationException>()));
    }
  });

  test('failed final rename restores previous current', () async {
    final old = File('${FilePathUtility.getModuleCurrentDir()}/old.txt');
    await old.writeAsString('old');
    await expectLater(
        service.startDownload(
          downloadUrl: 'http://127.0.0.1:${server.port}/payload.zip',
          saveDir: '${root.path}/staging',
          cancelToken: CancelToken(),
          publishExclusive: (publish) async {
            await Directory('${root.path}/staging/extracted')
                .delete(recursive: true);
            await publish();
          },
        ),
        throwsA(isA<StorageException>()));
    expect(await old.readAsString(), 'old');
  });

  test('rejects raw duplicate entry before Archive deduplication', () async {
    zip = rawZip([
      ('version.json', utf8.encode('{"version":1}')),
      ('index.html', utf8.encode('first')),
      ('index.html', utf8.encode('second')),
    ]);
    await expectLater(download(), throwsA(isA<ValidationException>()));
  });

  for (final responseMode in ['200', '206', '416']) {
    test('lazy CRC failure rejects $responseMode and keeps current', () async {
      zip = rawZip([
        ('version.json', utf8.encode('{"version":1}')),
        ('index.html', utf8.encode('hello'))
      ]);
      // STORE 条目的数据变更而不更新 CRC。
      final marker = utf8.encode('hello');
      var at = -1;
      for (var i = 0; i <= zip.length - marker.length; i++) {
        if (List.generate(marker.length, (j) => zip[i + j]).join(',') ==
            marker.join(',')) {
          at = i;
          break;
        }
      }
      zip[at] ^= 1;
      final old = File('${FilePathUtility.getModuleCurrentDir()}/old.txt');
      await old.writeAsString('old');
      if (responseMode == '416') {
        await temp().writeAsBytes(zip);
        respond =
            (r) => send(r, [], status: 416, range: 'bytes */${zip.length}');
      } else if (responseMode == '206') {
        await temp().writeAsBytes(zip.sublist(0, 10));
        respond = (r) => send(r, zip.sublist(10),
            status: 206, range: 'bytes 10-${zip.length - 1}/${zip.length}');
      }
      await expectLater(download(), throwsA(isA<ResourceException>()));
      expect(await old.readAsString(), 'old');
      expect(await temp().exists(), isFalse);
    });
  }

  test('rejects truncated archive and forged expanded size', () async {
    final valid = rawZip([
      ('version.json', utf8.encode('{"version":1}')),
      ('index.html', utf8.encode('hello'))
    ]);
    zip = valid.sublist(0, valid.length - 8);
    await expectLater(download(), throwsA(isA<ResourceException>()));
    zip = List.of(valid);
    // 篡改第二个 central header 的展开长度（local 声明与实际内容不变）。
    for (var i = 0; i < zip.length - 28; i++) {
      if (zip[i] == 0x50 &&
          zip[i + 1] == 0x4b &&
          zip[i + 2] == 1 &&
          zip[i + 3] == 2 &&
          zip[i + 28] == 10) {
        zip[i + 24] = 1;
      }
    }
    await expectLater(download(), throwsA(isA<ResourceException>()));
  });

  test('first complete download installs the ZIP', () async {
    final progress = <List<int>>[];
    await download(onProgress: (n, total) => progress.add([n, total]));
    expect(ranges, [null]);
    expect(progress.last, [zip.length, zip.length]);
    await expectInstalled();
  });

  test('206 appends only the verified remaining bytes', () async {
    const offset = 37;
    await temp().writeAsBytes(zip.sublist(0, offset));
    respond = (r) => send(r, zip.sublist(offset),
        status: 206, range: 'bytes $offset-${zip.length - 1}/${zip.length}');
    final progress = <List<int>>[];
    await download(onProgress: (n, total) => progress.add([n, total]));
    expect(ranges, ['bytes=$offset-']);
    expect(progress.last, [zip.length, zip.length]);
    await expectInstalled();
  });

  test('200 ignoring Range replaces stale prefix', () async {
    await temp().writeAsBytes(List.filled(37, 99));
    await download();
    expect(ranges, ['bytes=37-']);
    await expectInstalled();
  });

  for (final range in [
    null,
    'bytes 0-9/10',
    'bytes 37-40/100',
    'bytes 37-999/1000'
  ]) {
    test('invalid Content-Range $range preserves prefix', () async {
      final prefix = zip.sublist(0, 37);
      await temp().writeAsBytes(prefix);
      respond = (r) => send(r, zip.sublist(37), status: 206, range: range);
      await expectLater(download(), throwsA(isA<IntegrityException>()));
      expect(await temp().readAsBytes(), prefix);
    });
  }

  test('HTTP errors do not overwrite prefix', () async {
    final prefix = zip.sublist(0, 37);
    await temp().writeAsBytes(prefix);
    respond = (r) => send(r, utf8.encode('not found'), status: 404);
    await expectLater(download(), throwsA(isA<DioException>()));
    expect(await temp().readAsBytes(), prefix);
  });

  test('416 with exact size validates existing completed ZIP', () async {
    await temp().writeAsBytes(zip);
    respond = (r) => send(r, [], status: 416, range: 'bytes */${zip.length}');
    await download();
    expect(ranges, ['bytes=${zip.length}-']);
    await expectInstalled();
  });

  test('416 with stale size retries without Range once', () async {
    await temp().writeAsBytes(List.filled(zip.length + 5, 0));
    respond = (r) => ranges.length == 1
        ? send(r, [], status: 416, range: 'bytes */${zip.length}')
        : send(r, zip);
    await download();
    expect(ranges, ['bytes=${zip.length + 5}-', null]);
    await expectInstalled();
  });

  test('corrupt ZIP is removed so retry starts cleanly', () async {
    respond = (r) => send(r, utf8.encode('not a zip'));
    await expectLater(download(), throwsA(isA<IntegrityException>()));
    expect(await temp().exists(), isFalse);
    respond = (r) => send(r, zip);
    await download();
    expect(ranges, [null, null]);
    await expectInstalled();
  });

  test('short chunked 206 retains prefix and resumes on retry', () async {
    await temp().writeAsBytes(zip.sublist(0, 37));
    respond = (r) async {
      r.response.statusCode = 206;
      r.response.headers
          .set('content-range', 'bytes 37-${zip.length - 1}/${zip.length}');
      r.response.add(zip.sublist(37, 70));
      await r.response.close();
    };
    await expectLater(download(), throwsA(isA<IntegrityException>()));
    expect(await temp().readAsBytes(), zip.sublist(0, 70));
    respond = (r) => send(r, zip.sublist(70),
        status: 206, range: 'bytes 70-${zip.length - 1}/${zip.length}');
    await download();
    expect(ranges, ['bytes=37-', 'bytes=70-']);
    await expectInstalled();
  });

  test('network disconnect retains written bytes for retry', () async {
    final received = Completer<void>();
    respond = (r) async {
      final socket = await r.response.detachSocket(writeHeaders: false);
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
          'Content-Length: ${zip.length}\r\nConnection: close\r\n\r\n'));
      socket.add(zip.sublist(0, 70));
      await socket.flush();
      await received.future;
      socket.destroy();
    };
    await expectLater(download(onProgress: (n, _) {
      if (n >= 70 && !received.isCompleted) received.complete();
    }), throwsA(anything));
    expect(await temp().readAsBytes(), zip.sublist(0, 70));
    respond = (r) => send(r, zip.sublist(70),
        status: 206, range: 'bytes 70-${zip.length - 1}/${zip.length}');
    await download();
    await expectInstalled();
  });

  test('cancellation preserves written bytes and keeps cancel exception',
      () async {
    final token = CancelToken();
    final released = Completer<void>();
    respond = (r) async {
      final socket = await r.response.detachSocket(writeHeaders: false);
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
          'Content-Length: ${zip.length}\r\nConnection: close\r\n\r\n'));
      socket.add(zip.sublist(0, 70));
      await socket.flush();
      await released.future;
      socket.destroy();
    };
    await expectLater(
        download(
            token: token,
            onProgress: (n, _) {
              if (n >= 70) token.cancel('test cancellation');
            }),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)));
    released.complete();
    expect(await temp().readAsBytes(), zip.sublist(0, 70));
    respond = (r) => send(r, zip.sublist(70),
        status: 206, range: 'bytes 70-${zip.length - 1}/${zip.length}');
    await download();
    await expectInstalled();
  });

  test('416 completed but corrupt ZIP is discarded before next retry',
      () async {
    await temp().writeAsBytes(List.filled(zip.length, 0));
    respond = (r) => send(r, [], status: 416, range: 'bytes */${zip.length}');
    await expectLater(download(), throwsA(isA<IntegrityException>()));
    expect(await temp().exists(), isFalse);
    respond = (r) => send(r, zip);
    await download();
    expect(ranges.last, isNull);
    await expectInstalled();
  });

  test('repeated 416 is bounded and preserves old prefix', () async {
    final prefix = zip.sublist(0, 37);
    await temp().writeAsBytes(prefix);
    respond = (r) => send(r, [], status: 416, range: 'bytes */${zip.length}');
    await expectLater(download(), throwsA(isA<IntegrityException>()));
    expect(ranges, ['bytes=37-', null]);
    expect(await temp().readAsBytes(), prefix);
  });

  test('oversized chunked 206 rolls back the response bytes', () async {
    final prefix = zip.sublist(0, 37);
    await temp().writeAsBytes(prefix);
    respond = (r) async {
      r.response.statusCode = 206;
      r.response.headers.set('content-range', 'bytes 37-39/40');
      r.response.add(zip.sublist(37, 70));
      await r.response.close();
    };
    await expectLater(download(), throwsA(isA<IntegrityException>()));
    expect(await temp().readAsBytes(), prefix);
  });

  test('pre-cancelled request never touches existing prefix', () async {
    await temp().writeAsBytes(zip.sublist(0, 37));
    final token = CancelToken()..cancel();
    await expectLater(download(token: token), throwsA(isA<DioException>()));
    expect(await temp().readAsBytes(), zip.sublist(0, 37));
    expect(ranges, isEmpty);
  });
}
