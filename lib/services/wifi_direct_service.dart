import 'dart:async';
import 'package:flutter/services.dart';

/// ════════════════════════════════════════════════════════════════
/// WifiDirectService — FriendlyNET
///
/// Pont Flutter ↔ Android WifiDirectManager.
/// Permet de découvrir et connecter des pairs FriendlyNET proches
/// SANS utiliser de data mobile — via WiFi Direct P2P.
///
/// Avantages vs mesh Cloudflare :
///  - 0 Mo de data pour la découverte
///  - Latence très faible (direct device-to-device)
///  - Fonctionne même si le forfait est épuisé
///  - Idéal pour Jean (0 data) qui veut trouver Marie (à portée)
///
/// Usage :
///  final wd = WifiDirectService();
///  await wd.initialize();
///  wd.onPeersFound = (peers) { ... };
///  wd.onConnected = (ip) { ... };
///  await wd.startDiscovery();
/// ════════════════════════════════════════════════════════════════
class WifiDirectService {
  static const _method = MethodChannel('friendlynet/wifidirect');
  static const _events = EventChannel('friendlynet/wifidirect/events');

  StreamSubscription? _eventSub;
  bool _initialized = false;

  // ─── Callbacks ───
  void Function(List<WifiDirectPeer> peers)? onPeersFound;
  void Function(String groupOwnerIp)? onConnected;
  void Function(String message)? onError;
  void Function()? onDisconnected;

  // ─── État ───
  List<WifiDirectPeer> _peers = [];
  String _connectedIp = '';
  bool _isConnected = false;

  List<WifiDirectPeer> get peers => List.from(_peers);
  String get connectedIp => _connectedIp;
  bool get isConnected => _isConnected;
  bool get isInitialized => _initialized;

  // ═══════════════════════════════════════════
  // INIT
  // ═══════════════════════════════════════════

  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      await _method.invokeMethod('initialize');
      _listenEvents();
      _initialized = true;
      return true;
    } catch (e) {
      onError?.call('WiFi Direct non disponible: $e');
      return false;
    }
  }

  void _listenEvents() {
    _eventSub = _events.receiveBroadcastStream().listen(
      (event) {
        final map = Map<String, dynamic>.from(event as Map);
        final type = map['type'] as String? ?? '';

        switch (type) {
          case 'peers':
            final raw = (map['data'] as List?) ?? [];
            _peers = raw.map((p) {
              final m = Map<String, dynamic>.from(p as Map);
              return WifiDirectPeer(
                mac: m['mac'] as String? ?? '',
                name: m['name'] as String? ?? 'Inconnu',
                statusLabel: m['status'] as String? ?? '',
              );
            }).toList();
            onPeersFound?.call(_peers);

          case 'connected':
            _connectedIp = map['ip'] as String? ?? '';
            _isConnected = true;
            onConnected?.call(_connectedIp);

          case 'disconnected':
            _isConnected = false;
            _connectedIp = '';
            onDisconnected?.call();

          case 'error':
            onError?.call(map['msg'] as String? ?? 'Erreur WiFi Direct');
        }
      },
      onError: (e) => onError?.call('Stream error: $e'),
    );
  }

  // ═══════════════════════════════════════════
  // DISCOVERY
  // ═══════════════════════════════════════════

  Future<bool> startDiscovery() async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return false;
    }
    try {
      await _method.invokeMethod('startDiscovery');
      return true;
    } catch (e) {
      onError?.call('Erreur démarrage découverte: $e');
      return false;
    }
  }

  Future<void> stopDiscovery() async {
    try {
      await _method.invokeMethod('stopDiscovery');
    } catch (_) {}
  }

  Future<List<WifiDirectPeer>> getPeers() async {
    try {
      final raw = await _method.invokeMethod<List>('peers') ?? [];
      _peers = raw.map((p) {
        final m = Map<String, dynamic>.from(p as Map);
        return WifiDirectPeer(
          mac: m['mac'] as String? ?? '',
          name: m['name'] as String? ?? 'Inconnu',
          statusLabel: m['status'] as String? ?? '',
        );
      }).toList();
      return _peers;
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════════════
  // CONNEXION
  // ═══════════════════════════════════════════

  /// Connecte à un pair via son adresse MAC.
  /// Une fois connecté, onConnected(ip) sera appelé avec l'IP du group owner.
  Future<bool> connectToPeer(String mac) async {
    try {
      await _method.invokeMethod('connect', {'mac': mac});
      return true;
    } catch (e) {
      onError?.call('Connexion WiFi Direct échouée: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _method.invokeMethod('disconnect');
      _isConnected = false;
      _connectedIp = '';
    } catch (_) {}
  }

  // ═══════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════

  Future<void> dispose() async {
    _eventSub?.cancel();
    _eventSub = null;
    try {
      await _method.invokeMethod('cleanup');
    } catch (_) {}
    _initialized = false;
    _peers = [];
    _isConnected = false;
  }
}

// ─── Modèle ─────────────────────────────────────────────────────
class WifiDirectPeer {
  final String mac;
  final String name;
  final String statusLabel;

  const WifiDirectPeer({
    required this.mac,
    required this.name,
    required this.statusLabel,
  });

  String get letter => name.isNotEmpty ? name[0].toUpperCase() : '?';
  bool get isAvailable => statusLabel == 'Disponible';

  @override
  String toString() => 'WifiPeer($name @ $mac — $statusLabel)';
}
