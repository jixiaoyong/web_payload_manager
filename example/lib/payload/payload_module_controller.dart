import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

/// 监听单个模块的资源状态。
class PayloadModuleController extends ChangeNotifier {
  PayloadModuleController(this.moduleKey);

  final String moduleKey;
  ResourceState state = const ResourceState.loading();
  StreamSubscription<ResourceState>? _subscription;

  Future<void> start() async {
    await _subscription?.cancel();
    state = const ResourceState.loading();
    notifyListeners();

    _subscription =
        WebPayloadManager.getInstance().getModuleStateStream(moduleKey).listen(
      (next) {
        state = next;
        notifyListeners();
      },
      onError: (error) {
        state = ResourceState.error(
          message: error.toString(),
          severity: ErrorSeverity.critical,
        );
        notifyListeners();
      },
    );
  }

  Future<void> retry() async {
    await start();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
