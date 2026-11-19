import 'dart:io';

import 'package:dio/dio.dart';

import 'web_payload_models.dart';

/// exception_handler.dart
/// 异常定义和处理

// ============ Base Exception ============

/// 所有离线包加载、校验与存储异常的统一基类。
abstract class ResourceException implements Exception {
  /// 可读错误描述。
  final String message;

  /// 错误严重程度分级。
  final ErrorSeverity severity;

  /// 原始底层异常（若有）。
  final Exception? originalException;

  /// 创建基础资源异常。
  ResourceException({
    required this.message,
    required this.severity,
    this.originalException,
  });

  @override
  String toString() => message;
}

// ============ Specific Exceptions ============

/// 网络请求失败、连接中断或下载取消异常（可重试）。
class NetworkException extends ResourceException {
  /// 创建网络异常。
  NetworkException({
    required super.message,
    super.originalException,
  }) : super(
          severity: ErrorSeverity.recoverable,
        );
}

/// 版本检查或文件下载超时异常（可重试）。
class TimeoutException extends ResourceException {
  /// 创建超时异常。
  TimeoutException({
    required super.message,
    super.originalException,
  }) : super(
          severity: ErrorSeverity.recoverable,
        );
}

/// 清单结构、安全约束或版本兼容性校验失败异常。
class ValidationException extends ResourceException {
  /// 创建校验异常。
  ValidationException({
    required super.message,
    super.originalException,
  }) : super(
          severity: ErrorSeverity.validation,
        );
}

/// 本地文件系统读写、权限不足或磁盘空间异常。
class StorageException extends ResourceException {
  /// 创建存储异常。
  StorageException({
    required super.message,
    super.originalException,
  }) : super(
          severity: ErrorSeverity.critical,
        );
}

/// 离线包或单文件 MD5 摘要不一致导致的完整性异常。
class IntegrityException extends ResourceException {
  /// 创建完整性校验异常。
  IntegrityException({
    required super.message,
    super.originalException,
  }) : super(
          severity: ErrorSeverity.validation,
        );
}

// ============ Exception Helper ============

/// 将底层 [DioException]、[FileSystemException] 等统一映射为 [ResourceException]。
ResourceException mapToResourceException(
  dynamic exception,
  String defaultMessage,
) {
  if (exception is DioException) {
    if (exception.type == DioExceptionType.cancel) {
      // 用户取消,返回特殊的 recoverable 异常(但不会自动重试)
      return NetworkException(
        message: 'Download cancelled by user',
        originalException: exception,
      );
    } else if (exception.type == DioExceptionType.connectionTimeout ||
        exception.type == DioExceptionType.receiveTimeout) {
      return TimeoutException(
        message: 'Download timeout: $defaultMessage',
        originalException: exception,
      );
    } else {
      return NetworkException(
        message: 'Network error: ${exception.message}',
        originalException: exception,
      );
    }
  } else if (exception is FileSystemException) {
    return StorageException(
      message: 'Storage error: $defaultMessage',
      originalException: exception as Exception,
    );
  } else if (exception is ValidationException) {
    return exception;
  } else if (exception is ResourceException) {
    return exception;
  } else {
    return NetworkException(
      message: defaultMessage,
      originalException: exception as Exception?,
    );
  }
}
