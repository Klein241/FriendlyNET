import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/friend_peer.dart';

/// Orchestrateur principal de FriendlyNET.
///
/// Gère :
///  - Découverte des amis via le réseau mesh (Cloudflare Worker)
///  - Établissement du pont internet (hôte ou invité)
///  - Métriques et reconnexion automatique
class MeshProvider extends ChangeNotifier {
  // ─── Constantes ───
  static const _meshEndpoint = 'wss://bufferwave-tunnel.sfrfrfr.workers.dev/mesh';
  static const _prefNodeId = 'fn_node_id';
  static const _prefName = 'fn_display_name';
  static const _prefPeers = 'fn_cached_peers';

  // ─── Channels natifs ───
  static const _vpnChannel = MethodChannel('friendlynet/vpn');
  static const _relayChannel = MethodChannel('friendlynet/relay');

  // ─── État ───
  FriendRole _role = FriendRole.idle;
  MeshPhase _phase = MeshPhase.dormant;
  String _label = '';
  String _nodeId = '';
  String _info = 'Bienvenue sur FriendlyNET';
  bool _ready = false;

  // Pairs
  List<FriendPeer> _friends = [];
  FriendPeer? _bridge; // pair actuellement connecté
  FriendPeer? _pendingAsk; // demande en attente (côté hôte)

  // Mesh socket
  WebSocketChannel? _ws;
  bool _meshActive = false;
  Timer? _heartbeat;
  Timer? _refresh;

  // Métriques
  SessionMetrics _metrics = const SessionMetrics();
  Timer? _metricsTick;

  // Reconnexion
  Timer? _recoveryTimer;
  int _recoveryN = 0;
  FriendPeer? _lastBridge;
  bool _recovering = false;

  // ─── Getters ───
  FriendRole get role => _role;
  MeshPhase get phase => _phase;
  String get displayName => _label;
  String get nodeId => _nodeId;
  String get statusLine => _info;
  bool get isReady => _ready;
  List<FriendPeer> get friends => List.from(_friends);
  FriendPeer? get bridge => _bridge;
  FriendPeer? get pendingAsk => _pendingAsk;
  SessionMetrics get metrics => _metrics;

  bool get isIdle => _role == FriendRole.idle;
  bool get isHosting => _role == FriendRole.host;
  bool get isGuest => _role == FriendRole.guest && _phase == MeshPhase.live;
  bool get isSearching => _meshActive;

  // ═══════════════════════════════════════════
  // INITIALISATION
  // ═══════════════════════════════════════════

  Future<void> bootstrap() async {
    if (_ready) return;
    final prefs = await SharedPreferences.getInstance();
    _label = prefs.getString(_prefName) ?? '';
    _nodeId = prefs.getString(_prefNodeId) ?? '';
    if (_nodeId.isEmpty) {
      _nodeId = _makeNodeId();
      await prefs.setString(_prefNodeId, _nodeId);
    }
    await _loadCachedFriends();
    _ready = true;
    notifyListeners();
  }

  Future<void> updateLabel(String name) async {
    _label = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefName, _label);
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // SCAN — Rejoindre le mesh et découvrir
  // ═══════════════════════════════════════════

  Future<void> startSearch() async {
    if (_meshActive) return;

    _info = 'Connexion au réseau FriendlyNET...';
    _phase = MeshPhase.searching;
    notifyListeners();

    try {
      final uri = Uri.parse(
        '$_meshEndpoint?node=$_nodeId&name=${Uri.encodeComponent(_label)}&role=seeker',
      );
      _ws = WebSocketChannel.connect(uri);

      _ws!.stream.listen(
        _onSignal,
        onError: (e) {
          _meshActive = false;
          _info = 'Signal perdu';
          notifyListeners();
          _autoRejoin();
        },
        onDone: () {
          _meshActive = false;
          _autoRejoin();
        },
      );

      _meshActive = true;

      // Annonce
      _send({'action': 'announce', 'node': _nodeId, 'name': _label, 'role': 'seeker'});

      // Heartbeat
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
        _send({'action': 'heartbeat', 'node': _nodeId, 'ts': DateTime.now().millisecondsSinceEpoch});
      });

      // Rafraîchir les pairs
      _refresh?.cancel();
      _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
        _send({'action': 'list_peers', 'node': _nodeId});
      });

      _info = 'En ligne — recherche d\'amis...';
      notifyListeners();
    } catch (e) {
      _meshActive = false;
      _info = 'Impossible de se connecter au mesh';
      _phase = MeshPhase.broken;
      notifyListeners();
    }
  }

  void stopSearch() {
    _heartbeat?.cancel();
    _refresh?.cancel();
    try {
      _send({'action': 'depart', 'node': _nodeId});
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _meshActive = false;
    if (_phase == MeshPhase.searching) _phase = MeshPhase.dormant;
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // HÔTE — Partager sa connexion
  // ═══════════════════════════════════════════

  Future<bool> startHosting() async {
    if (_role != FriendRole.idle) return false;

    _role = FriendRole.host;
    _phase = MeshPhase.handshake;
    _info = 'Préparation du partage...';
    notifyListeners();

    // Rejoindre le mesh comme hôte
    try {
      if (!_meshActive) {
        final uri = Uri.parse(
          '$_meshEndpoint?node=$_nodeId&name=${Uri.encodeComponent(_label)}&role=provider',
        );
        _ws = WebSocketChannel.connect(uri);
        _ws!.stream.listen(_onSignal, onError: (_) {}, onDone: () {});
        _meshActive = true;
      }
      _send({'action': 'announce', 'node': _nodeId, 'name': _label, 'role': 'provider'});
    } catch (_) {}

    // Lancer le relais TCP natif
    try {
      final ok = await _relayChannel.invokeMethod('startRelay', {'port': 8899});
      if (ok != true) {
        _role = FriendRole.idle;
        _phase = MeshPhase.broken;
        _info = 'Impossible de démarrer le relais';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _role = FriendRole.idle;
      _phase = MeshPhase.broken;
      _info = 'Erreur relais: $e';
      notifyListeners();
      return false;
    }

    _phase = MeshPhase.live;
    _info = 'Partage actif — en attente d\'amis';
    _startMetrics();
    notifyListeners();
    return true;
  }

  Future<void> stopHosting() async {
    try { await _relayChannel.invokeMethod('stopRelay'); } catch (_) {}
    stopSearch();
    _role = FriendRole.idle;
    _phase = MeshPhase.dormant;
    _bridge = null;
    _info = 'Partage arrêté';
    _stopMetrics();
    _metrics = const SessionMetrics();
    notifyListeners();
  }

  void acceptGuest() {
    if (_pendingAsk != null) {
      _send({
        'action': 'bridge_accept',
        'from': _nodeId,
        'to': _pendingAsk!.uid,
        'label': _label,
      });
      _bridge = _pendingAsk;
      _pendingAsk = null;
      _info = 'Connexion avec ${_bridge!.nickname}';
      notifyListeners();
    }
  }

  void rejectGuest() {
    _pendingAsk = null;
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // INVITÉ — Utiliser la connexion d'un ami
  // ═══════════════════════════════════════════

  Future<bool> joinFriend(FriendPeer host) async {
    if (_role != FriendRole.idle) return false;

    _role = FriendRole.guest;
    _phase = MeshPhase.handshake;
    _bridge = host;
    _info = 'Connexion vers ${host.nickname}...';
    notifyListeners();

    // Envoyer la demande de pont
    _send({
      'action': 'bridge_offer',
      'from': _nodeId,
      'to': host.uid,
      'label': _label,
    });

    // Démarrer le tunnel VPN
    try {
      final ok = await _vpnChannel.invokeMethod('startVpn', {
        'nodeId': host.uid,
        'userId': _nodeId,
        'killSwitch': false,
        'localProxy': true,
        'proxyHost': host.meshIp.isNotEmpty ? host.meshIp : host.uid,
        'proxyPort': 8899,
        'workerUrl': 'wss://bufferwave-tunnel.sfrfrfr.workers.dev/tunnel',
        'tunnelKey': '',
      });

      if (ok == true) {
        _phase = MeshPhase.live;
        _info = 'Internet via ${host.nickname} ✓';
        _startMetrics();
        notifyListeners();
        return true;
      }
    } catch (e) {
      _info = 'Erreur tunnel: $e';
    }

    _phase = MeshPhase.broken;
    _info = 'Impossible d\'établir le tunnel';
    notifyListeners();
    return false;
  }

  Future<void> leaveFriend() async {
    try { await _vpnChannel.invokeMethod('stopVpn'); } catch (_) {}
    stopSearch();
    _role = FriendRole.idle;
    _phase = MeshPhase.dormant;
    _bridge = null;
    _info = 'Déconnecté';
    _stopMetrics();
    _metrics = const SessionMetrics();
    _cancelRecovery();
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // SIGNALING — Traitement des messages mesh
  // ═══════════════════════════════════════════

  void _onSignal(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final action = data['action'] as String? ?? '';

      switch (action) {
        case 'peer_list':
          _handlePeerList(data);
          break;
        case 'bridge_offer':
          _handleBridgeOffer(data);
          break;
        case 'bridge_accept':
          _handleBridgeAccept(data);
          break;
        case 'peer_joined':
          _send({'action': 'list_peers', 'node': _nodeId});
          break;
      }
    } catch (_) {}
  }

  void _handlePeerList(Map<String, dynamic> data) {
    final raw = data['peers'] as List? ?? [];
    _friends.clear();

    for (final item in raw) {
      final m = Map<String, dynamic>.from(item as Map);
      final id = m['node'] as String? ?? '';
      if (id == _nodeId || id.isEmpty) continue;

      _friends.add(FriendPeer(
        uid: id,
        nickname: m['name'] as String? ?? 'Ami',
        meshIp: m['meshAddr'] as String? ?? '',
        netKind: _parseNet(m['access'] as String? ?? ''),
        strength: m['quality'] as int? ?? 50,
        hosting: m['role'] == 'provider',
        online: m['alive'] as bool? ?? true,
        bandwidth: m['bw'] as int? ?? 0,
        country: m['region'] as String? ?? '',
      ));
    }

    // Hôtes en premier, puis par qualité
    _friends.sort((a, b) {
      if (a.hosting && !b.hosting) return -1;
      if (!a.hosting && b.hosting) return 1;
      return b.strength.compareTo(a.strength);
    });

    _cacheFriends();
    notifyListeners();
  }

  void _handleBridgeOffer(Map<String, dynamic> data) {
    if (_role != FriendRole.host) return;
    final from = data['from'] as String? ?? '';
    final label = data['label'] as String? ?? 'Quelqu\'un';
    if (from == _nodeId) return;

    _pendingAsk = FriendPeer(uid: from, nickname: label, hosting: false, online: true);
    notifyListeners();
  }

  void _handleBridgeAccept(Map<String, dynamic> data) {
    if (_role != FriendRole.guest) return;
    _info = 'Pont accepté !';
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // RECONNEXION AUTOMATIQUE
  // ═══════════════════════════════════════════

  void _handleGuestDrop() {
    if (_recovering) return;
    _lastBridge ??= _bridge;
    if (_recoveryN >= 8) {
      _info = 'Connexion perdue définitivement';
      _cancelRecovery();
      leaveFriend();
      return;
    }
    _recovering = true;
    _phase = MeshPhase.recovering;
    _recoveryN++;
    final wait = Duration(seconds: (2 * (1 << (_recoveryN - 1))).clamp(2, 30));
    _info = 'Reconnexion $_recoveryN/8 dans ${wait.inSeconds}s...';
    notifyListeners();
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(wait, _tryRecover);
  }

  Future<void> _tryRecover() async {
    final target = _lastBridge;
    if (target == null || _role != FriendRole.guest) {
      _recovering = false;
      return;
    }
    _info = 'Reconnexion vers ${target.nickname}...';
    notifyListeners();
    try {
      await _vpnChannel.invokeMethod('stopVpn');
      final ok = await joinFriend(target);
      if (ok) {
        _recovering = false;
        _recoveryN = 0;
      } else {
        _recovering = false;
        _handleGuestDrop();
      }
    } catch (_) {
      _recovering = false;
      _handleGuestDrop();
    }
  }

  void _cancelRecovery() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recovering = false;
    _recoveryN = 0;
  }

  // ═══════════════════════════════════════════
  // UTILITAIRES
  // ═══════════════════════════════════════════

  void _send(Map<String, dynamic> msg) {
    try { _ws?.sink.add(jsonEncode(msg)); } catch (_) {}
  }

  void _autoRejoin() {
    Future.delayed(const Duration(seconds: 5), () {
      if (!_meshActive && _role != FriendRole.idle) startSearch();
    });
  }

  void _startMetrics() {
    _metricsTick?.cancel();
    final origin = DateTime.now();
    _metricsTick = Timer.periodic(const Duration(seconds: 1), (_) {
      _metrics = _metrics.evolve(elapsed: DateTime.now().difference(origin));
      notifyListeners();
    });
  }

  void _stopMetrics() {
    _metricsTick?.cancel();
    _metricsTick = null;
  }

  Future<void> _cacheFriends() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _friends
          .where((f) => f.hosting)
          .take(15)
          .map((f) => jsonEncode(f.pack()))
          .toList();
      await prefs.setStringList(_prefPeers, encoded);
    } catch (_) {}
  }

  Future<void> _loadCachedFriends() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefPeers) ?? [];
      for (final str in raw) {
        final m = jsonDecode(str) as Map<String, dynamic>;
        final peer = FriendPeer.unpack(m);
        if (!_friends.any((f) => f.uid == peer.uid)) {
          _friends.add(peer.refresh(online: false));
        }
      }
    } catch (_) {}
  }

  NetKind _parseNet(String raw) {
    switch (raw.toLowerCase()) {
      case '4g': case 'lte': return NetKind.lte;
      case '5g': case 'nr': return NetKind.fiveG;
      case 'wifi': case 'wlan': return NetKind.wifi;
      default: return NetKind.offline;
    }
  }

  String _makeNodeId() {
    final rng = Random.secure();
    return List.generate(8, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void dispose() {
    stopSearch();
    _metricsTick?.cancel();
    _recoveryTimer?.cancel();
    super.dispose();
  }
}
