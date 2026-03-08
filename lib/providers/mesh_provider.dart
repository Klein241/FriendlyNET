// CORRECTION APPLIQUÉE : startHosting() refresh manquant + Bluetooth permission supprimée
// DATE : 2025-03-08
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:logger/logger.dart';
import 'package:bufferwave_core/bufferwave_core.dart' show EdgeRelay;
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart' show BleDiscoveredDevice, HotspotHostState;
import '../models/friend_peer.dart';
import '../services/wifi_direct_service.dart';
import '../services/e2e_service.dart';
import '../services/connectivity_monitor.dart';
import '../services/bufferwave_api_service.dart';
import '../services/notification_service.dart';

/// Orchestrateur principal de FriendlyNET.
///
/// Fonctionnalités critiques :
///  1. Découverte mesh globale (Cloudflare Worker)
///  2. Low Bandwidth Mode — survie en mode throttlé Orange
///  3. Auto-Consent — case consentement, plus besoin d'approuver
///  4. Foreground Service — Android ne tue pas l'app
///  5. Battery Optimization Bypass — données illimitées en arrière-plan
///  6. Reconnexion aggressive — jusqu'à 20 tentatives avec backoff
///
/// Scénario Orange 100 Mo :
///   Jean active 100 Mo → établit tunnel (5 Mo) → tout passe par Marie.
///   Orange coupe/throttle → le tunnel WebSocket survit sur keepalive
///   ultra-léger (48 bytes / 45 sec). Jean continue YouTube via Marie.
class MeshProvider extends ChangeNotifier {
  // ─── Constantes ───
  static const _prefNodeId  = 'fn_node_id';
  static const _prefName    = 'fn_display_name';
  static const _prefPeers   = 'fn_cached_peers';
  static const _prefConsent = 'fn_auto_consent';
  static const _prefLowBw   = 'fn_low_bandwidth';

  // Logger
  static final _log = Logger(
    printer: SimplePrinter(colors: false),
    level: Level.debug,
  );

  // ─── Channels natifs ───
  static const _vpnChannel    = MethodChannel('friendlynet/vpn');
  static const _relayChannel  = MethodChannel('friendlynet/relay');
  static const _systemChannel = MethodChannel('friendlynet/system');

  // ─── État ───
  FriendRole  _role  = FriendRole.idle;
  MeshPhase   _phase = MeshPhase.dormant;
  String _label  = '';
  String _nodeId = '';
  String _info   = 'Bienvenue sur FriendlyNET';
  bool   _ready  = false;

  bool _autoConsent  = true;
  bool _lowBandwidth = false;

  // Pairs
  final List<FriendPeer> _friends = [];
  FriendPeer? _bridge;
  FriendPeer? _pendingAsk;

  // Mesh socket
  WebSocketChannel? _ws;
  bool   _meshActive = false;
  Timer? _heartbeat;
  Timer? _refresh;

  // Métriques
  SessionMetrics _metrics = const SessionMetrics();
  Timer? _metricsTick;
  int _sessionUpBytes = 0;
  int _sessionDownBytes = 0;

  // Reconnexion renforcée
  Timer? _recoveryTimer;
  int _recoveryN = 0;
  FriendPeer? _lastBridge;
  bool _recovering = false;
  static const int _maxRecoveryAttempts = 20;

  // WebSocket health monitoring
  Timer? _wsHealthCheck;
  DateTime? _lastWsActivity;

  // WiFi Direct (P2P réel via LocalOnlyHotspot + BLE)
  final WifiDirectService _wifiDirect = WifiDirectService();
  List<BleDiscoveredDevice> _wifiPeers = [];
  bool   _wifiDirectActive = false;
  String _wifiDirectIp     = '';
  HotspotHostState? _hotspotState;

  // ─── Nouveaux services ───
  final E2EService             _e2e      = E2EService();
  final ConnectivityMonitor    _connMon  = ConnectivityMonitor();
  final BufferwaveApiService   _bwApi    = BufferwaveApiService();
  final NotificationService    _notif    = NotificationService();
  Timer? _bwHeartbeatTimer;

  // ─── Getters ───
  FriendRole get role        => _role;
  MeshPhase  get phase       => _phase;
  String get displayName     => _label;
  String get nodeId          => _nodeId;
  String get statusLine      => _info;
  bool   get isReady         => _ready;
  List<FriendPeer> get friends => List.from(_friends);
  FriendPeer? get bridge     => _bridge;
  FriendPeer? get pendingAsk => _pendingAsk;
  SessionMetrics get metrics => _metrics;
  bool get autoConsent       => _autoConsent;
  bool get lowBandwidth      => _lowBandwidth;

  bool get isIdle     => _role == FriendRole.idle;
  bool get isHosting  => _role == FriendRole.host;
  bool get isGuest    => _role == FriendRole.guest && _phase == MeshPhase.live;
  bool get isSearching => _meshActive;

  // WiFi Direct getters
  List<BleDiscoveredDevice> get wifiPeers => List.from(_wifiPeers);
  bool   get wifiDirectActive             => _wifiDirectActive;
  String get wifiDirectIp                 => _wifiDirectIp;
  HotspotHostState? get hotspotInfo       => _hotspotState;

  // E2E getters
  String get e2eFingerprint => _e2e.fingerprint;
  bool   get e2eReady       => _e2e.isReady;
  bool   get workerOnline   => _bwApi.isWorkerOnline;

  // Intervalles adaptatifs
  int get _heartbeatSec => _lowBandwidth ? 45 : 15;
  int get _refreshSec   => _lowBandwidth ? 30 : 5;
  // Mesh endpoint (depuis BufferwaveApiService ou fallback)
  String get _meshEndpoint => _bwApi.isInitialized
      ? _bwApi.meshWssUrl
      : 'wss://friendlynet-mesh.bufferwave.workers.dev/mesh';

  // ═══════════════════════════════════════════
  // INITIALISATION
  // ═══════════════════════════════════════════

  Future<void> bootstrap() async {
    if (_ready) return;
    final prefs = await SharedPreferences.getInstance();
    _label        = prefs.getString(_prefName)    ?? '';
    _nodeId       = prefs.getString(_prefNodeId)  ?? '';
    _autoConsent  = prefs.getBool(_prefConsent)   ?? true;  // ON par défaut
    _lowBandwidth = prefs.getBool(_prefLowBw)     ?? false;
    if (_nodeId.isEmpty) {
      _nodeId = _makeNodeId();
      await prefs.setString(_prefNodeId, _nodeId);
    }
    await _loadCachedFriends();

    // ─── Init E2E (génère la paire de clés X25519 locale) ───
    await _e2e.initialize();
    _log.i('E2E prêt — fingerprint: ${_e2e.fingerprint}');

    // ─── Init Notifications ───
    await _notif.initialize();

    // ─── Init BufferWave API (health-check Worker + DoH) ───
    unawaited(_bwApi.initialize(_nodeId).then((_) {
      if (_bwApi.isWorkerOnline) {
        _startBwHeartbeat();
      } else {
        _log.w('Worker Cloudflare hors ligne — mode dégradé local');
      }
      notifyListeners();
    }));

    // ─── Init ConnectivityMonitor (auto-détection throttle) ───
    _connMon.onLowBandwidth = (isLow) {
      if (isLow != _lowBandwidth) {
        _log.i('Auto low-bandwidth: $isLow');
        setLowBandwidth(isLow);
        _info = isLow
            ? '⚠️ Débit faible détecté — mode éco activé'
            : '✅ Débit restauré — mode normal';
        notifyListeners();
      }
    };
    _connMon.onStatusMessage = (msg) {
      _log.d('Réseau: $msg');
    };
    unawaited(_connMon.start());

    _ready = true;
    notifyListeners();

    // ✅ CORRIGÉ — protections système supprimées du bootstrap
    // Elles sont maintenant déclenchées par PermissionGatewayScreen
  }

  static const _prefSystemPermsGranted = 'fn_system_perms_done';

  /// À appeler UNE SEULE FOIS depuis PermissionGatewayScreen
  /// après que l'utilisateur a cliqué "Activer".
  /// ✅ CORRIGÉ — dialogs système uniquement après consentement utilisateur
  Future<void> activateSystemProtections() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefSystemPermsGranted) == true) return;
    try {
      await requestBatteryExemption();
      await requestUnrestrictedData();
      await startForegroundGuard();
      await prefs.setBool(_prefSystemPermsGranted, true);
    } catch (_) {}
  }

  Future<void> updateLabel(String name) async {
    _label = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefName, _label);
    notifyListeners();
  }

  /// Active/désactive l'auto-consentement.
  /// Quand activé, les demandes de connexion sont acceptées
  /// automatiquement sans notification (Marie n'a plus besoin
  /// d'approuver Jean à chaque fois).
  Future<void> setAutoConsent(bool val) async {
    _autoConsent = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefConsent, val);
    notifyListeners();
  }

  /// Active le mode basse consommation de données.
  /// Heartbeat toutes les 45s au lieu de 15s.
  /// Peer refresh toutes les 30s au lieu de 5s.
  /// Keepalive WebSocket minimal.
  Future<void> setLowBandwidth(bool val) async {
    _lowBandwidth = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefLowBw, val);

    // Reconfigurer les timers si actif
    if (_meshActive) {
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(
        Duration(seconds: _heartbeatSec),
        (_) => _sendHeartbeat(),
      );
      _refresh?.cancel();
      _refresh = Timer.periodic(
        Duration(seconds: _refreshSec), // 30s en éco, 5s normal
        (_) => _send({'action': 'list_peers', 'node': _nodeId}),
      );
    }
    notifyListeners();
  }

  // ═══════════════════════════════════════════
  // ANDROID SYSTEM PROTECTION
  // ═══════════════════════════════════════════

  /// Demande à Android d'exempter l'app des optimisations batterie.
  /// Critique pour que le tunnel survive en arrière-plan quand
  /// le forfait Orange est épuisé et la data est throttlée.
  Future<bool> requestBatteryExemption() async {
    try {
      final result = await _systemChannel.invokeMethod('requestBatteryOptExemption');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Vérifie si l'app est exempte des restrictions batterie.
  Future<bool> isBatteryExempt() async {
    try {
      final result = await _systemChannel.invokeMethod('isBatteryOptExempt');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Demande à Android d'autoriser les données illimitées
  /// en arrière-plan (unrestricted data).
  Future<bool> requestUnrestrictedData() async {
    try {
      final result = await _systemChannel.invokeMethod('requestUnrestrictedData');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  // ═══════════════════════════════════════════
  // WIFI DIRECT — Découverte locale 0 data
  // ═══════════════════════════════════════════

  /// Démarre la découverte WiFi Direct via BLE.
  /// Trouve les hôtes FriendlyNET proches sans utiliser de data mobile.
  /// Utilise le scan BLE pour détecter les hotspots LocalOnlyHotspot.
  Future<void> startWifiDirect() async {
    // S'assurer que les permissions sont accordées
    final permsOk = await _wifiDirect.ensurePermissions();
    if (!permsOk) {
      _info = 'Permissions WiFi Direct / BLE refusées';
      notifyListeners();
      return;
    }

    _wifiDirect.onDevicesFound = (devices) {
      _wifiPeers = devices;
      _info = '${devices.length} appareil(s) WiFi Direct trouvé(s)';
      notifyListeners();
    };
    _wifiDirect.onConnectedToHost = (ip) {
      _wifiDirectIp = ip;
      _wifiDirectActive = true;
      _info = 'WiFi Direct connecté — IP: $ip';
      notifyListeners();
    };
    _wifiDirect.onDisconnected = () {
      _wifiDirectActive = false;
      _wifiDirectIp = '';
      _info = 'WiFi Direct déconnecté';
      notifyListeners();
    };
    _wifiDirect.onError = (msg) {
      _info = 'WiFi Direct: $msg';
      notifyListeners();
    };
    _wifiDirect.onLog = (msg) {
      _log.d('[P2P] $msg');
    };
    _wifiDirect.onHotspotReady = (state) {
      _hotspotState = state;
      _info = 'Hotspot actif: ${state.ssid}';
      notifyListeners();
    };

    final ok = await _wifiDirect.startScanning();
    if (ok) {
      _info = 'Scan BLE en cours...';
      notifyListeners();
    }
  }

  Future<void> stopWifiDirect() async {
    await _wifiDirect.stopScanning();
    await _wifiDirect.stopHosting();
    _wifiPeers = [];
    _wifiDirectActive = false;
    _wifiDirectIp = '';
    _hotspotState = null;
    notifyListeners();
  }

  /// Se connecte à un hôte WiFi Direct découvert via BLE.
  /// Le flux complet est automatique :
  ///   BLE connect → read SSID+PSK → WiFi hotspot connect → transport P2P
  Future<bool> connectWifiDirect(BleDiscoveredDevice device) async {
    _info = 'Connexion à ${device.deviceName}...';
    notifyListeners();
    return await _wifiDirect.connectToHost(device);
  }

  /// Démarre le mode hôte WiFi Direct.
  /// Crée un hotspot local et diffuse les identifiants via BLE.
  Future<bool> startWifiDirectHosting() async {
    final permsOk = await _wifiDirect.ensurePermissions();
    if (!permsOk) {
      _info = 'Permissions WiFi Direct refusées';
      notifyListeners();
      return false;
    }

    _wifiDirect.onHotspotReady = (state) {
      _hotspotState = state;
      _wifiDirectActive = true;
      _wifiDirectIp = state.hostIpAddress ?? '';
      _info = 'Hotspot actif: ${state.ssid} (${state.hostIpAddress})';
      notifyListeners();
    };
    _wifiDirect.onError = (msg) {
      _info = 'WiFi Direct: $msg';
      notifyListeners();
    };
    _wifiDirect.onLog = (msg) {
      _log.d('[P2P Host] $msg');
    };

    final state = await _wifiDirect.startHosting();
    if (state != null) {
      _hotspotState = state;
      _wifiDirectActive = true;
      _wifiDirectIp = state.hostIpAddress ?? '';
      _info = 'Hotspot WiFi Direct actif: ${state.ssid}';
      notifyListeners();
      return true;
    }
    return false;
  }

  // ═══════════════════════════════════════════
  // DEEPLINKS ANDROID SETTINGS
  // ═══════════════════════════════════════════

  /// Ouvre les paramètres "Données non restreintes" pour cette app.
  /// Essentiel pour survivre en mode Data Saver d'Orange.
  Future<void> openDataSaverSettings() async {
    try { await _systemChannel.invokeMethod('openDataSaverSettings'); } catch (_) {}
  }

  /// Ouvre les paramètres batterie pour désactiver l'optimisation.
  Future<void> openBatterySettings() async {
    try { await _systemChannel.invokeMethod('openBatterySettings'); } catch (_) {}
  }

  /// Lance le foreground service Android avec notification
  /// persistante. Empêche Android de tuer le processus.
  Future<bool> startForegroundGuard() async {
    try {
      final result = await _systemChannel.invokeMethod('startForeground', {
        'title': 'FriendlyNET actif',
        'body': _role == FriendRole.host
            ? 'Partage Internet en cours'
            : 'Connecté via un ami',
      });
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Arrête le foreground service.
  /// ✅ CORRIGÉ — timeout 2s garanti, pas de await bloquant
  Future<void> stopForegroundGuard() async {
    try {
      await _systemChannel
          .invokeMethod('stopForeground')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
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
      final mode = _lowBandwidth ? '&lowbw=1' : '';
      final uri = Uri.parse(
        '$_meshEndpoint?node=$_nodeId&name=${Uri.encodeComponent(_label)}&role=seeker$mode',
      );
      _ws = WebSocketChannel.connect(uri);

      _ws!.stream.listen(
        (data) {
          _lastWsActivity = DateTime.now();
          _onSignal(data);
        },
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
      _lastWsActivity = DateTime.now();

      // Annonce
      _send({'action': 'announce', 'node': _nodeId, 'name': _label, 'role': 'seeker'});

    // Demander la liste immédiatement après l'annonce
    await Future.delayed(const Duration(milliseconds: 500));
    _send({'action': 'list_peers', 'node': _nodeId});

    // Refresh agressif pour la première découverte
    Future.delayed(const Duration(seconds: 2), () {
      if (_meshActive) _send({'action': 'list_peers', 'node': _nodeId});
    });
    Future.delayed(const Duration(seconds: 5), () {
      if (_meshActive) _send({'action': 'list_peers', 'node': _nodeId});
    });

      // Heartbeat (adapté au mode basse conso)
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(
        Duration(seconds: _heartbeatSec),
        (_) => _sendHeartbeat(),
      );

      // Rafraîchir les pairs — toujours actif, juste plus lent en éco
      _refresh?.cancel();
      _refresh = Timer.periodic(
        Duration(seconds: _refreshSec), // 30s en éco, 5s normal
        (_) => _send({'action': 'list_peers', 'node': _nodeId}),
      );

      // Health check WebSocket (détecte si WS est mort silencieusement)
      _wsHealthCheck?.cancel();
      _wsHealthCheck = Timer.periodic(const Duration(seconds: 60), (_) {
        _checkWsHealth();
      });

      _info = _lowBandwidth
          ? 'Mode éco-data — en ligne'
          : 'En ligne — recherche d\'amis...';
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
    _wsHealthCheck?.cancel();
    try {
      _send({'action': 'depart', 'node': _nodeId});
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _meshActive = false;
    if (_phase == MeshPhase.searching) _phase = MeshPhase.dormant;
    notifyListeners();
  }

  /// Demande manuelle la liste des pairs (utile en mode low bandwidth).
  void refreshPeersNow() {
    _send({'action': 'list_peers', 'node': _nodeId});
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

    // Protection Android : foreground service + battery exemption
    await startForegroundGuard();
    await requestBatteryExemption();

    // Rejoindre le mesh comme hôte
    try {
      if (!_meshActive) {
        final uri = Uri.parse(
          '$_meshEndpoint?node=$_nodeId&name=${Uri.encodeComponent(_label)}&role=provider',
        );
        _ws = WebSocketChannel.connect(uri);
        _ws!.stream.listen(
          (data) {
            _lastWsActivity = DateTime.now();
            _onSignal(data);
          },
          onError: (_) => _autoRejoin(),
          onDone: () => _autoRejoin(),
        );
        _meshActive = true;
        _lastWsActivity = DateTime.now();
      }
      _send({'action': 'announce', 'node': _nodeId, 'name': _label, 'role': 'provider'});

      // Demander la liste immédiatement après l'annonce hôte
      await Future.delayed(const Duration(milliseconds: 500));
      _send({'action': 'list_peers', 'node': _nodeId});

      // Refresh agressif pour la première découverte
      Future.delayed(const Duration(seconds: 2), () {
        if (_meshActive) _send({'action': 'list_peers', 'node': _nodeId});
      });
      Future.delayed(const Duration(seconds: 5), () {
        if (_meshActive) _send({'action': 'list_peers', 'node': _nodeId});
      });

      // Heartbeat en mode hôte
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(
        Duration(seconds: _heartbeatSec),
        (_) => _sendHeartbeat(),
      );

      // Rafraîchir les pairs — toujours actif, juste plus lent en éco
      _refresh?.cancel();
      _refresh = Timer.periodic(
        Duration(seconds: _refreshSec), // 30s en éco, 5s normal
        (_) => _send({'action': 'list_peers', 'node': _nodeId}),
      );
      // ✅ CORRIGÉ — Ajout du timer _refresh dans startHosting() pour que les hôtes découvrent les pairs

      // Health check WebSocket (détecte si WS est mort silencieusement)
      _wsHealthCheck?.cancel();
      _wsHealthCheck = Timer.periodic(const Duration(seconds: 60), (_) {
        _checkWsHealth();
      });
    } catch (_) {}

    // Lancer le relais TCP natif
    try {
      final ok = await _relayChannel.invokeMethod('startRelay', {'port': 8899});
      if (ok != true) {
        _role = FriendRole.idle;
        _phase = MeshPhase.broken;
        _info = 'Impossible de démarrer le relais';
        await stopForegroundGuard();
        notifyListeners();
        return false;
      }
    } catch (e) {
      _role = FriendRole.idle;
      _phase = MeshPhase.broken;
      _info = 'Erreur relais: $e';
      await stopForegroundGuard();
      notifyListeners();
      return false;
    }

    _phase = MeshPhase.live;
    _info = _autoConsent
        ? 'Partage actif — acceptation auto ✓'
        : 'Partage actif — en attente d\'amis';
    _startMetrics();
    notifyListeners();
    return true;
  }

  /// ✅ CORRIGÉ — notifyListeners() garanti même si service mort
  Future<void> stopHosting() async {
    try {
      _hostRelay?.dispose();
      _hostRelay = null;
      _relayChannel.setMethodCallHandler(null);
    } catch (_) {}
    try {
      await _relayChannel
          .invokeMethod('stopRelay')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await stopForegroundGuard();
    } catch (_) {}
    stopSearch();
    // Toujours exécuté même si erreur au-dessus
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
      final guestId = _pendingAsk!.uid;
      final accept = <String, dynamic>{
        'action': 'bridge_accept',
        'from': _nodeId,
        'to': guestId,
        'label': _label,
      };
      if (_e2e.isReady) accept['pubKey'] = _e2e.publicKeyB64;
      _send(accept);
      _bridge = _pendingAsk;
      _pendingAsk = null;
      _info = 'Connexion avec ${_bridge!.nickname}';
      _notif.notifyConnected(_bridge!.nickname, asHost: true);
      // Start relay tunnel for manual consent
      _startHostRelayTunnel(guestId);
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
    if (_role != FriendRole.idle && !_recovering) return false;

    if (!_recovering) {
      _role  = FriendRole.guest;
      _phase = MeshPhase.handshake;
    }
    _bridge = host;
    _info   = 'Connexion vers ${host.nickname}...';
    notifyListeners();

    // Protection Android
    if (!_recovering) {
      await startForegroundGuard();
      await requestBatteryExemption();

      // Request VPN permission at runtime (Android shows system dialog)
      try {
        final hasVpnPermission = await _vpnChannel.invokeMethod('prepareVpn');
        if (hasVpnPermission != true) {
          _info = 'Permission VPN requise';
          _phase = MeshPhase.broken;
          notifyListeners();
          return false;
        }
      } catch (e) {
        _log.w('VPN permission check: $e');
        // Continue anyway — startVpn will handle the permission dialog
      }
    }

    // ─── Envoyer la demande de pont (avec clé publique E2E) ───
    final offer = <String, dynamic>{
      'action': 'bridge_offer',
      'from':   _nodeId,
      'to':     host.uid,
      'label':  _label,
    };
    if (_e2e.isReady) offer['pubKey'] = _e2e.publicKeyB64;
    _send(offer);

    // Démarrer le tunnel VPN
    try {
      final ok = await _vpnChannel.invokeMethod('startVpn', {
        'nodeId':            host.uid,
        'userId':            _nodeId,
        'killSwitch':        false,
        'localProxy':        true,
        'proxyHost':         host.meshIp.isNotEmpty ? host.meshIp : host.uid,
        'proxyPort':         8899,
        'workerUrl':         'wss://friendlynet-mesh.bufferwave.workers.dev/tunnel',
        'tunnelKey':         '',
        'lowBandwidth':      _lowBandwidth,
        'keepaliveInterval': _lowBandwidth ? 45 : 15,
      });

      if (ok == true) {
        _phase = MeshPhase.live;
        _info  = 'Internet via ${host.nickname} ✓';
        if (!_recovering) _startMetrics();
        notifyListeners();
        return true;
      }
    } catch (e) {
      _info = 'Erreur tunnel: $e';
    }

    _phase = MeshPhase.broken;
    _info  = 'Impossible d\'établir le tunnel';
    notifyListeners();
    return false;
  }

  /// ✅ CORRIGÉ — notifyListeners() garanti, pas d'écran noir
  Future<void> leaveFriend() async {
    try {
      _hostRelay?.dispose();
      _hostRelay = null;
      _relayChannel.setMethodCallHandler(null);
    } catch (_) {}
    try {
      await _vpnChannel
          .invokeMethod('stopVpn')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await stopForegroundGuard();
    } catch (_) {}
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
  // SIGNALING
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
          final peerName = data['name'] as String? ?? 'Pair';
          _notif.notifyNewPeer(peerName);
          if (!_lowBandwidth) {
            _send({'action': 'list_peers', 'node': _nodeId});
          }
          break;
        case 'peer_left':
          final peerName = data['name'] as String? ?? 'Pair';
          _notif.notifyPeerLeft(peerName);
          break;
        case 'heartbeat_ack':
          // Connexion confirmée vivante
          break;
      }
    } catch (_) {}
  }

  void _handlePeerList(Map<String, dynamic> data) {
    final raw = data['peers'] as List? ?? [];
    final incoming = <FriendPeer>[];

    for (final item in raw) {
      final m = Map<String, dynamic>.from(item as Map);
      final id = m['node'] as String? ?? '';
      if (id == _nodeId || id.isEmpty) continue;

      incoming.add(FriendPeer(
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

    // Ne pas effacer la liste si la réponse est vide
    if (incoming.isNotEmpty) {
      _friends
        ..clear()
        ..addAll(incoming);

      _friends.sort((a, b) {
        if (a.hosting && !b.hosting) return -1;
        if (!a.hosting && b.hosting) return 1;
        return b.strength.compareTo(a.strength);
      });

      _cacheFriends();
    }
    notifyListeners();
  }

  void _handleBridgeOffer(Map<String, dynamic> data) {
    if (_role != FriendRole.host) return;
    final from  = data['from']  as String? ?? '';
    final label = data['label'] as String? ?? 'Quelqu\'un';
    if (from == _nodeId) return;

    // ─── E2E : dériver la clé partagée avec l'invité ───
    final peerPubKey = data['pubKey'] as String?;
    if (peerPubKey != null && E2EService.isValidPublicKey(peerPubKey) && _e2e.isReady) {
      _e2e.deriveSharedKey(peerPubKey, from).then((ok) {
        _log.i('E2E session avec $from : ${ok ? "✅ établie" : "❌ échec"}');
      });
    }

    // AUTO-CONSENT
    if (_autoConsent) {
      final accept = <String, dynamic>{
        'action': 'bridge_accept',
        'from':   _nodeId,
        'to':     from,
        'label':  _label,
      };
      if (_e2e.isReady) accept['pubKey'] = _e2e.publicKeyB64;
      _send(accept);
      _bridge = FriendPeer(uid: from, nickname: label, hosting: false, online: true);
      _info   = '$label connecté automatiquement ✓';
      _notif.notifyConnected(label, asHost: true);
      // Connect to Worker relay so guest's tunnel data reaches us
      _startHostRelayTunnel(from);
      notifyListeners();
      return;
    }

    _pendingAsk = FriendPeer(uid: from, nickname: label, hosting: false, online: true);
    _info       = '$label souhaite utiliser votre connexion';
    _notif.notifyConnectionRequest(label);
    notifyListeners();
  }

  void _handleBridgeAccept(Map<String, dynamic> data) async {
    if (_role != FriendRole.guest) return;

    // ─── E2E : dériver la clé partagée avec l'hôte ───
    final hostId     = data['from']   as String? ?? '';
    final peerPubKey = data['pubKey'] as String?;
    if (peerPubKey != null && E2EService.isValidPublicKey(peerPubKey) && _e2e.isReady && hostId.isNotEmpty) {
      _e2e.deriveSharedKey(peerPubKey, hostId).then((ok) {
        _log.i('E2E session avec hôte $hostId : ${ok ? "✅ établie" : "❌ échec"}');
      });
    }

    _info = 'Pont accepté — démarrage tunnel...';
    notifyListeners();

    // Vérifier si le VPN natif tourne déjà
    bool vpnRunning = false;
    try {
      vpnRunning = await _vpnChannel.invokeMethod('isRunning') == true;
    } catch (_) {}

    if (!vpnRunning && _bridge != null && _phase == MeshPhase.handshake) {
      // Relancer le VPN avec les paramètres du bridge actuel
      try {
        final ok = await _vpnChannel.invokeMethod('startVpn', {
          'nodeId':            _bridge!.uid,
          'userId':            _nodeId,
          'killSwitch':        false,
          'localProxy':        true,
          'proxyHost':         _bridge!.meshIp.isNotEmpty
              ? _bridge!.meshIp : _bridge!.uid,
          'proxyPort':         8899,
          'workerUrl':         'wss://friendlynet-mesh.bufferwave.workers.dev/tunnel',
          'tunnelKey':         '',
          'lowBandwidth':      _lowBandwidth,
          'keepaliveInterval': _lowBandwidth ? 45 : 15,
        });
        if (ok == true) {
          _phase = MeshPhase.live;
          _info = 'Internet via ${_bridge!.nickname} ✓';
          _startMetrics();
          notifyListeners();
        }
      } catch (e) {
        _info = 'Erreur tunnel: $e';
        _phase = MeshPhase.broken;
        notifyListeners();
      }
    } else if (vpnRunning) {
      _phase = MeshPhase.live;
      _info = 'Internet via ${_bridge!.nickname} ✓';
      notifyListeners();
    }
  }

  // ═══════════════════════════════════════════
  // HOST RELAY TUNNEL — Edge Relay Engine
  // ═══════════════════════════════════════════

  EdgeRelay? _hostRelay;

  /// Connects host to Worker relay using EdgeRelay from bufferwave_core.
  /// Receives guest's raw IP packets and forwards to native PacketProcessor.
  void _startHostRelayTunnel(String guestNodeId) {
    _hostRelay?.dispose();

    final workerBase = _bwApi.isInitialized
        ? _bwApi.workerBaseUrl
        : 'https://friendlynet-mesh.bufferwave.workers.dev';
    final wsBase = workerBase
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');

    // ✅ CORRIGÉ — user=HOST_NODEID & peer=GUEST_NODEID dans l'URL
    // Le Worker cherche la clé "HOST→GUEST" dans relayWaiting
    // TailscaleMode (guest) se connecte avec user=GUEST&peer=HOST
    // Le Worker trouve "HOST→GUEST" == partnerKey de "GUEST→HOST" ✅
    final tunnelUrl = '$wsBase/tunnel?user=$_nodeId&peer=$guestNodeId&mode=host';

    _hostRelay = EdgeRelay(
      endpoints: [tunnelUrl],
      localId: _nodeId,
      peerId: guestNodeId,
      queryParams: {},  // ✅ CORRIGÉ — vide, tout est déjà dans l'URL
    );

    _hostRelay!.onPaired = () {
      _log.i('Host relay ✅ paired avec guest $guestNodeId');
      _info = 'Relay actif — trafic en transit';
      notifyListeners();
    };

    _hostRelay!.onData = (Uint8List data) {
      if (data.isEmpty) return;
      // Paquets IP du guest → forwarder vers FriendlyNetRelayService
      _relayChannel.invokeMethod('processPacket', {
        'data': data.toList(),
      }).catchError((_) {});
      _sessionUpBytes += data.length;
    };

    _hostRelay!.onDisconnected = () {
      _log.w('Host relay déconnecté — tentative reconnexion');
      // ✅ CORRIGÉ — auto-reconnect si toujours host
      if (_role == FriendRole.host && _bridge != null) {
        Future.delayed(const Duration(seconds: 3), () {
          if (_role == FriendRole.host && _bridge != null) {
            _startHostRelayTunnel(guestNodeId);
          }
        });
      }
    };

    _hostRelay!.onError = (e) => _log.w('Host relay erreur: $e');

    // Listen for response packets from native relay → send back to guest
    _relayChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'responsePacket':
          final data = call.arguments['data'];
          if (data != null && _hostRelay != null) {
            final bytes = data is List<int>
                ? Uint8List.fromList(data)
                : Uint8List.fromList(List<int>.from(data));
            _hostRelay!.sendBinary(bytes);
            _sessionDownBytes += bytes.length;
          }
          break;
        case 'metricsUpdate':
          _sessionDownBytes = call.arguments['bytesIn'] as int? ?? 0;
          _sessionUpBytes = call.arguments['bytesOut'] as int? ?? 0;
          notifyListeners();
          break;
      }
    });

    _hostRelay!.connect().then((ok) {
      _log.i('Host relay connect: ${ok ? "OK ✅" : "ÉCHEC ❌"}');
      // ✅ CORRIGÉ — retry si connect échoue
      if (!ok) {
        Future.delayed(const Duration(seconds: 5), () {
          if (_role == FriendRole.host && _bridge != null) {
            _startHostRelayTunnel(guestNodeId);
          }
        });
      }
    });
  }

  // ═══════════════════════════════════════════
  // LOW BANDWIDTH — Heartbeat ultra-léger
  // ═══════════════════════════════════════════

  /// Envoie un heartbeat minimal.
  /// En mode normal : JSON complet (~120 bytes)
  /// En mode low bandwidth : JSON minimal (~48 bytes)
  void _sendHeartbeat() {
    if (!_meshActive) return;

    if (_lowBandwidth) {
      // Ultra-minimal : juste l'action et le node ID
      _send({'a': 'hb', 'n': _nodeId});
    } else {
      _send({
        'action': 'heartbeat',
        'node': _nodeId,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  /// Vérifie que la WebSocket est toujours vivante.
  /// Si aucune activité depuis 90 secondes, reconnecte.
  void _checkWsHealth() {
    if (!_meshActive) return;
    if (_lastWsActivity == null) return;

    final silence = DateTime.now().difference(_lastWsActivity!).inSeconds;
    final threshold = _lowBandwidth ? 120 : 90;

    if (silence > threshold) {
      _info = 'Connexion silencieuse — reconnexion...';
      notifyListeners();
      _reconnectMesh();
    }
  }

  /// Reconnecte silencieusement le WebSocket sans changer l'état UI.
  Future<void> _reconnectMesh() async {
    try {
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _meshActive = false;

    // Petite pause pour laisser le réseau se stabiliser
    await Future.delayed(const Duration(seconds: 2));

    final role = _role == FriendRole.host ? 'provider' : 'seeker';
    try {
      final mode = _lowBandwidth ? '&lowbw=1' : '';
      final uri = Uri.parse(
        '$_meshEndpoint?node=$_nodeId&name=${Uri.encodeComponent(_label)}&role=$role$mode',
      );
      _ws = WebSocketChannel.connect(uri);
      _ws!.stream.listen(
        (data) {
          _lastWsActivity = DateTime.now();
          _onSignal(data);
        },
        onError: (_) => _autoRejoin(),
        onDone: () => _autoRejoin(),
      );
      _meshActive = true;
      _lastWsActivity = DateTime.now();
      _send({'action': 'announce', 'node': _nodeId, 'name': _label, 'role': role});
    } catch (_) {
      // Réessayer dans 10 secondes
      Future.delayed(const Duration(seconds: 10), () {
        if (!_meshActive) _reconnectMesh();
      });
    }
  }

  // ═══════════════════════════════════════════
  // RECONNEXION AGGRESSIVE (survie Orange throttle)
  // ═══════════════════════════════════════════

  void _handleGuestDrop() {
    if (_recovering) return;
    _lastBridge ??= _bridge;

    if (_recoveryN >= _maxRecoveryAttempts) {
      _info = 'Connexion perdue après $_maxRecoveryAttempts tentatives';
      _cancelRecovery();
      leaveFriend();
      return;
    }

    _recovering = true;
    _phase = MeshPhase.recovering;
    _recoveryN++;

    // Backoff exponentiel plafonné à 60 sec (au lieu de 30)
    // Plus patient en mode throttlé
    final maxWait = _lowBandwidth ? 120 : 60;
    final wait = Duration(
      seconds: (2 * (1 << (_recoveryN - 1))).clamp(2, maxWait),
    );

    _info = 'Reconnexion $_recoveryN/$_maxRecoveryAttempts dans ${wait.inSeconds}s...';
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
      // D'abord essayer de reconnecter le mesh signaling
      if (!_meshActive) {
        await _reconnectMesh();
        // Attendre un peu que la connexion s'établisse
        await Future.delayed(const Duration(seconds: 3));
      }

      await _vpnChannel.invokeMethod('stopVpn');

      // Petite pause avant de réessayer
      await Future.delayed(const Duration(seconds: 1));

      final ok = await joinFriend(target);
      if (ok) {
        _recovering = false;
        _recoveryN = 0;
        _info = 'Reconnecté via ${target.nickname} ✓';
        notifyListeners();
      } else {
        _recovering = false;
        _handleGuestDrop();
      }
    } catch (_) {
      _recovering = false;
      _handleGuestDrop();
    }
  }

  void cancelReconnect() {
    _cancelRecovery();
    _recovering = false;
    _recoveryN = 0;
    leaveFriend();
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

  // ═══════════════════════════════════════════
  // BUFFERWAVE API HEARTBEAT
  // ═══════════════════════════════════════════

  void _startBwHeartbeat() {
    _bwHeartbeatTimer?.cancel();
    // Heartbeat API toutes les 5 min (indépendant du mesh WS)
    _bwHeartbeatTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _bwApi.heartbeat(_nodeId);
    });
  }

  void _send(Map<String, dynamic> msg) {
    try { _ws?.sink.add(jsonEncode(msg)); } catch (_) {}
  }

  void _autoRejoin() {
    final delay = _lowBandwidth ? 15 : 5;
    Future.delayed(Duration(seconds: delay), () {
      if (!_meshActive && _role != FriendRole.idle) {
        _reconnectMesh();
      }
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
      final raw   = prefs.getStringList(_prefPeers) ?? [];
      for (final str in raw) {
        final m    = jsonDecode(str) as Map<String, dynamic>;
        final peer = FriendPeer.unpack(m);
        if (!_friends.any((f) => f.uid == peer.uid)) {
          _friends.add(peer.refresh(online: false));
        }
      }
    } catch (_) {}
  }

  NetKind _parseNet(String raw) {
    switch (raw.toLowerCase()) {
      case '4g': case 'lte':  return NetKind.lte;
      case '5g': case 'nr':   return NetKind.fiveG;
      case 'wifi': case 'wlan': return NetKind.wifi;
      default:                  return NetKind.offline;
    }
  }

  String _makeNodeId() {
    final rng = Random.secure();
    return List.generate(8, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void dispose() {
    stopSearch();
    stopForegroundGuard();
    _wifiDirect.dispose();
    _metricsTick?.cancel();
    _recoveryTimer?.cancel();
    _wsHealthCheck?.cancel();
    // ─── Nettoyage nouveaux services ───
    _connMon.stop();
    _bwHeartbeatTimer?.cancel();
    _bwApi.deregisterNode(_nodeId);
    _e2e.clearAllSessions();
    super.dispose();
  }
}
