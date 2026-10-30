import 'dart:async';
import 'package:flutter/services.dart';

enum VpnState {
  disconnected,
  connecting,
  authenticating,
  connected,
  error,
}

class VpnService {
  static const MethodChannel _channel = MethodChannel('com.izz.tunneling/vpn');
  static const EventChannel _statsChannel = EventChannel('com.izz.tunneling/vpn_stats');

  static final StreamController<VpnState> _stateController =
      StreamController<VpnState>.broadcast();
  static final StreamController<Map<String, dynamic>> _statsController =
      StreamController<Map<String, dynamic>>.broadcast();
  static final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  static final StreamController<String> _configFileController =
      StreamController<String>.broadcast();

  static Stream<String> get configFileStream => _configFileController.stream;

  static VpnState _currentState = VpnState.disconnected;
  static VpnState get currentState => _currentState;
  static String? _lastErrorMessage;
  static String? get lastErrorMessage => _lastErrorMessage;

  static Stream<VpnState> get stateStream => _stateController.stream;
  static Stream<Map<String, dynamic>> get statsStream => _statsController.stream;
  static Stream<String> get errorStream => _errorController.stream;

  static Future<String?> getPendingConfig() async {
    try {
      return await _channel.invokeMethod<String>('getPendingConfig');
    } catch (_) {
      return null;
    }
  }

  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case "onStateChanged":
          _handleStateChanged(call.arguments);
          break;
        case "onStats":
          final stats = Map<String, dynamic>.from(call.arguments as Map);
          _statsController.add(stats);
          break;
        case "onConfigFileOpened":
          final content = call.arguments as String?;
          if (content != null && content.trim().isNotEmpty) {
            _configFileController.add(content);
          }
          break;
      }
    });
  }

  /// Handle state change from native side.
  /// Arguments can be:
  ///   - A String (legacy: just the state name)
  ///   - A Map with "state" and optional "message" keys
  static void _handleStateChanged(dynamic arguments) {
    String stateStr;
    String? message;

    if (arguments is Map) {
      stateStr = (arguments["state"] as String?) ?? "disconnected";
      message = arguments["message"] as String?;
    } else if (arguments is String) {
      stateStr = arguments;
      message = null;
    } else {
      stateStr = "disconnected";
      message = null;
    }

    final newState = _parseState(stateStr);

    if (newState == VpnState.error && message != null) {
      _lastErrorMessage = message;
      _errorController.add(message);
    } else if (newState == VpnState.connected) {
      _lastErrorMessage = null;
    }

    _updateState(newState);
  }

  static Future<bool> startVpn(String configJson) async {
    try {
      _lastErrorMessage = null;
      _updateState(VpnState.connecting);

      final bool? result = await _channel.invokeMethod<bool>('startVpn', {
        'config': configJson,
      });

      if (result != true) {
        // User denied VPN permission or other immediate failure
        _updateState(VpnState.disconnected);
        return false;
      }

      // result == true means the native side accepted the start command.
      // The ACTUAL connection state will be reported via onStateChanged callback.
      // Do NOT set connected here — wait for the native side to confirm.
      return true;
    } on PlatformException catch (e) {
      _lastErrorMessage = e.message ?? 'Platform error';
      _errorController.add(_lastErrorMessage!);
      _updateState(VpnState.error);
      return false;
    } catch (e) {
      _lastErrorMessage = e.toString();
      _errorController.add(_lastErrorMessage!);
      _updateState(VpnState.error);
      return false;
    }
  }

  static Future<void> stopVpn() async {
    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
    _lastErrorMessage = null;
    _updateState(VpnState.disconnected);
  }

  static void _updateState(VpnState state) {
    _currentState = state;
    _stateController.add(state);
  }

  static VpnState _parseState(String stateStr) {
    switch (stateStr.toLowerCase()) {
      case "connecting":
        return VpnState.connecting;
      case "authenticating":
        return VpnState.authenticating;
      case "connected":
        return VpnState.connected;
      case "error":
        return VpnState.error;
      default:
        return VpnState.disconnected;
    }
  }
}
