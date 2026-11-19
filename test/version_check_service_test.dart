import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_payload_manager/src/exception_handler.dart';
import 'package:web_payload_manager/src/version_check_service.dart';

void main() {
  group('VersionCheckService.getLatestModule', () {
    test('accepts business code 0', () async {
      final dio = Dio()
        ..httpClientAdapter = _FakeAdapter((_) async {
          return ResponseBody.fromString(
            '{"code":0,"message":"Success","data":{"zipUrl":"http://localhost/payload.zip","version":2,"md5":"abc","fileSize":100}}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });

      final service = VersionCheckService(
        updateUrl: 'http://localhost/check-update',
        dio: dio,
      );

      final result = await service.getLatestModule();
      expect(result, isNotNull);
      expect(result!.version, 2);
      expect(result.zipUrl, contains('payload.zip'));
      service.dispose();
    });

    test('accepts business code 200', () async {
      final dio = Dio()
        ..httpClientAdapter = _FakeAdapter((_) async {
          return ResponseBody.fromString(
            '{"code":200,"message":"Success","data":{"zipUrl":"http://localhost/payload.zip","version":3,"md5":"abc","fileSize":100}}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });

      final service = VersionCheckService(
        updateUrl: 'http://localhost/check-update',
        dio: dio,
      );

      final result = await service.getLatestModule();
      expect(result, isNotNull);
      expect(result!.version, 3);
      service.dispose();
    });

    test('throws validation exception when data is missing', () async {
      final dio = Dio()
        ..httpClientAdapter = _FakeAdapter((_) async {
          return ResponseBody.fromString(
            '{"code":0,"message":"Success"}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });

      final service = VersionCheckService(
        updateUrl: 'http://localhost/check-update',
        dio: dio,
      );

      await expectLater(
        service.getLatestModule(),
        throwsA(isA<ValidationException>()),
      );
      service.dispose();
    });
  });
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options);
  }
}
