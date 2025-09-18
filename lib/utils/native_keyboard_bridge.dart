import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

/// Listens on the MethodChannel for keyboard-height updates.
class NativeKeyboardBridge {
  static const _channel = MethodChannel('com.example.movieflix/keyboard');

  /// Publishes the latest keyboard height (in logical pixels).
  final ValueNotifier<double> keyboardHeight = ValueNotifier(0);

  NativeKeyboardBridge() {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method == 'keyboardHeight') {
      final int raw = call.arguments as int;
      // convert to logical pixels
      final double logical = raw / WidgetsBinding.instance.window.devicePixelRatio;
      keyboardHeight.value = logical;
    }
  }
}
