import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/local_web_server.dart';

void main() {
  group('LocalWebServer', () {
    late LocalWebServer server;
    late Directory tempDir;

    setUp(() async {
      server = LocalWebServer();
      tempDir = await Directory.systemTemp.createTemp('wps_local_server_test_');
      await File('${tempDir.path}/index.html').writeAsString('<html>ok</html>');
      await File('${tempDir.path}/data.json').writeAsString('{"ok":true}');
      await File('${tempDir.path}/secret.exe').writeAsString('blocked');
      await server.start();
      server.registerModuleRoot(tempDir.path);
    });

    tearDown(() async {
      await server.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('getAuthUserAgent contains token prefix after start', () {
      final ua = server.getAuthUserAgent();
      expect(ua, startsWith('WebPayloadManager/'));
      expect(ua.length, greaterThan('WebPayloadManager/'.length));
    });

    test('checkHealth succeeds with internal auth token', () async {
      expect(await server.checkHealth(), isTrue);
    });

    test('serves allowed file with valid user agent auth', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse(server.getModuleUrl('index.html')),
        );
        request.headers.set('user-agent', server.getAuthUserAgent());
        final response = await request.close();
        final body =
            await response.transform(const SystemEncoding().decoder).join();

        expect(response.statusCode, HttpStatus.ok);
        expect(body, contains('ok'));
      } finally {
        client.close(force: true);
      }
    });

    test('self-heal restart preserves URL, credential and registered root',
        () async {
      final url = server.getModuleUrl('index.html');
      final ua = server.getAuthUserAgent();
      final oldPort = server.port;
      await server.stop(preserveSession: true);
      await server.start(port: oldPort);
      expect(server.getModuleUrl('index.html'), url);
      expect(server.getAuthUserAgent(), ua);
      expect(await server.checkHealth(), isTrue);
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('user-agent', ua);
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        expect(await response.transform(const SystemEncoding().decoder).join(),
            contains('ok'));
      } finally {
        client.close(force: true);
      }
    });

    test('normal stop clears session and unregistered root is unhealthy',
        () async {
      final token = server.authToken;
      await server.stop();
      await server.start();
      expect(server.authToken, isNot(token));
      expect(await server.checkHealth(), isFalse);
      server.registerModuleRoot(tempDir.path);
      expect(await server.checkHealth(), isTrue);
    });

    test('missing registered root is unhealthy', () async {
      server.registerModuleRoot('${tempDir.path}/missing');
      expect(await server.checkHealth(), isFalse);
    });

    test('port conflict retry retains session', () async {
      final oldPort = server.port;
      final ua = server.getAuthUserAgent();
      await server.stop(preserveSession: true);
      final blocker =
          await HttpServer.bind(InternetAddress.loopbackIPv4, oldPort);
      try {
        await expectLater(
            server.start(port: oldPort), throwsA(isA<SocketException>()));
        await server.start(port: 0);
        expect(server.port, isNot(oldPort));
        expect(server.getAuthUserAgent(), ua);
        expect(await server.checkHealth(), isTrue);
      } finally {
        await blocker.close(force: true);
      }
    });

    test('expired credentials are renewed during preserved restart', () async {
      server.refreshAuthToken(const Duration(seconds: -1));
      final oldToken = server.authToken;
      expect(await server.checkHealth(), isFalse);
      final oldPort = server.port;
      await server.stop(preserveSession: true);
      await server.start(port: oldPort);
      expect(server.authToken, isNot(oldToken));
      expect(await server.checkHealth(), isTrue);
    });

    test('rejects unauthorized request', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse(server.getModuleUrl('index.html')),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.unauthorized);
      } finally {
        client.close(force: true);
      }
    });

    test('rejects invalid host header even with valid auth', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse(server.getModuleUrl('index.html')),
        );
        request.headers.set('user-agent', server.getAuthUserAgent());
        request.headers.set('host', 'evil.example.com');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.forbidden);
      } finally {
        client.close(force: true);
      }
    });

    test('rejects path traversal', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/../secret.txt'),
        );
        request.headers.set('user-agent', server.getAuthUserAgent());
        final response = await request.close();
        expect(response.statusCode,
            anyOf(HttpStatus.forbidden, HttpStatus.notFound));
      } finally {
        client.close(force: true);
      }
    });

    test('rejects disallowed file extension', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse(server.getModuleUrl('secret.exe')),
        );
        request.headers.set('user-agent', server.getAuthUserAgent());
        final response = await request.close();
        expect(response.statusCode, HttpStatus.forbidden);
      } finally {
        client.close(force: true);
      }
    });
  });
}
