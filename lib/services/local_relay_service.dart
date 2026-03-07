import 'dart:async';
import 'package:flutter/services.dart';

/// Service de relais local — contrôle le TCP relay + DNS relay natifs.
/// L'hôte démarre ce service pour que l'invité puisse router
/// son trafic internet à travers lui.
class LocalRelayService {
  static const MethodChannel _channel =
      MethodChannel('friendlynet/relay');

  bool _tcpRunning = false;
  bool _dnsRunning = false;

  Function(String)? onStatusChanged;
  Function(String)? onError;

  /// Démarre le relay TCP (port 8899) + DNS (port 8853) sur l'hôte.
  Future<bool> startRelay({int port = 8899}) async {
    try {
      await _channel.invokeMethod('startRelay', {'port': port});
      _tcpRunning = true;
      _dnsRunning = true;
      onStatusChanged?.call('Relais actif — TCP:$port + DNS:8853');
      return true;
    } on PlatformException catch (e) {
      onError?.call('Erreur relais: ${e.message}');
      return false;
    }
  }

  /// Arrête les deux relais.
  Future<void> stopRelay() async {
    try {
      await _channel.invokeMethod('stopRelay');
    } catch (_) {}
    _tcpRunning = false;
    _dnsRunning = false;
    onStatusChanged?.call('Relais arrêté');
  }

  /// Démarre uniquement le DNS relay.
  Future<bool> startDns() async {
    try {
      await _channel.invokeMethod('startDns');
      _dnsRunning = true;
      return true;
    } on PlatformException catch (e) {
      onError?.call('Erreur DNS relay: ${e.message}');
      return false;
    }
  }

  /// Arrête uniquement le DNS relay.
  Future<void> stopDns() async {
    try {
      await _channel.invokeMethod('stopDns');
    } catch (_) {}
    _dnsRunning = false;
  }

  /// Récupère le statut des relais.
  Future<Map<String, dynamic>> getStatus() async {
    try {
      final result = await _channel.invokeMethod('relayStatus');
      if (result is Map) {
        _dnsRunning = result['dnsRunning'] as bool? ?? false;
        return Map<String, dynamic>.from(result);
      }
    } catch (_) {}
    return {'dnsRunning': _dnsRunning, 'dnsCacheSize': 0};
  }

  bool get isTcpRunning => _tcpRunning;
  bool get isDnsRunning => _dnsRunning;

  void dispose() {
    stopRelay();
  }
}
