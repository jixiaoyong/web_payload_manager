import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path_lib;

import 'util/logger.dart';

class LocalWebServer {
  HttpServer? _server;
  String _servingRoot = '';
  final Map<String, String> _snapshotRoots = {};

  /// 将不可变快照 [rootPath] 绑定至 [identity]，返回带版本前缀的入口 URL。
  /// [entryHtml] 必须是相对该快照的安全路径。
  String registerSnapshot(String identity, String rootPath, String entryHtml) {
    _snapshotRoots[identity] = rootPath;
    return 'http://127.0.0.1:$port/__payload/$identity/$entryHtml';
  }

  int _port = 0;
  bool _isRunning = false;
  bool _debugLogRequests = false;

  // --- 启动锁，防止并发启动 ---
  Future<void>? _startTask;
  // --- 生命周期串行锁（start/stop/checkHealth） ---
  Future<void> _lifecycleTask = Future.value();

  // --- 安全相关成员 ---
  String? _authToken;
  DateTime? _tokenExpiry;

  // ============ 外部属性接口 ============

  int get port => _port;
  String get servingRoot => _servingRoot;
  String? get authToken => _authToken;
  DateTime? get tokenExpiry => _tokenExpiry;
  bool get isRunning => _isRunning;
  bool get debugLogRequests => _debugLogRequests;
  String getModuleUrl(String moduleEntryHtml) =>
      'http://127.0.0.1:$port/$moduleEntryHtml';
  String getSecureModuleUrl(String key) =>
      'http://127.0.0.1:$port/$key/index.html?token=$_authToken';

  /// 获取包含鉴权 token 的 User-Agent 字符串
  /// 用于 WebView 中设置 User-Agent，所有资源请求都会自动携带此 User-Agent
  /// 格式: "WebPayloadManager/{token}"
  String getAuthUserAgent() {
    if (_authToken == null) return '';
    return 'WebPayloadManager/$_authToken';
  }

  void setDebugLogRequests(bool enabled) {
    _debugLogRequests = enabled;
  }

  // ============ 启动/停止服务器 ============

  Future<void> start({
    int? port,
    Duration tokenValidFor = const Duration(days: 7),
  }) async {
    return _runLifecycleExclusive(() async {
      // 如果已经在运行，直接返回
      if (_isRunning) return;

      // 如果启动任务正在进行，等待它完成
      if (_startTask != null) {
        await _startTask;
        return;
      }

      // 创建启动任务（启动锁）
      _startTask = _doStart(port, tokenValidFor);
      try {
        await _startTask;
      } finally {
        _startTask = null;
      }
    });
  }

  /// 实际的启动逻辑
  Future<void> _doStart(
    int? port,
    Duration tokenValidFor,
  ) async {
    try {
      final bindPort = port ?? 0; // 0 lets OS choose an available port
      if (_authToken == null ||
          _tokenExpiry == null ||
          !DateTime.now().isBefore(_tokenExpiry!)) {
        _generateAuthToken(tokenValidFor);
      }

      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, bindPort);
      _port = _server!.port;
      _server!.idleTimeout = const Duration(seconds: 60);
      _server!.listen(_handleRequest);

      // 在 listen() 成功之后才设置 _isRunning = true
      _isRunning = true;

      logger.i('🚀 LocalWebServer started on http://127.0.0.1:$_port');
      logger.i('Auth token configured, valid until: $_tokenExpiry');
    } catch (e) {
      // 启动失败时清理状态
      _isRunning = false;
      if (_server != null) {
        try {
          await _server!.close(force: true);
        } catch (_) {
          // 忽略关闭时的错误
        }
        _server = null;
      }
      _port = 0;
      // 绑定失败不丢弃会话，允许换端口重试时继续使用原凭证与根目录。
      logger.e('❌ Failed to start LocalWebServer: $e');
      rethrow;
    }
  }

  /// 自愈重启可保留会话；正常释放仍清除目录与凭证。
  Future<void> stop({bool preserveSession = false}) async {
    return _runLifecycleExclusive(() async {
      // 即使已停止，也允许正常 dispose 清除保留的会话。
      // 等待正在进行的启动任务完成
      if (_startTask != null) {
        await _startTask;
      }

      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
      }
      _isRunning = false;
      if (!preserveSession) {
        _servingRoot = '';
        _authToken = null;
        _tokenExpiry = null;
      }
      logger.i('🛑 LocalWebServer stopped');
    });
  }

  // ============ 端口分配&Token ============

  void _generateAuthToken([Duration validFor = const Duration(days: 7)]) {
    final random = Random.secure();
    final values = List<int>.generate(32, (_) => random.nextInt(256));
    _authToken = base64Url.encode(values);
    _tokenExpiry = DateTime.now().add(validFor);
  }

  void refreshAuthToken([Duration validFor = const Duration(days: 7)]) {
    _generateAuthToken(validFor);
    logger.i('Auth token refreshed');
  }

  bool _validateAuthToken(HttpRequest request) {
    if (_authToken == null ||
        _tokenExpiry == null ||
        DateTime.now().isAfter(_tokenExpiry!)) {
      return false;
    }
    // Header auth
    final auth = request.headers.value('Authorization');
    if (auth != null && auth == 'Bearer $_authToken') return true;
    // User-Agent auth (兼容部分客户端)
    final userAgent = request.headers.value('user-agent') ?? '';
    if (userAgent.contains(_authToken!)) return true;
    // Query token 兼容支持
    final tokenInQuery = request.uri.queryParameters['token'];
    if (tokenInQuery == _authToken) return true;
    return false;
  }

  // ============ 注册资源目录 ============

  void registerModuleRoot(String rootPath) {
    if (!_isRunning) throw StateError('Server is not running');
    _servingRoot = rootPath;
    logger.i('Registered: $rootPath');
  }

  /// Health check for local server (requires auth)
  Future<bool> checkHealth(
      {Duration timeout = const Duration(seconds: 2)}) async {
    return _runLifecycleExclusive(() async {
      if (!_isRunning || _port == 0 || _authToken == null) {
        return false;
      }
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        final result = await Future<bool>(() async {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$_port/__health'));
          request.headers.set('Authorization', 'Bearer $_authToken');
          final response = await request.close();
          await response.drain();
          return response.statusCode == HttpStatus.ok;
        }).timeout(timeout);
        return result;
      } catch (_) {
        return false;
      } finally {
        client.close(force: true);
      }
    });
  }

  Future<T> _runLifecycleExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lifecycleTask = _lifecycleTask.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ============ 处理请求 ============

  Future<void> _handleRequest(HttpRequest request) async {
    if (_debugLogRequests) {
      logger.i(
          '[LocalWebServer] ${request.method} ${request.uri} host=${request.headers.host}');
    }
    // ------- 鉴权，失败返回401 -------
    if (!_validateAuthToken(request)) {
      if (_debugLogRequests) {
        logger.w('[LocalWebServer] 401 Unauthorized path=${request.uri.path}');
      }
      _sendError(request, HttpStatus.unauthorized, 'Unauthorized');
      return;
    }

    // ------- Host校验 -------
    if (!_isValidHost(request.headers.host ?? '')) {
      if (_debugLogRequests) {
        logger.w('[LocalWebServer] 403 Invalid host=${request.headers.host}');
      }
      _sendError(request, HttpStatus.forbidden, 'Invalid host');
      return;
    }

    // ------- 路径解析（健康检查不依赖 rootPath，需先处理） -------
    var requestedPath = request.uri.path;
    if (requestedPath.startsWith('/')) {
      requestedPath = requestedPath.substring(1);
    }
    if (requestedPath == '__health') {
      if (_servingRoot.isEmpty || !await Directory(_servingRoot).exists()) {
        _sendError(request, HttpStatus.serviceUnavailable, 'Server not ready');
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      _setSecurityHeaders(request.response);
      request.response.write(jsonEncode({'status': 'ok'}));
      await request.response.close();
      return;
    }

    // ------- 路径处理与安全校验 (已优化) -------
    var rootPath = _servingRoot;
    if (requestedPath.startsWith('__payload/')) {
      final parts = requestedPath.split('/');
      rootPath = parts.length >= 3
          ? (_snapshotRoots[parts[1]] ?? _servingRoot)
          : _servingRoot;
      requestedPath = parts.skip(2).join('/');
    } else {
      // 若请求不含 __payload/ 前缀（例如网页内部通过绝对路径引用的 /common/style.css），
      // 优先根据 Referer 中的 __payload/<identity>/ 定位对应快照根目录以实现快照隔离；
      // 若无 Referer 则安全回退至当前激活的 _servingRoot。
      final referer = request.headers.value('referer');
      if (referer != null) {
        final match = RegExp(r'/__payload/([^/?#]+)/').firstMatch(referer);
        if (match != null) {
          final identity = match.group(1);
          if (identity != null && _snapshotRoots.containsKey(identity)) {
            rootPath = _snapshotRoots[identity]!;
          }
        }
      }
    }
    if (rootPath.isEmpty) {
      if (_debugLogRequests) {
        logger.w('[LocalWebServer] 503 Server not ready');
      }
      _sendError(request, HttpStatus.serviceUnavailable, 'Server not ready');
      return;
    }

    // 对空路径请求, 默认返回 index.html
    if (requestedPath.isEmpty) {
      requestedPath = 'index.html';
    }

    // 4. 净化路径, 防止路径遍历攻击
    final sanitizedPath = _sanitizePath(requestedPath);
    if (sanitizedPath == null) {
      if (_debugLogRequests) {
        logger.w('[LocalWebServer] 403 Access Denied path=$requestedPath');
      }
      _sendError(request, HttpStatus.forbidden, 'Access Denied');
      return;
    }

    // 5. 拼接最终文件路径并再次校验
    final filePath = path_lib.normalize(path_lib.join(rootPath, sanitizedPath));
    final normalizedRoot = path_lib.normalize(rootPath);

    if (!path_lib.isWithin(normalizedRoot, filePath)) {
      if (_debugLogRequests) {
        logger.w('[LocalWebServer] 403 Access Denied filePath=$filePath');
      }
      _sendError(request, HttpStatus.forbidden, 'Access Denied');
      return;
    }

    // ------- 文件服务 -------
    final file = File(filePath);
    if (!await file.exists()) {
      // 对于相对路径的资源(如 a.png), 尝试从根目录查找
      final rootAttemptPath =
          path_lib.join(rootPath, path_lib.basename(filePath));
      final rootFile = File(rootAttemptPath);
      if (await rootFile.exists()) {
        await _serveFile(request, rootAttemptPath);
        return;
      }
      if (_debugLogRequests) {
        logger.w('[LocalWebServer] 404 File not found path=$requestedPath');
      }
      _sendError(
          request, HttpStatus.notFound, 'File not found: $requestedPath');
      return;
    }

    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.directory) {
      final indexPath = path_lib.join(filePath, 'index.html');
      final indexFile = File(indexPath);
      if (!await indexFile.exists()) {
        if (_debugLogRequests) {
          logger.w(
              '[LocalWebServer] 404 Directory listing not allowed path=$filePath');
        }
        _sendError(
            request, HttpStatus.notFound, 'Directory listing not allowed');
        return;
      }
      await _serveFile(request, indexPath);
      return;
    }

    if (!_isAllowedFile(filePath)) {
      if (_debugLogRequests) {
        logger.w('[LocalWebServer] 403 File type not allowed path=$filePath');
      }
      _sendError(request, HttpStatus.forbidden, 'File type not allowed');
      return;
    }

    await _serveFile(request, filePath);
  }

  // ============ 文件服务与安全 ============

  static const List<String> _allowedExtensions = [
    '.html',
    '.htm',
    '.js',
    '.css',
    '.json',
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.svg',
    '.webp',
    '.woff',
    '.woff2',
    '.ttf',
    '.eot',
    '.mp4',
    '.webm',
    '.ogg',
    '.mp3',
  ];
  static const Set<String> _bannedFileNames = {
    '.env',
    '.git',
    '.gitignore',
    'config.db',
    'config.json',
    'private.key',
  };

  Future<void> _serveFile(HttpRequest request, String filePath) async {
    try {
      final file = File(filePath);
      _setSecurityHeaders(request.response);
      request.response.headers.contentType = _getContentType(filePath);

      // 检查 ETag，如果返回 true 说明已处理 304，直接关闭
      if (await _setEtagHeaders(request, file, request.response)) {
        await request.response.close();
        return;
      }

      // 使用流式传输，避免一次性读取大文件占用内存
      await file.openRead().pipe(request.response);
    } catch (e) {
      // pipe 会自动关闭 response，所以只有在未开始传输时才需要手动处理错误
      try {
        _sendError(request, HttpStatus.internalServerError, 'Server error');
      } catch (_) {}
    }
  }

  void _setSecurityHeaders(HttpResponse response) {
    response.headers.add('X-Content-Type-Options', 'nosniff');
    response.headers.add('X-Frame-Options', 'SAMEORIGIN');
    response.headers.add('X-XSS-Protection', '1; mode=block');
    response.headers.add('Referrer-Policy', 'strict-origin-when-cross-origin');
    response.headers
        .add('Permissions-Policy', 'geolocation=(), microphone=(), camera=()');
    // 文件缓存 1 小时, 避免频繁请求
    // response.headers.add('Cache-Control', 'public, max-age=3600');
    response.headers.add('Cache-Control', 'no-cache, must-revalidate');
  }

  /// 设置 ETag 头
  /// 返回 true 表示命中缓存 (304)，调用者应立即结束响应且不发送 Body
  /// 返回 false 表示未命中，需继续发送 Body
  Future<bool> _setEtagHeaders(
      HttpRequest request, File file, HttpResponse response) async {
    try {
      final stat = await file.stat();
      final etag = '"${stat.modified.millisecondsSinceEpoch}-${stat.size}"';
      response.headers.add('ETag', etag);
      final ifNoneMatch = request.headers.value('if-none-match');
      if (ifNoneMatch == etag) {
        response.statusCode = HttpStatus.notModified;
        return true;
      }
    } catch (_) {}
    return false;
  }

  String? _sanitizePath(String path) {
    try {
      final normalized = path_lib.normalize(path);
      if (normalized.contains('..')) return null;
      if (path_lib.isAbsolute(normalized)) return null;
      return normalized;
    } catch (_) {
      return null;
    }
  }

  bool _isValidHost(String host) {
    final uri = Uri.tryParse('http://$host');
    return uri != null &&
        uri.userInfo.isEmpty &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1');
  }

  bool _isAllowedFile(String filePath) {
    final ext = path_lib.extension(filePath).toLowerCase();
    if (!_allowedExtensions.contains(ext)) return false;
    final name = path_lib.basename(filePath).toLowerCase();
    if (_bannedFileNames.contains(name)) return false;
    return true;
  }

  ContentType _getContentType(String filePath) {
    final ext = path_lib.extension(filePath).toLowerCase();
    return switch (ext) {
      '.html' || '.htm' => ContentType.html,
      '.js' => ContentType('application', 'javascript'),
      '.json' => ContentType.json,
      '.css' => ContentType('text', 'css'),
      '.png' => ContentType('image', 'png'),
      '.jpg' || '.jpeg' => ContentType('image', 'jpeg'),
      '.gif' => ContentType('image', 'gif'),
      '.svg' => ContentType('image', 'svg+xml'),
      '.webp' => ContentType('image', 'webp'),
      '.woff' => ContentType('font', 'woff'),
      '.woff2' => ContentType('font', 'woff2'),
      '.ttf' => ContentType('font', 'ttf'),
      '.eot' => ContentType('application', 'vnd.ms-fontobject'),
      '.mp4' => ContentType('video', 'mp4'),
      '.webm' => ContentType('video', 'webm'),
      '.ogg' => ContentType('audio', 'ogg'),
      '.mp3' => ContentType('audio', 'mpeg'),
      _ => ContentType.binary,
    };
  }

  void _sendError(HttpRequest request, int code, String msg) {
    try {
      request.response.statusCode = code;
      _setSecurityHeaders(request.response);
      // 对 401 与 403 鉴权失败做脱敏处理，避免向本机其他 App 端口扫描暴露服务特征
      if (code == HttpStatus.unauthorized || code == HttpStatus.forbidden) {
        request.response.headers.contentType = ContentType.text;
        request.response.write('$code Denied');
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': msg, 'statusCode': code}));
      }
      request.response.close();
    } catch (_) {}
  }
}
