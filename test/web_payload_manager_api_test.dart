import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/web_payload_manager.dart';
import 'package:web_payload_manager/src/local_web_server.dart';

class RecoveryServer extends LocalWebServer {
  bool changePort = false;
  bool failHealth = false;
  @override
  Future<bool> checkHealth(
          {Duration timeout = const Duration(seconds: 2)}) async =>
      failHealth ? false : await super.checkHealth(timeout: timeout);
  @override
  Future<void> start(
      {int? port, Duration tokenValidFor = const Duration(days: 7)}) async {
    if (changePort) {
      refreshAuthToken();
      if (port != null && port != 0) {
        throw const SocketException('injected port conflict');
      }
      failHealth = false;
    }
    return super.start(port: port, tokenValidFor: tokenValidFor);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = WebPayloadManager.getInstance();

  test('getModuleStateStream throws before initialization', () {
    expect(
        () => manager.getModuleStateStream('one'), throwsA(isA<StateError>()));
  });

  group('module subscription lifecycle', () {
    late Directory dir;
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    Future<void> writePayload(String type, int version) async {
      final root = Directory('${dir.path}/$type');
      await root.create(recursive: true);
      await File('${root.path}/version.json').writeAsString(jsonEncode({
        'version': version,
        'modules': [
          {'key': 'one', 'entryHtml': 'index.html'},
          {'key': 'two', 'entryHtml': 'index.html'},
        ],
      }));
      await File('${root.path}/index.html').writeAsString('$type-$version');
    }

    Future<String> readUrl(String url, String userAgent) async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('user-agent', userAgent);
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        return await response.transform(utf8.decoder).join();
      } finally {
        client.close(force: true);
      }
    }

    Future<void> waitFor(bool Function() predicate) async {
      for (var i = 0; i < 200; i++) {
        if (predicate()) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('Timed out waiting for module state');
    }

    setUp(() async {
      HttpOverrides.global = null;
      dir = await Directory.systemTemp.createTemp('wpm_manager_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => dir.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (message) async {
        final key = utf8.decode(message!.buffer.asUint8List());
        if (key == 'AssetManifest.json') {
          return ByteData.sublistView(utf8.encode('{}'));
        }
        return null;
      });
      await writePayload('default', 1);
      await writePayload('current', 2);
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          h.resolve(Response(requestOptions: o, data: null, statusCode: 200));
        }));
      await manager.initialize(
        updateUrl: 'https://example.invalid/version.json',
        webAssetBaseDir: 'assets/test',
        dio: dio,
        syncOnStart: false,
        syncOnEachModuleStart: false,
      );
    });

    tearDown(() async {
      await manager.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
      await dir.delete(recursive: true);
    });

    test('background update keeps local Data and activates explicitly',
        () async {
      await manager.dispose();
      final gate = Completer<void>();
      final archive = Archive();
      for (final item in {
        'version.json': jsonEncode({
          'version': 3,
          'modules': [
            {'key': 'one', 'entryHtml': 'index.html'}
          ]
        }),
        'index.html': 'updated-3',
      }.entries) {
        final bytes = utf8.encode(item.value);
        archive.addFile(ArchiveFile(item.key, bytes.length, bytes));
      }
      final zip = ZipEncoder().encode(archive);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/version.json') {
          await gate.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'version': 3,
            'downloadUrl': 'http://127.0.0.1:${server.port}/payload.zip',
            'md5': md5.convert(zip).toString()
          }));
        } else {
          request.response.add(zip);
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      await manager.initialize(
          updateUrl: 'http://127.0.0.1:${server.port}/version.json',
          webAssetBaseDir: 'assets/test',
          syncOnStart: true,
          syncOnEachModuleStart: false);
      final states = <ResourceState>[];
      final sub = manager.getModuleStateStream('one').listen(states.add);
      addTearDown(sub.cancel);
      await waitFor(() => states.any((s) => s is Data));
      final first = states.whereType<Data>().last;
      final ua = manager.getAuthUserAgent();
      expect(await readUrl(first.data, ua), 'current-2');
      gate.complete();
      await waitFor(() => manager.payloadSyncState is SyncCompleted);
      expect(states.last, isA<Data>());
      expect(states.whereType<Data>(), hasLength(1));
      expect(manager.availableVersion, '3');
      expect(await readUrl(first.data, ua), 'current-2');
      await manager.activateAvailableUpdate();
      await waitFor(() => states.whereType<Data>().length == 2);
      final next = states.whereType<Data>().last;
      expect(next.version, '3');
      expect(next.data, isNot(first.data));
      expect(await readUrl(next.data, ua), 'updated-3');
      expect(await readUrl(first.data, ua), 'current-2');

      final syncStates = <PayloadSyncState>[];
      final syncSub = manager.payloadSyncStateStream.listen(syncStates.add);
      addTearDown(syncSub.cancel);
      expect(manager.availableVersion, '3');
      expect(manager.payloadSyncState, isA<SyncCompleted>());
      await manager.rollbackToDefault();
      await waitFor(() =>
          states.whereType<Data>().length == 3 &&
          syncStates.any((state) => state is SyncIdle));
      expect(manager.availableVersion, isNull);
      expect(manager.payloadSyncState, isA<SyncIdle>());
      expect(syncStates.last, isA<SyncIdle>());
      final fallback = states.whereType<Data>().last;
      expect(fallback.version, '1');
      expect(await readUrl(fallback.data, ua), 'default-1');
    });

    for (final hostVersion in <String?>[null, '1.0.0']) {
      test(
          'minAppVersion rejects incompatible host $hostVersion without blocking local',
          () async {
        await manager.dispose();
        final dio = Dio()
          ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
            h.resolve(Response(requestOptions: o, statusCode: 200, data: {
              'version': 9,
              'minAppVersion': '2.0.0',
              'forceUpdate': true,
              'downloadUrl': 'https://example.invalid/payload.zip',
            }));
          }));
        await manager.initialize(
            updateUrl: 'https://example.invalid/version.json',
            webAssetBaseDir: 'assets/test',
            dio: dio,
            hostAppVersion: hostVersion,
            syncOnStart: true,
            syncOnEachModuleStart: false);
        final states = <ResourceState>[];
        final sub = manager.getModuleStateStream('one').listen(states.add);
        addTearDown(sub.cancel);
        await waitFor(() => states.any((s) => s is Data));
        await waitFor(() => manager.payloadSyncState is SyncFailed);
        expect(states.last, isA<Data>());
        expect((states.last as Data).version, '2');
        expect(manager.availableVersion, isNull);
      });
    }

    test('empty update URL permits built-in mode and reload without network',
        () async {
      await manager.dispose();
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          requests++;
          h.reject(DioException(requestOptions: o));
        }));
      await manager.initialize(
          updateUrl: '',
          webAssetBaseDir: 'assets/test',
          dio: dio,
          syncOnStart: false,
          syncOnEachModuleStart: false);
      final states = <Data>[];
      final sub = manager.getModuleStateStream('one').listen((s) {
        if (s is Data) states.add(s);
      });
      addTearDown(sub.cancel);
      await waitFor(() => states.isNotEmpty);
      await manager.reLoad();
      expect(requests, 0);
      expect(manager.payloadSyncState, isA<SyncIdle>());
    });

    test(
        'health recovery notifies changed port and token while preserving session',
        () async {
      await manager.dispose();
      final server = RecoveryServer();
      await manager.initialize(
          updateUrl: '',
          webAssetBaseDir: 'assets/test',
          syncOnStart: false,
          syncOnEachModuleStart: false,
          localWebServer: server);
      final states = <Data>[];
      final sub = manager.getModuleStateStream('one').listen((s) {
        if (s is Data) states.add(s);
      });
      addTearDown(sub.cancel);
      await waitFor(() => states.isNotEmpty);
      final first = states.last;
      final previousUa = manager.getAuthUserAgent();
      server.changePort = true;
      server.failHealth = true;
      await manager.ensureLocalWebServerHealthy();
      await waitFor(() => states.length == 2);
      expect(manager.getAuthUserAgent(), isNot(previousUa));
      expect(Uri.parse(states.last.data).path, Uri.parse(first.data).path);
      expect(states.last.version, first.version);
      expect(await readUrl(states.last.data, manager.getAuthUserAgent()),
          'current-2');
    });

    test('retryDelayMs controls exponential download retry', () async {
      await manager.dispose();
      final attempts = <DateTime>[];
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          if (o.uri.path.endsWith('version.json')) {
            h.resolve(Response(requestOptions: o, statusCode: 200, data: {
              'version': 3,
              'downloadUrl': 'https://example.invalid/payload.zip',
            }));
          } else {
            attempts.add(DateTime.now());
            h.reject(DioException(
                requestOptions: o, type: DioExceptionType.connectionError));
          }
        }));
      await manager.initialize(
          updateUrl: 'https://example.invalid/version.json',
          webAssetBaseDir: 'assets/test',
          dio: dio,
          maxRetries: 2,
          retryDelayMs: 30,
          syncOnStart: true,
          syncOnEachModuleStart: false);
      await waitFor(() => manager.payloadSyncState is SyncFailed);
      expect(attempts, hasLength(3));
      expect(attempts[1].difference(attempts[0]).inMilliseconds,
          greaterThanOrEqualTo(25));
      expect(attempts[2].difference(attempts[1]).inMilliseconds,
          greaterThanOrEqualTo(55));
    });

    test('same subscription receives initial load, reload and rollback',
        () async {
      final values = <Data>[];
      var done = false;
      final sub = manager.getModuleStateStream('one').listen((s) {
        if (s is Data) values.add(s);
      }, onDone: () => done = true);
      await waitFor(() => values.isNotEmpty);
      final ua = manager.getAuthUserAgent();
      expect(await readUrl(values.last.data, ua), 'current-2');
      await manager.reLoad();
      await waitFor(() => values.length == 2);
      await manager.rollbackToDefault();
      await waitFor(() => values.length == 3);
      expect(done, isFalse);
      expect(await readUrl(values.last.data, ua), 'default-1');
      await sub.cancel();
    });

    test('rollback updates serving root without any subscription', () async {
      final values = <Data>[];
      final sub = manager.getModuleStateStream('one').listen((s) {
        if (s is Data) values.add(s);
      });
      await waitFor(() => values.isNotEmpty);
      final url = values.last.data;
      final ua = manager.getAuthUserAgent();
      await sub.cancel();
      await manager.rollbackToDefault();
      // 回滚不再改变旧页面会话；新订阅才进入 default。
      expect(await readUrl(url, ua), 'current-2');
    });

    test('cancel during reload and replace subscription safely', () async {
      final values = <Data>[];
      final sub = manager.getModuleStateStream('one').listen((s) {
        if (s is Data) values.add(s);
      });
      await waitFor(() => values.isNotEmpty);
      final reload = manager.reLoad();
      await sub.cancel();
      final next = <Data>[];
      final replacement = manager.getModuleStateStream('one').listen((s) {
        if (s is Data) next.add(s);
      });
      await reload;
      await waitFor(() => next.isNotEmpty);
      await replacement.cancel();
    });

    test('loadSnapshot falls back to default when current is corrupted',
        () async {
      // 故意破坏 current 目录下的入口文件 index.html
      final currentEntry =
          File('${FilePathUtility.getModuleCurrentDir()}/index.html');
      if (await currentEntry.exists()) {
        await currentEntry.delete();
      }

      final values = <Data>[];
      final sub = manager.getModuleStateStream('one').listen((s) {
        if (s is Data) values.add(s);
      });
      await waitFor(() => values.isNotEmpty);

      // 验证透明兜底到了 default 内置包 (default-1)
      final ua = manager.getAuthUserAgent();
      expect(await readUrl(values.last.data, ua), 'default-1');
      await sub.cancel();
    });

    test('dispose closes multiple active streams without map mutation',
        () async {
      final done = <String>[];
      manager
          .getModuleStateStream('one')
          .listen((_) {}, onDone: () => done.add('one'));
      manager
          .getModuleStateStream('two')
          .listen((_) {}, onDone: () => done.add('two'));
      await manager.dispose();
      await waitFor(() => done.length == 2);
      expect(() => manager.getModuleStateStream('one'), throwsStateError);
    });
  });
}
