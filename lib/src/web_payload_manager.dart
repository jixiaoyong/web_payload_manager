// 核心协调管理器 (Facade Layer)

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'download_service.dart';
import 'exception_handler.dart';
import 'file_path_utility.dart';
import 'local_web_server.dart';
import 'util/asset_sync_utility.dart';
import 'util/logger.dart';
import 'version_check_service.dart';
import 'version_parser.dart';
import 'web_payload_models.dart';

/// Convenience getter for the singleton [WebPayloadManager] instance.
WebPayloadManager get webPayloadManager => WebPayloadManager.getInstance();

/// Core facade managing versioned offline web payloads, background updates,
/// integrity verification, and local loopback HTTP hosting.
class WebPayloadManager {
  static WebPayloadManager? _instance;

  late DownloadService _downloadService;
  late VersionCheckService _versionCheckService;
  late LocalWebServer _localWebServer;

  // 状态 Controllers
  final Map<String, StreamController<ResourceState>> _controllers = {};

  // 全局资源包同步状态
  PayloadSyncState _payloadSyncState = const PayloadSyncState.idle();
  StreamController<PayloadSyncState> _payloadSyncStateController =
      StreamController<PayloadSyncState>.broadcast();

  // 全局下载任务锁
  Future<void>? _globalDownloadTask;
  CancelToken? _globalCancelToken;

  Future<void>? _ensureWebServerTask;
  Future<void> _payloadAccess = Future.value();

  Future<void> _withPayloadAccess(Future<void> Function() action) {
    final task = _payloadAccess.then((_) => action());
    _payloadAccess = task.catchError((_) {});
    return task;
  }

  late int _maxRetries;
  late int _retryDelayMs;
  String? _hostAppVersion;
  bool _hasUpdateSource = false;
  final Map<String, String> _snapshots = {};
  final Map<String, Data> _activeSessions = {};
  String? _availableVersion;

  /// 最近通过校验的可用版本；完成同步不代表已打开页面已切换。
  String? get availableVersion => _availableVersion;

  /// 显式激活当前可用包，为所有订阅派发新的不可变会话 URL。
  /// 宿主应在安全时机调用，并重载 WebView；旧 URL 继续绑定旧快照。
  Future<void> activateAvailableUpdate() async {
    await _ensureWebServerRunning();
    for (final entry in _controllers.entries.toList()) {
      await _loadCurrentOrDefault(entry.key, entry.value);
    }
  }

  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _syncOnEachModuleStart = true;

  WebPayloadManager._internal();

  static bool _isDevHttp(Uri uri) =>
      uri.scheme == 'http' &&
      (uri.host == '127.0.0.1' ||
          uri.host == 'localhost' ||
          uri.host == '10.0.2.2' ||
          uri.host.startsWith('192.168.') ||
          uri.host.startsWith('10.') ||
          uri.host.startsWith('172.'));

  String webAssetDir = '';

  /// 获取单例实例
  static WebPayloadManager getInstance() {
    _instance ??= WebPayloadManager._internal();
    return _instance!;
  }

  /// 初始化服务
  /// 必须在使用前调用
  /// - [updateUrl]: 更新 URL；两个自动同步开关均关闭时允许空字符串，且手动重载也不联网。
  /// - [localWebServer]: 可注入本地服务器以便宿主适配和恢复故障测试；默认自动创建。
  /// - [webAssetBaseDir]: 本地的网页资源模块,文件目录和[updateUrl]的资源目录一致.
  /// 如果是作为 path 依赖的子包，可使用 packages 前缀路径，如：'packages/your_app/assets/web_modules'
  /// 如果是宿主 App，使用：'assets/web_modules'
  /// - [maxRetries]: 最大重试次数.
  /// - [retryDelayMs]: 首次重试延迟(毫秒),之后按指数退避 (默认2000).
  /// - [hostAppVersion]: 宿主版本；远端声明 minAppVersion 时必须提供且满足要求。
  /// - [dio]: (可选) 自定义的 Dio 实例,用于网络请求.
  /// - [versionParser]: (可选) 自定义版本解析器, 默认使用 [StandardVersionParser], 支持静态根 JSON 与传统业务包裹结构.
  /// - [syncOnStart]: (可选) 是否在初始化时就立即检查更新并下载. 默认为 `true`.
  /// - [syncOnEachModuleStart]: (可选) 是否在每次请求模块时都检查更新. 默认为 `true`.
  ///
  /// [syncOnStart] 和 [syncOnEachModuleStart] 均为 false 时只使用本地包，可通过 [reLoad] 手动同步。
  Future<void> initialize({
    required String updateUrl,
    required String webAssetBaseDir,
    int maxRetries = 3,
    int retryDelayMs = 2000,
    String? hostAppVersion,
    Dio? dio,
    VersionInfoParser? versionParser,
    bool syncOnStart = true,
    bool syncOnEachModuleStart = true,
    bool debugLogRequests = false,
    LocalWebServer? localWebServer,
  }) async {
    if (_isInitialized && !_isDisposed) {
      logger.i('WebPayloadManager already initialized');
      return;
    }

    if (_isDisposed) {
      _isDisposed = false;
      _isInitialized = false;
      if (_payloadSyncStateController.isClosed) {
        _payloadSyncStateController =
            StreamController<PayloadSyncState>.broadcast();
      }
      _payloadSyncState = const PayloadSyncState.idle();
    }

    try {
      if (maxRetries < 0 || retryDelayMs < 0) {
        throw ArgumentError('Retry configuration must be non-negative');
      }
      final updateUri = Uri.parse(updateUrl);
      if (!(updateUrl.isEmpty && !syncOnStart && !syncOnEachModuleStart) &&
          updateUri.scheme != 'https' &&
          !_isDevHttp(updateUri)) {
        throw ArgumentError(
            'Updates require HTTPS (except development LAN/loopback IPs)');
      }
      _maxRetries = maxRetries;
      _retryDelayMs = retryDelayMs;
      _hostAppVersion = hostAppVersion;
      _hasUpdateSource = updateUrl.isNotEmpty;
      _syncOnEachModuleStart = syncOnEachModuleStart;

      // 初始化路径工具
      await FilePathUtility.initialize();

      // 自动发现所有 assetBaseDir 下的模块 key（子文件夹），并同步到 default
      await AssetSyncUtility.syncAllAssetsToDefault(webAssetBaseDir);
      webAssetDir = webAssetBaseDir;

      // 初始化各个服务
      _downloadService = DownloadService(dio: dio);
      _versionCheckService = VersionCheckService(
        updateUrl: updateUrl,
        dio: dio,
        parser: versionParser,
      );
      _localWebServer = localWebServer ?? LocalWebServer();
      _localWebServer.setDebugLogRequests(debugLogRequests);

      // 启动本地 Web 服务器
      await _localWebServer.start();
      _localWebServer.registerModuleRoot(FilePathUtility.getModuleDefaultDir());

      _isInitialized = true;
      logger.i('WebPayloadManager initialized successfully');

      // 根据参数决定是否在启动时就开始同步
      if (syncOnStart) {
        logger.i('syncOnStart is true, starting background sync...');
        // 后台同步，不阻塞 initialize 返回
        unawaited(
          _downloadIfNeed().catchError((e) {
            logger.w('Background sync on start failed: $e');
          }),
        );
      }
    } catch (e) {
      logger.e('Failed to initialize WebPayloadManager: $e');
      rethrow;
    }
  }

  /// 重新加载模块
  Future<void> reLoad() async {
    try {
      // 初始化路径工具
      await FilePathUtility.initialize();
      // 自动发现所有 assetBaseDir 下的模块 key（子文件夹），并同步到 default
      await AssetSyncUtility.syncAllAssetsToDefault(webAssetDir);
      logger.i('reLoad, retry loading an online resource...');
      await _downloadIfNeed();
    } catch (e) {
      logger.w('Background sync on reLoad failed: $e');
    }
    // 重载也要恢复服务，避免停服后只派发无法访问的旧 URL。
    if (_isDisposed) return;
    await _ensureWebServerRunning();
    // 无论下载成功与否，都尝试加载当前或默认的本地资源
    for (final entry in _controllers.entries.toList()) {
      await _loadCurrentOrDefault(entry.key, entry.value);
    }
  }

  /// 触发容灾回滚：将异常的 current 离线包移除并隔离，回退至 default 稳定内置资源
  Future<void> rollbackToDefault() async {
    logger.w('Triggering emergency rollback to default baseline assets...');
    await _withPayloadAccess(() async {
      if (await FilePathUtility.rollbackCurrentToDefault()) {
        _availableVersion = null;
        _setPayloadSyncState(const PayloadSyncState.idle());
      }
    });
    // 先切根再检查健康：current 已被隔离，不能再用旧根探活。
    if (_localWebServer.isRunning) {
      _localWebServer.registerModuleRoot(FilePathUtility.getModuleDefaultDir());
    }
    await _ensureWebServerRunning();
    // 即使没有活跃订阅，已打开页面的后续请求也必须使用 default。
    _localWebServer.registerModuleRoot(FilePathUtility.getModuleDefaultDir());
    // 重新加载并派发 default 资源
    for (final entry in _controllers.entries.toList()) {
      await _loadCurrentOrDefault(entry.key, entry.value);
    }
  }

  /// 当前全局资源包同步状态（检测更新 / 下载 zip / 解压）。
  PayloadSyncState get payloadSyncState => _payloadSyncState;

  /// 全局资源包同步状态流。
  Stream<PayloadSyncState> get payloadSyncStateStream =>
      _payloadSyncStateController.stream;

  void _setPayloadSyncState(PayloadSyncState state) {
    _payloadSyncState = state;
    if (!_payloadSyncStateController.isClosed) {
      _payloadSyncStateController.add(state);
    }
  }

  /// 获取模块状态流，外部 UI 通过此方法获取模块的加载状态。
  ///
  /// 返回 `Stream<ResourceState>`，按生命周期依次发出 [Loading]、[Data] 或 [Error]。
  Stream<ResourceState> getModuleStateStream(String key) {
    if (!_isInitialized || _isDisposed) {
      throw StateError('WebPayloadManager not initialized');
    }

    final controller = _controllers.putIfAbsent(key, () {
      late final StreamController<ResourceState> c;
      c = StreamController<ResourceState>.broadcast(
        onListen: () => unawaited(_startUpdateFlow(key, c)),
        onCancel: () {
          if (identical(_controllers[key], c)) {
            _controllers.remove(key);
            _activeSessions.remove(key);
          }
          unawaited(c.close());
        },
      );
      return c;
    });

    return controller.stream;
  }

  /// 核心更新流程
  Future<void> _startUpdateFlow(
    String key,
    StreamController<ResourceState> controller,
  ) async {
    // 步骤 1: 确保 Web 服务器正在运行 (自愈机制)
    try {
      await _ensureWebServerRunning();
    } catch (e) {
      logger.e('Critical error: Could not ensure web server is running. $e');
      final errorMessage = (e is ResourceException)
          ? e.message
          : 'Failed to start local server.';
      _emit(
        key,
        controller,
        ResourceState.error(
          message: '$errorMessage Please try again.',
          severity: ErrorSeverity.critical,
        ),
      );
      return; // 保留订阅，允许后续重载恢复。
    }

    if (_isDisposed ||
        controller.isClosed ||
        !identical(_controllers[key], controller)) {
      return;
    }
    // 步骤 2: 如果服务正常, 继续执行加载流程
    try {
      _emit(key, controller, const ResourceState.loading());

      // 本地优先：网络同步只更新包状态，不替换已打开的页面。
      await _loadCurrentOrDefault(key, controller);
      if (_syncOnEachModuleStart) unawaited(_downloadIfNeed());
    } catch (e) {
      logger.e('Error in update flow for $key: $e');

      _emit(
        key,
        controller,
        ResourceState.error(
          message: 'Fatal error: $e',
          severity: ErrorSeverity.critical,
        ),
      );
    }
  }

  void _emit(String key, StreamController<ResourceState> controller,
      ResourceState state) {
    if (!_isDisposed &&
        !controller.isClosed &&
        identical(_controllers[key], controller)) {
      controller.add(state);
    }
  }

  /// 确保 Web 服务器正在运行，若未运行或不健康则尝试自动重试与自愈启动
  Future<void> _ensureWebServerRunning() async {
    if (_ensureWebServerTask != null) {
      return _ensureWebServerTask!;
    }

    final completer = Completer<void>();
    _ensureWebServerTask = completer.future;

    () async {
      try {
        final oldPort = _localWebServer.port;
        final oldToken = _localWebServer.authToken;

        // 尝试启动或自愈，最多重试 3 次
        const maxAttempts = 3;
        bool startedSuccessfully = false;
        Exception? lastError;

        for (var attempt = 1; attempt <= maxAttempts; attempt++) {
          try {
            if (!_localWebServer.isRunning) {
              logger.w(
                'LocalWebServer is not running (attempt $attempt/$maxAttempts). Attempting to start...',
              );
              try {
                await _localWebServer.start(port: oldPort > 0 ? oldPort : null);
              } catch (_) {
                await _localWebServer.start(port: 0);
              }
            } else {
              var ok = await _localWebServer.checkHealth();
              if (!ok) {
                await Future<void>.delayed(
                    Duration(milliseconds: 100 * attempt));
                ok = await _localWebServer.checkHealth();
              }
              if (!ok) {
                logger.w(
                  'LocalWebServer health check failed (attempt $attempt/$maxAttempts). Restarting...',
                );
                final portToTry = _localWebServer.port;
                await _localWebServer.stop(preserveSession: true);
                try {
                  if (portToTry > 0) {
                    await _localWebServer.start(port: portToTry);
                  } else {
                    await _localWebServer.start();
                  }
                } catch (e) {
                  logger.w(
                    'Restart on port $portToTry failed: $e. Falling back to auto port.',
                  );
                  await _localWebServer.start(port: 0);
                }
              }
            }

            if (_localWebServer.servingRoot.isEmpty) {
              _localWebServer
                  .registerModuleRoot(FilePathUtility.getModuleDefaultDir());
            }

            final healthy = await _localWebServer.checkHealth();
            if (healthy) {
              startedSuccessfully = true;
              break;
            } else {
              throw Exception('Health check failed after start');
            }
          } catch (e) {
            lastError = e is Exception ? e : Exception(e.toString());
            logger.w('WebServer start/heal attempt $attempt failed: $e');
            if (attempt < maxAttempts) {
              await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
            }
          }
        }

        if (!startedSuccessfully) {
          throw lastError ??
              Exception('LocalWebServer failed to heal after 3 attempts');
        }

        // 端口或 Token 变动时通知各模块更新
        if (oldPort != _localWebServer.port ||
            oldToken != _localWebServer.authToken) {
          for (final entry in _controllers.entries.toList()) {
            final active = _activeSessions[entry.key];
            if (active == null) continue;
            final uri =
                Uri.parse(active.data).replace(port: _localWebServer.port);
            final next = Data(uri.toString(), version: active.version);
            _activeSessions[entry.key] = next;
            _emit(entry.key, entry.value, next);
          }
        }

        completer.complete();
      } catch (e, st) {
        logger.e('Failed to restart LocalWebServer: $e');
        completer.completeError(
          StorageException(
            message: 'Failed to start local web server.',
            originalException: e is Exception ? e : null,
          ),
          st,
        );
      } finally {
        _ensureWebServerTask = null;
      }
    }();

    return _ensureWebServerTask!;
  }

  /// App resume self-heal: ensure local web server is healthy
  Future<void> ensureLocalWebServerHealthy() async {
    if (!_isInitialized || _isDisposed) return;
    try {
      await _ensureWebServerRunning();
      // 成功恢复后：针对之前由于服务崩溃导致未建立会话或状态异常的模块，自动恢复加载本地资源
      for (final entry in _controllers.entries.toList()) {
        if (_activeSessions[entry.key] == null) {
          await _loadCurrentOrDefault(entry.key, entry.value);
        }
      }
    } catch (e) {
      logger.e('ensureLocalWebServerHealthy failed: $e');
      for (final entry in _controllers.entries.toList()) {
        _emit(
            entry.key,
            entry.value,
            ResourceState.error(
              message: 'Local web server recovery failed: $e',
              severity: ErrorSeverity.critical,
            ));
      }
    }
  }

  /// 确保全局资源包就绪 (核心锁逻辑)，有更新的话尝试下载到 current 目录
  Future<void> _downloadIfNeed() {
    if (!_hasUpdateSource) return Future.value();
    // 如果已有任务在进行, 直接返回该任务的 Future
    if (_globalDownloadTask != null) {
      logger.d('Download task already running, waiting for it to complete.');
      return _globalDownloadTask!;
    }

    logger.i('No active download task, starting a new one.');
    // 创建 Completer, 并将其 Future 作为锁
    final completer = Completer<void>();
    _globalDownloadTask = completer.future;
    _globalCancelToken = CancelToken(); // 创建全局 CancelToken

    // 立即执行的异步函数, 用于执行实际的检查和下载
    () async {
      try {
        _setPayloadSyncState(const PayloadSyncState.checking());

        // 1. 获取远程和本地版本信息
        final remoteModule = await _versionCheckService.getLatestModule();
        final remoteVersion = remoteModule?.effectiveVersionStr;

        if (remoteModule == null ||
            remoteVersion == null ||
            remoteVersion.isEmpty) {
          logger.w(
            'Failed to fetch remote version, falling back to local version.',
          );
          _setPayloadSyncState(
            const PayloadSyncState.failed(message: '无法获取远程版本信息'),
          );
          completer.complete();
          return;
        }

        final minimum = remoteModule.minAppVersion;
        if (minimum != null &&
            minimum.isNotEmpty &&
            (_hostAppVersion == null ||
                VersionComparator.needsUpdate(
                    localVersion: _hostAppVersion, remoteVersion: minimum))) {
          throw ValidationException(
              message: 'Payload requires host app $minimum');
        }
        final localVersion = await FilePathUtility.getLocalVersionInfo();

        // 2. 比较版本, 决定是否需要下载
        final needsUpdate = _downloadService.compareVersions(
          localVersion: localVersion?.effectiveVersionStr,
          remoteVersion: remoteVersion,
        );

        if (!needsUpdate && localVersion != null) {
          // 无需更新, 使用本地现有路径完成
          logger.i('No update needed. Using local version.');
          _setPayloadSyncState(const PayloadSyncState.upToDate());
          completer.complete();
          return;
        }

        // 3. 执行下载和解压
        logger.i('New version available, starting download...');
        _setPayloadSyncState(const PayloadSyncState.downloading());
        // 传递全局 CancelToken

        await _performDownloadAndUnzip(remoteModule, _globalCancelToken!);
        _availableVersion = remoteVersion;
        _setPayloadSyncState(const PayloadSyncState.completed());
        // 无可用旧会话的首装订阅无需等待宿主再次激活。
        for (final entry in _controllers.entries.toList()) {
          if (!_activeSessions.containsKey(entry.key)) {
            await _loadCurrentOrDefault(entry.key, entry.value);
          }
        }
        completer.complete();
      } catch (e) {
        logger.e('Error in _downloadIfNeed: $e');
        _setPayloadSyncState(
          PayloadSyncState.failed(message: e.toString()),
        );
        completer.complete();
      } finally {
        // 4. 任务结束 (无论成败), 释放锁和 Token
        logger.d('Download task finished, releasing lock.');
        _globalDownloadTask = null;
        _globalCancelToken = null;
      }
    }();

    // 返回锁的 Future
    return completer.future;
  }

  /// 执行实际的下载、解压和验证操作
  /// 返回新版本的资源根目录
  /// 下载完成后，会自动更新 current 目录
  /// 出错的话会抛出异常，需要在外层捕获处理
  Future<void> _performDownloadAndUnzip(
    WebVersionInfoBean remoteModule,
    CancelToken cancelToken,
  ) async {
    int retryCount = 0;
    while (true) {
      // 使用循环处理重试
      try {
        final downloadDir = FilePathUtility.getModuleDownloadDir();
        await FilePathUtility.ensureDirectoryExists(downloadDir);

        // 启动下载, 传入 cancelToken 和 onReceiveProgress 回调
        final downloadUri = Uri.parse(remoteModule.downloadUrl ?? '');
        if (downloadUri.scheme != 'https' && !_isDevHttp(downloadUri)) {
          throw ValidationException(message: 'Payload download requires HTTPS');
        }
        await _downloadService.startDownload(
          downloadUrl: remoteModule.downloadUrl ?? remoteModule.zipUrl ?? '',
          saveDir: downloadDir,
          publishExclusive: _withPayloadAccess,
          expectedMd5: remoteModule.md5,
          expectedVersion: remoteModule.effectiveVersionStr,
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            final progress = total > 0 ? received / total : 0.0;
            _setPayloadSyncState(
              PayloadSyncState.downloading(
                progress: progress,
                currentBytes: received,
              ),
            );
            // 后台进度只经 payloadSyncStateStream 发布。
          },
        );

        logger.i('Download completed.');

        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          logger.i('Download was cancelled by user.');
          rethrow; // 取消时不重试, 直接抛出
        }
        retryCount++;
        if (retryCount > _maxRetries) {
          logger.e('Download failed after $_maxRetries retries.');
          rethrow; // 重试次数耗尽, 向上抛出异常
        }

        final delaySeconds = _retryDelayMs * (1 << (retryCount - 1));
        logger.w(
          'Download attempt $retryCount failed, retrying after $delaySeconds milliseconds...',
        );
        await Future.delayed(Duration(milliseconds: delaySeconds));
      } catch (e) {
        retryCount++;
        if (retryCount > _maxRetries) {
          logger.e('Download failed after $_maxRetries retries.');
          rethrow;
        }
        final delaySeconds = _retryDelayMs * (1 << (retryCount - 1));
        logger.w(
          'Download attempt $retryCount failed with general error, retrying after $delaySeconds milliseconds...',
        );
        await Future.delayed(Duration(milliseconds: delaySeconds));
      }
    }
  }

  /// 加载当前或默认的资源
  Future<void> _loadCurrentOrDefault(
          String key, StreamController<ResourceState> controller) =>
      _withPayloadAccess(() => _loadSnapshot(key, controller));

  Future<void> _loadSnapshot(
    String key,
    StreamController<ResourceState> controller,
  ) async {
    try {
      // 优先读取 current 和 default 的版本信息
      final currentVersion = await FilePathUtility.getLocalVersionInfo(
        dirType: 'current',
      );
      final defaultVersion = await FilePathUtility.getLocalVersionInfo(
        dirType: 'default',
      );

      final currentDir = FilePathUtility.getModuleCurrentDir();
      final defaultDir = FilePathUtility.getModuleDefaultDir();

      // 判断首选目录：版本更新者优先使用
      bool preferCurrent = false;
      if (currentVersion != null && defaultVersion != null) {
        final defaultIsNewer = VersionComparator.needsUpdate(
          localVersion: currentVersion.effectiveVersionStr,
          remoteVersion: defaultVersion.effectiveVersionStr,
        );
        preferCurrent = !defaultIsNewer;
      } else if (currentVersion != null) {
        preferCurrent = true;
      }

      // 如果首选 current，尝试加载 current；若发生任何异常，自动透明兜底回退至 default 内置包
      if (preferCurrent) {
        try {
          await _createAndDispatchSnapshot(
            key: key,
            useDir: currentDir,
            localVersion: currentVersion!,
            controller: controller,
          );
          return;
        } catch (currentError) {
          logger.w(
            'Failed to load preferred current payload ($currentError). Falling back to default built-in assets...',
          );
        }
      }

      // 回退或首选加载 default 内置包
      if (defaultVersion != null && await Directory(defaultDir).exists()) {
        await _createAndDispatchSnapshot(
          key: key,
          useDir: defaultDir,
          localVersion: defaultVersion,
          controller: controller,
        );
        return;
      }

      throw StorageException(
        message: 'No fallback resources available for $key',
      );
    } catch (e) {
      _emit(
        key,
        controller,
        ResourceState.error(
          message: 'Fallback failed: $e',
          severity: ErrorSeverity.critical,
        ),
      );
    }
  }

  /// 抽取通用的快照生成与 URL 派发逻辑
  Future<void> _createAndDispatchSnapshot({
    required String key,
    required String useDir,
    required VersionJsonBean localVersion,
    required StreamController<ResourceState> controller,
  }) async {
    // 确保目录存在
    final exists = await Directory(useDir).exists();
    if (!exists) {
      throw StorageException(
        message: 'Resource directory does not exist: $useDir',
      );
    }

    // 异步加载期间可能取消订阅或 dispose；旧任务不得再修改服务。
    if (_isDisposed ||
        controller.isClosed ||
        !identical(_controllers[key], controller)) {
      return;
    }

    // 注册根目录
    _localWebServer.registerModuleRoot(useDir);
    final entryHtml = localVersion.modules
        ?.firstWhere((element) => element.key == key)
        .entryHtml;
    if (entryHtml == null) {
      throw Exception('Module $key not found in payload at $useDir');
    }

    final entryFile = File('$useDir/$entryHtml');
    if (!await entryFile.exists()) {
      throw Exception('Module $key entry file missing: $entryHtml at $useDir');
    }

    final manifest = await File('$useDir/version.json').readAsBytes();
    final contentDigests = <String>[];
    await for (final entity
        in Directory(useDir).list(recursive: true, followLinks: false)) {
      if (entity is File) {
        contentDigests.add(
            '${entity.path.substring(useDir.length)}:${await sha256.bind(entity.openRead()).first}');
      }
    }
    contentDigests.sort();
    final identity = sha256.convert(
        [...manifest, ...contentDigests.join('|').codeUnits]).toString();
    var snapshot = _snapshots[identity];
    if (snapshot == null) {
      snapshot = '${Directory(useDir).parent.path}/sessions/$identity';
      final target = Directory(snapshot);
      if (!await target.exists()) {
        final staging = Directory('$snapshot.tmp');
        if (await staging.exists()) await staging.delete(recursive: true);
        await staging.create(recursive: true);
        await for (final entity
            in Directory(useDir).list(recursive: true, followLinks: false)) {
          final relative = entity.path.substring(useDir.length);
          if (entity is File) {
            final destination = File('${staging.path}$relative');
            await destination.parent.create(recursive: true);
            await entity.copy(destination.path);
          }
        }
        await staging.rename(snapshot);
      }
      _snapshots[identity] = snapshot;
    }

    final url = _localWebServer.registerSnapshot(identity, snapshot, entryHtml);
    final data = Data(url, version: localVersion.effectiveVersionStr);
    _activeSessions[key] = data;
    _emit(key, controller, data);

    logger.i(
        'Successfully loaded resources for $key from $useDir (v${localVersion.effectiveVersionStr})');
  }

  /// 取消当前正在进行的全局下载任务
  Future<void> cancelAllDownloads() async {
    if (_globalCancelToken != null && !_globalCancelToken!.isCancelled) {
      logger.i('Cancellation requested for all downloads.');
      _globalCancelToken!.cancel('Global download cancelled by user.');
    } else {
      logger.d('No active global download task to cancel.');
    }
  }

  /// 获取包含鉴权 token 的 User-Agent 字符串
  /// 用于 WebView 中设置 User-Agent，所有资源请求（CSS、JS、图片等）都会自动携带此 User-Agent
  /// 格式: "WebPayloadManager/{token}"
  String getAuthUserAgent() {
    return _localWebServer.getAuthUserAgent();
  }

  /// 清理所有资源
  /// 应该在 App 退出时调用
  Future<void> dispose() async {
    if (_isDisposed) return;

    _isDisposed = true;

    try {
      // 取消所有下载
      await cancelAllDownloads();

      // 先移除快照，避免 close -> onCancel 修改正在遍历的 map。
      final controllers = _controllers.values.toList();
      _controllers.clear();
      for (final controller in controllers) {
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      }

      // 等待已进入的自愈结束再停止，避免 dispose 后重新启动监听端口。
      try {
        await _ensureWebServerTask;
      } catch (_) {
        // 自愈失败不影响释放。
      }
      // 停止服务
      try {
        await _globalDownloadTask;
      } catch (_) {}
      _snapshots.clear();
      _activeSessions.clear();
      _availableVersion = null;
      _downloadService.dispose();
      _versionCheckService.dispose();
      await _localWebServer.stop();

      if (!_payloadSyncStateController.isClosed) {
        await _payloadSyncStateController.close();
      }
      _payloadSyncState = const PayloadSyncState.idle();

      // 清理任务锁 (确保进行中的任务能正常结束, 但不再接受新请求)
      _globalDownloadTask = null;
      _globalCancelToken = null;
      _ensureWebServerTask = null;
      _isInitialized = false;
      _setPayloadSyncState(const PayloadSyncState.idle());

      logger.i('WebPayloadManager disposed');
    } catch (e) {
      logger.e('Error disposing WebPayloadManager: $e');
    }
  }
}
