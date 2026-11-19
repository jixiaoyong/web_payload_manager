import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

import 'config/app_config.dart';

Future<String> resolveUpdateUrl() async {
  if (AppConfig.isRemoteUpdateConfigured(AppConfig.defaultUpdateUrl)) {
    return AppConfig.defaultUpdateUrl;
  }
  final prefs = await SharedPreferences.getInstance();
  final cached = prefs.getString(AppConfig.cachedUpdateUrlKey)?.trim();
  if (cached != null && cached.isNotEmpty) {
    return cached;
  }
  return AppConfig.defaultUpdateUrl;
}

Future<void> initializeWebPayloadManager() async {
  final updateUrl = await resolveUpdateUrl();
  final manager = WebPayloadManager.getInstance();
  await manager.initialize(
    updateUrl: updateUrl,
    webAssetBaseDir: AppConfig.webAssetBaseDir,
    dio: Dio(),
    syncOnStart: AppConfig.isRemoteUpdateConfigured(updateUrl),
    syncOnEachModuleStart: false,
    debugLogRequests: true,
  );
}

Future<void> restartWebPayloadManager() async {
  final manager = WebPayloadManager.getInstance();
  await manager.dispose();
  await initializeWebPayloadManager();
}
