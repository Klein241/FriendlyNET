import 'dart:async';
import 'package:flutter/services.dart';
import '../models/friend_peer.dart';

/// Service de découverte P2P via Wi-Fi Direct.
/// Communique avec WifiDirectManager.kt via MethodChannel.
class PeerDiscoveryService {
  static const MethodChannel _channel =
      MethodChannel('friendlynet/wifidirect');
  static const EventChannel _events =
      EventChannel('friendlynet/wifidirect/events');

  final List<FriendPeer> _discovered = [];
  StreamSubscription? _sub;
  bool _scanning = false;

  Function(List<FriendPeer>)? onPeersUpdated;
  Function(String)? onStatusChanged;
  Function(String)? onError;
  Function(String)? onConnected;

  Future<void> initialize() async {
    try {
      await _channel.invokeMethod('initialize');
      _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (e) {
        onError?.call('Stream P2P: $e');
      });
      onStatusChanged?.call('Découverte initialisée');
    } on PlatformException catch (e) {
      onError?.call('Init P2P: ${e.message}');
    }
  }

  Future<bool> startDiscovery() async {
    if (_scanning) return true;
    try {
      await _channel.invokeMethod('startDiscovery');
      _scanning = true;
      onStatusChanged?.call('Recherche de personnes proches...');
      return true;
    } on PlatformException catch (e) {
      onError?.call('Scan impossible: ${e.message}');
      return false;
    }
  }

  Future<void> stopDiscovery() async {
    _scanning = false;
    try {
      await _channel.invokeMethod('stopDiscovery');
    } catch (_) {}
    onStatusChanged?.call('Scan arrêté');
  }

  Future<bool> connectToPeer(String mac) async {
    try {
      await _channel.invokeMethod('connect', {'mac': mac});
      return true;
    } on PlatformException catch (e) {
      onError?.call('Connexion échouée: ${e.message}');
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (_) {}
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final data = Map<String, dynamic>.from(event);
    final type = data['type'] as String? ?? '';

    switch (type) {
      case 'peers':
        final list = data['data'] as List? ?? [];
        _discovered.clear();
        for (final item in list) {
          final m = Map<String, dynamic>.from(item as Map);
          _discovered.add(FriendPeer(
            nodeId: m['mac'] as String? ?? '',
            label: m['name'] as String? ?? 'Appareil',
            mac: m['mac'] as String? ?? '',
            statusLabel: m['status'] as String? ?? '',
          ));
        }
        onPeersUpdated?.call(List.from(_discovered));
        break;

      case 'connected':
        final ip = data['ip'] as String? ?? '';
        onConnected?.call(ip);
        onStatusChanged?.call('Connecté via Wi-Fi Direct');
        break;

      case 'error':
        onError?.call(data['msg'] as String? ?? 'Erreur Wi-Fi Direct');
        break;
    }
  }

  bool get isScanning => _scanning;
  List<FriendPeer> get peers => List.from(_discovered);

  void dispose() {
    stopDiscovery();
    _sub?.cancel();
  }
}
