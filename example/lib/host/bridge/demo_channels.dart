import 'dart:io';

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import 'bridge_registry.dart';
import 'web_js_channel.dart';

typedef PaymentHandler = Future<Map<String, dynamic>> Function(
  String payType,
  String orderId,
  String amount,
);

/// 注册 Example 演示用通道（仅展示 Bridge 调用模式）。
void registerDemoChannels({
  required BridgeRegistry registry,
  required VoidCallback onClosePage,
  required void Function(String message) onToast,
  Future<void> Function(String title, String content)? onShowNativeModal,
  PaymentHandler? onPayment,
}) {
  registry.registerAll([
    WebJsChannel(
      name: 'DemoEcho',
      version: 1,
      callback: (data) async {
        if (data is Map) {
          return {'echo': data};
        }
        return {'echo': data?.toString()};
      },
    ),
    WebJsChannel(
      name: 'DemoHostInfo',
      version: 1,
      callback: (_) async => {
        'platform': Platform.operatingSystem,
        'hostAppId': AppConfig.hostAppId,
      },
    ),
    WebJsChannel(
      name: 'DemoToast',
      version: 1,
      callback: (data) async {
        final message = _readMessage(data) ?? 'Hello from host';
        onToast(message);
        return {'ok': true};
      },
    ),
    WebJsChannel(
      name: 'DemoNativeModal',
      version: 1,
      callback: (data) async {
        final title = (data is Map && data['title'] != null)
            ? data['title'].toString()
            : '原生 Modal 弹窗';
        final content = (data is Map && data['content'] != null)
            ? data['content'].toString()
            : '测试 iOS 弹窗遮盖后手势释放与点击响应';
        if (onShowNativeModal != null) {
          await onShowNativeModal(title, content);
        } else {
          onToast('$title: $content');
        }
        return {'ok': true};
      },
    ),
    WebJsChannel(
      name: 'DemoPayment',
      version: 1,
      callback: (data) async {
        final map = (data is Map) ? data : {};
        final payType = map['payType']?.toString() ?? 'apple_pay';
        final orderId = map['orderId']?.toString() ?? 'ORD-001';
        final amount = map['amount']?.toString() ?? '0.01';

        if (onPayment != null) {
          return await onPayment(payType, orderId, amount);
        }

        return {
          'status': 'success',
          'payType': payType,
          'orderId': orderId,
          'message': '默认模拟支付成功',
        };
      },
    ),
    WebJsChannel(
      name: 'DemoClosePage',
      version: 1,
      callback: (_) async {
        onClosePage();
        return {'ok': true};
      },
    ),
    WebJsChannel(
      name: 'AppBridgeMeta',
      version: 1,
      callback: (_) async => registry.buildMetaMap(),
    ),
  ]);
}

String? _readMessage(dynamic data) {
  if (data is String) {
    return data;
  }
  if (data is Map) {
    final msg = data['message'];
    if (msg != null) {
      return msg.toString();
    }
  }
  return null;
}
