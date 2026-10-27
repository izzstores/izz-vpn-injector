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

  static VpnState _currentState = VpnState.disconnected;
  static VpnState get currentState => _currentState;

  static Stream<VpnState> get stateStream => _stateController.stream;
  static Stream<Map<String, dynamic>> get statsStream => _statsController.stream;

  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case "onStateChanged":
          final stateStr = call.arguments as String? ?? "disconnected";
          _updateState(_parseState(stateStr));
          break;
        case "onStats":
          final stats = Map<String, dynamic>.from(call.arguments as Map);
          _statsController.add(stats);
          break;
      }
    });
  }

  static Future<bool> startVpn(String configJson) async {
    try {
      _updateState(VpnState.connecting);
      final bool? result = await _channel.invokeMethod<bool>('startVpn', {
        'config': configJson,
      });
      if (result == true) {
        _updateState(VpnState.connected);
        return true;
      } else {
        _updateState(VpnState.error);
        return false;
      }
    } on PlatformException catch (_) {
      _updateState(VpnState.error);
      return false;
    }
  }

  static Future<void> stopVpn() async {
    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
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
