import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web_payload_manager/web_payload_manager.dart';

import 'app_bootstrap.dart';
import 'app_restart.dart';
import 'payload/module_loader_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeWebPayloadManager();

  runApp(const DemoApp());
}

class DemoApp extends StatefulWidget {
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> with WidgetsBindingObserver {
  Key _appShellKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(WebPayloadManager.getInstance().ensureLocalWebServerHealthy());
    }
  }

  Future<void> _restartApp() async {
    await restartWebPayloadManager();
    if (!mounted) {
      return;
    }
    setState(() => _appShellKey = UniqueKey());
  }

  @override
  Widget build(BuildContext context) {
    return AppRestartScope(
      onRestart: _restartApp,
      child: MaterialApp(
        key: _appShellKey,
        title: 'Web Payload Manager Demo',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: false,
        ),
        home: const ModuleLoaderPage(),
      ),
    );
  }
}
