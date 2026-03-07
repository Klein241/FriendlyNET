import 'dart:async';
import 'package:flutter/services.dart';

/// Service de liaison P2P — gère la connexion directe entre 2 appareils.
/// Après que PeerDiscoveryService a trouvé un pair, ce service
/// établit et maintient la connexion.
class PeerLinkService {
  static const MethodChannel _channel =
      MethodChannel('friendlynet/wifidirect');

  String? _connectedIp;
  bool _linked = false;

  Function(String ip)? onLinked;
  Function()? onUnlinked;
  Function(String)? onError;

  /// Connecte à un pair découvert via son adresse MAC.
  Future<bool> link(String mac) async {
    try {
      await _channel.invokeMethod('connect', {'mac': mac});
      _linked = true;
      return true;
    } on PlatformException catch (e) {
      onError?.call('Link échoué: ${e.message}');
      return false;
    }
  }

  /// Appelé quand le natif confirme la connexion (via event stream).
  void confirmLink(String ip) {
    _connectedIp = ip;
    _linked = true;
    onLinked?.call(ip);
  }

  /// Déconnecte le lien P2P.
  Future<void> unlink() async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (_) {}
    _linked = false;
    _connectedIp = null;
    onUnlinked?.call();
  }

  bool get isLinked => _linked;
  String? get connectedIp => _connectedIp;

  void dispose() {
    unlink();
  }
}
