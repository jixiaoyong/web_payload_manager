// 版本检测服务

import 'package:dio/dio.dart';
import 'exception_handler.dart';

import 'util/logger.dart';
import 'version_parser.dart';
import 'web_payload_models.dart';

/// 远端离线包版本清单拉取与解析服务。
class VersionCheckService {
  final Dio _dio;
  final String _updateUrl;
  final VersionInfoParser _parser;

  /// 创建版本检测服务实例。
  VersionCheckService({
    required String updateUrl,
    Dio? dio,
    VersionInfoParser? parser,
    int timeoutMs = 15000,
  })  : _updateUrl = updateUrl,
        _dio = dio ?? Dio(),
        _parser = parser ?? const StandardVersionParser() {
    _dio.options.connectTimeout = Duration(milliseconds: timeoutMs);
    _dio.options.receiveTimeout = Duration(milliseconds: timeoutMs);
  }

  /// 获取配置的版本解析器
  VersionInfoParser get parser => _parser;

  /// 获取最新的版本信息
  /// 返回 WebVersionInfoBean 或 null (如果模块不存在) 或抛出异常
  Future<WebVersionInfoBean?> getLatestModule() async {
    try {
      final response = await _dio.get<dynamic>(_updateUrl,
          options: Options(followRedirects: false));

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw NetworkException(
          message: 'Failed to fetch module: ${response.statusCode}',
        );
      }

      if (response.data == null) {
        throw ValidationException(
          message: 'Invalid response format: missing response body',
        );
      }

      return _parser.parse(response.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw TimeoutException(
          message: 'Timeout while fetching module',
          originalException: e,
        );
      } else {
        throw NetworkException(
          message: 'Network error: ${e.message}',
          originalException: e,
        );
      }
    } catch (e) {
      if (e is ResourceException) rethrow;
      throw NetworkException(
        message: 'Failed to fetch module: $e',
        originalException: e as Exception?,
      );
    }
  }

  /// 上报模块加载统计（可选扩展）
  /// 用于服务端收集用户行为数据
  Future<void> reportModuleStats({
    required String key,
    required dynamic version,
    required bool success,
    required int durationMs,
    String? errorMessage,
  }) async {
    try {
      await _dio.post<String>(
        '$_updateUrl/stats/module',
        data: {
          'key': key,
          'version': version?.toString(),
          'success': success,
          'durationMs': durationMs,
          'errorMessage': errorMessage,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } catch (e) {
      // 统计报告失败不应该影响主流程
      logger.w('Warning: Failed to report module stats: $e');
    }
  }

  /// 销毁资源
  void dispose() {
    _dio.close();
  }
}
