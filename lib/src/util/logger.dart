import 'dart:developer' as dev;

class Logger {
  static final Logger _instance = Logger._internal();
  factory Logger() => _instance;
  Logger._internal();

  void log(Object message) {
    // debugPrint(message.toString());
    dev.log(message.toString(), name: 'web_manager');
  }

  void i(Object message) {
    log(message);
  }

  void d(Object message) {
    log(message.toString());
  }

  void w(Object message) {
    log(message.toString());
  }

  void e(Object message) {
    log(message.toString());
  }
}

final logger = Logger();
