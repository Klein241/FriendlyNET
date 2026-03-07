import 'dart:async';
import 'package:flutter/services.dart';

/// Pont entre Flutter et le tunnel natif (FriendlyNetVpnService).
/// Gère le démarrage/arrêt du tunnel et le monitoring de l'état.
class TunnelBridgeService {
  static const MethodChannel _channel =
      MethodChannel('friendlynet/vpn');

  bool _running = false;
  Timer? _monitor;

  Function(bool connected)? onConnectionChanged;
  Function(String)? onStatusChanged;
  Function(String)? onError;

  /// Démarre le tunnel sécurisé vers l'hôte.
  Future<bool> startTunnel({
    required String nodeId,
    required String userId,
    required String workerUrl,
    required String tunnelKey,
    int keepaliveInterval = 15,
    bool lowBandwidth = false,
    String? localIp,
  }) async {
    try {
      final result = await _channel.invokeMethod('startVpn', {
        'nodeId': nodeId,
        'userId': userId,
        'workerUrl': workerUrl,
        'tunnelKey': tunnelKey,
        'keepaliveInterval': keepaliveInterval,
        'lowBandwidth': lowBandwidth,
        if (localIp != null) 'localIp': localIp,
      });
      _running = result == true;
      if (_running) {
        onConnectionChanged?.call(true);
        onStatusChanged?.call('Mode Sécurisé actif');
        _startMonitor();
      }
      return _running;
    } on PlatformException catch (e) {
      onError?.call('Erreur tunnel: ${e.message}');
      return false;
    }
  }

  /// Arrête le tunnel.
  Future<void> stopTunnel() async {
    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
    _running = false;
    _monitor?.cancel();
    onConnectionChanged?.call(false);
    onStatusChanged?.call('Mode Sécurisé arrêté');
  }

  /// Monitoring périodique (toutes les 5s).
  void _startMonitor() {
    _monitor?.cancel();
    _monitor = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_running) {
        _monitor?.cancel();
        return;
      }
      // Le monitoring réel est géré côté natif par TailscaleMode
      // Ce timer sert de heartbeat Dart-side
    });
  }

  bool get isRunning => _running;

  void dispose() {
    stopTunnel();
  }
}
