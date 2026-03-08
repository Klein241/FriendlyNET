import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:logger/logger.dart';

/// ════════════════════════════════════════════════════════════════
/// HostRelay — Remplace EdgeRelay de bufferwave_core
///
/// Se connecte à une URL WebSocket EXACTE sans modifier les query params.
/// Gère le pairing Worker, keepalive, reconnexion automatique.
///
/// ✅ CORRIGÉ — EdgeRelay ajoutait ses propres user= et peer=
/// ce qui doublait les paramètres et cassait le pairing Worker.
/// HostRelay envoie l'URL telle quelle → pairing immédiat.
/// ════════════════════════════════════════════════════════════════
class HostRelay {
  final String tunnelUrl; // URL complète avec user= et peer= déjà inclus
  final String localId;
  final String peerId;

  void Function(Uint8List data)? onData;
  void Function()? onPaired;
  void Function()? onDisconnected;
  void Function(String error)? onError;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _keepalive;
  Timer? _reconnectTimer;
  bool _running = false;
  bool _paired = false;
  int _attempts = 0;
  static const _maxAttempts = 20;

  static final _log = Logger(printer: SimplePrinter(colors: false));

  bool get isPaired => _paired;
  bool get isConnected => _channel != null && _running;

  HostRelay({
    required this.tunnelUrl,
    required this.localId,
    required this.peerId,
  });

  /// Connecte au Worker. Retourne true si connexion initiale réussie.
  Future<bool> connect() async {
    _running = true;
    _attempts = 0;
    return _doConnect();
  }

  Future<bool> _doConnect() async {
    if (!_running) return false;
    try {
      // ✅ CRITIQUE — connexion à l'URL EXACTE, aucun param ajouté
      _channel = WebSocketChannel.connect(Uri.parse(tunnelUrl));
      await _channel!.ready;
      _paired = false;
      _attempts = 0;
      _log.i('[HostRelay] Connecté à $tunnelUrl');

      _sub = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (e) {
          onError?.call('WS error: $e');
          _onDisconnect();
        },
      );

      _startKeepalive();
      return true;
    } catch (e) {
      _log.w('[HostRelay] Connect fail: $e');
      onError?.call('Connect fail: $e');
      _scheduleReconnect();
      return false;
    }
  }

  /// Traite les messages entrants du WebSocket.
  /// - Binaire (List<int> / Uint8List) → onData callback (paquets IP)
  /// - String JSON avec action "relay_paired" → onPaired callback
  /// - Autre String → traité comme binaire brut
  void _onMessage(dynamic raw) {
    if (raw is List<int>) {
      onData?.call(Uint8List.fromList(raw));
      return;
    }
    if (raw is Uint8List) {
      onData?.call(raw);
      return;
    }
    if (raw is String) {
      // Le Worker peut envoyer des messages JSON de contrôle
      try {
        final msg = jsonDecode(raw) as Map<String, dynamic>;
        final action = msg['action'] as String? ?? '';
        if (action == 'relay_paired') {
          _paired = true;
          _log.i('[HostRelay] ✅ Paired avec $peerId');
          onPaired?.call();
        }
        // "relay_waiting" = en attente du partenaire, keepalive continue
      } catch (_) {
        // Pas du JSON → traiter comme données brutes
        onData?.call(Uint8List.fromList(raw.codeUnits));
      }
    }
  }

  /// Envoie des données binaires au pair via le WebSocket.
  bool sendBinary(Uint8List data) {
    if (_channel == null || !_running) return false;
    try {
      _channel!.sink.add(data);
      return true;
    } catch (e) {
      onError?.call('Send error: $e');
      return false;
    }
  }

  /// Keepalive toutes les 20s pour maintenir le WebSocket ouvert.
  void _startKeepalive() {
    _keepalive?.cancel();
    _keepalive = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_running || _channel == null) return;
      try {
        _channel!.sink.add(jsonEncode({'a': 'ping', 'n': localId}));
      } catch (_) {}
    });
  }

  void _onDisconnect() {
    if (!_running) return;
    _paired = false;
    _keepalive?.cancel();
    _sub?.cancel();
    _channel = null;
    onDisconnected?.call();
    _scheduleReconnect();
  }

  /// Reconnexion avec backoff exponentiel : 2s, 4s, 6s, ... max 60s
  void _scheduleReconnect() {
    if (!_running || _attempts >= _maxAttempts) return;
    _attempts++;
    final delay = (_attempts * 2000).clamp(2000, 60000);
    _log.w('[HostRelay] Reconnexion dans ${delay}ms (tentative $_attempts/$_maxAttempts)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (_running) _doConnect();
    });
  }

  /// Déconnecte proprement le WebSocket et annule tous les timers.
  Future<void> disconnect() async {
    _running = false;
    _paired = false;
    _keepalive?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  /// Dispose complète : déconnexion + nettoyage callbacks.
  void dispose() {
    disconnect();
    onData = null;
    onPaired = null;
    onDisconnected = null;
    onError = null;
  }
}
