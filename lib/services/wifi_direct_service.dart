import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

/// ════════════════════════════════════════════════════════════════
/// WifiDirectService — FriendlyNET
///
/// WiFi Direct réel via LocalOnlyHotspot + BLE discovery.
///
/// Flux Hôte :
///   1. initialize() → prépare les ressources P2P + BLE
///   2. startHosting() → crée un hotspot local + advertise BLE
///   3. Les invités scannent via BLE, reçoivent SSID+PSK
///   4. Invité connecte au hotspot sans PIN ni data
///   5. Communication directe via IP locale (192.168.x.x)
///
/// Flux Invité :
///   1. initialize() → prépare les ressources P2P + BLE
///   2. startScanning() → scan BLE pour trouver les hôtes
///   3. connectToHost(device) → BLE auto-read SSID+PSK → WiFi connect
///   4. Communication directe via IP locale
///
/// Avantages :
///   - 0 Mo de data mobile
///   - Latence ~5ms (direct device-to-device)
///   - Fonctionne même sans forfait
///   - BLE = découverte à faible énergie
///   - LocalOnlyHotspot = pas besoin de tethering
/// ════════════════════════════════════════════════════════════════
class WifiDirectService {
  FlutterP2pHost? _host;
  FlutterP2pClient? _client;

  bool _initialized = false;
  bool _hosting = false;
  bool _scanning = false;

  // ─── État ───
  HotspotHostState? _hotspotState;
  HotspotClientState? _clientState;
  List<BleDiscoveredDevice> _discoveredDevices = [];
  String _hostGatewayIp = '';

  // ─── Subscriptions ───
  StreamSubscription? _hotspotSub;
  StreamSubscription<List<BleDiscoveredDevice>>? _scanSub;

  // ─── Callbacks ───
  void Function(List<BleDiscoveredDevice> devices)? onDevicesFound;
  void Function(String hostIp)? onConnectedToHost;
  void Function(HotspotHostState state)? onHotspotReady;
  void Function(List<P2pClientInfo> clients)? onClientsChanged;
  void Function()? onDisconnected;
  void Function(String msg)? onError;
  void Function(String msg)? onLog;

  // ─── Getters ───
  bool get isInitialized => _initialized;
  bool get isHosting => _hosting;
  bool get isScanning => _scanning;
  bool get isConnectedToHost => _clientState?.isActive ?? false;
  String get hostGatewayIp => _hostGatewayIp;
  HotspotHostState? get hotspotState => _hotspotState;
  HotspotClientState? get clientState => _clientState;
  List<BleDiscoveredDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);
  List<P2pClientInfo> get connectedClients => _host?.clientList ?? [];

  // ═══════════════════════════════════════════
  // INITIALIZE
  // ═══════════════════════════════════════════

  /// Initialise les ressources P2P et BLE.
  /// Doit être appelé avant toute autre opération.
  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      _host = FlutterP2pHost();
      _client = FlutterP2pClient();
      await _host!.initialize();
      _initialized = true;
      _log('P2P initialisé');
      return true;
    } catch (e) {
      _logError('Initialisation P2P échouée: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════
  // PERMISSIONS
  // ═══════════════════════════════════════════

  /// Vérifie et demande les permissions WiFi Direct + BLE.
  Future<bool> ensurePermissions() async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return false;
    }
    try {
      // P2P permissions (location, wifi)
      final hasP2p = await _host!.checkP2pPermissions();
      if (!hasP2p) {
        final granted = await _host!.askP2pPermissions();
        if (!granted) {
          _logError('Permissions P2P refusées');
          return false;
        }
      }

      // BLE permissions
      final hasBle = await _host!.checkBluetoothPermissions();
      if (!hasBle) {
        final granted = await _host!.askBluetoothPermissions();
        if (!granted) {
          _logError('Permissions Bluetooth refusées');
          return false;
        }
      }

      // Location enabled
      final locEnabled = await _host!.checkLocationEnabled();
      if (!locEnabled) {
        await _host!.enableLocationServices();
      }

      // WiFi enabled
      final wifiEnabled = await _host!.checkWifiEnabled();
      if (!wifiEnabled) {
        await _host!.enableWifiServices();
      }

      // Bluetooth enabled
      final btEnabled = await _host!.checkBluetoothEnabled();
      if (!btEnabled) {
        await _host!.enableBluetoothServices();
      }

      return true;
    } catch (e) {
      _logError('Vérification permissions: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════
  // MODE HÔTE — Hotspot + BLE advertising
  // ═══════════════════════════════════════════

  /// Crée un hotspot local et diffuse les identifiants via BLE.
  ///
  /// Les invités qui scannent via BLE verront notre appareil et pourront
  /// récupérer le SSID + mot de passe automatiquement.
  ///
  /// [advertiseBle] — si true, diffuse SSID/PSK via BLE GATT
  /// [timeout] — durée max d'attente pour l'initialisation du hotspot
  Future<HotspotHostState?> startHosting({
    bool advertiseBle = true,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return null;
    }
    if (_hosting) {
      _log('Déjà en mode hôte');
      return _hotspotState;
    }

    try {
      _log('Création du hotspot...');
      final state = await _host!.createGroup(
        advertise: advertiseBle,
        timeout: timeout,
      );
      _hotspotState = state;
      _hosting = true;

      // Écouter les changements d'état du hotspot
      _hotspotSub = _host!.streamHotspotState().listen(
        (s) {
          _hotspotState = s;
          if (s.isActive) {
            _log('Hotspot actif: SSID=${s.ssid}, IP=${s.hostIpAddress}');
            onHotspotReady?.call(s);
          }
        },
        onError: (e) => _logError('Stream hotspot: $e'),
      );

      _log('Hotspot créé: SSID=${state.ssid}, IP=${state.hostIpAddress}');
      onHotspotReady?.call(state);
      return state;
    } catch (e) {
      _logError('Création hotspot échouée: $e');
      _hosting = false;
      return null;
    }
  }

  /// Arrête le hotspot et le BLE advertising.
  Future<void> stopHosting() async {
    if (!_hosting) return;
    _hotspotSub?.cancel();
    _hotspotSub = null;
    try {
      await _host?.removeGroup();
    } catch (e) {
      _logError('Arrêt hotspot: $e');
    }
    _hosting = false;
    _hotspotState = null;
    _log('Hotspot arrêté');
  }

  /// Envoie un message texte à tous les clients connectés.
  Future<void> broadcastToClients(String text) async {
    try {
      await _host?.broadcastText(text);
    } catch (e) {
      _logError('Broadcast échoué: $e');
    }
  }

  /// Envoie un message à un client spécifique.
  Future<bool> sendToClient(String text, String clientId) async {
    try {
      return await _host?.sendTextToClient(text, clientId) ?? false;
    } catch (e) {
      _logError('Envoi au client échoué: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════
  // MODE INVITÉ — BLE scan + WiFi connect
  // ═══════════════════════════════════════════

  /// Démarre le scan BLE pour trouver les hôtes FriendlyNET.
  ///
  /// Les appareils trouvés sont disponibles via [onDevicesFound].
  /// [scanTimeout] — durée du scan avant arrêt automatique (défaut: 30s)
  Future<bool> startScanning({
    Duration scanTimeout = const Duration(seconds: 30),
  }) async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return false;
    }
    if (_scanning) {
      _log('Scan déjà actif');
      return true;
    }

    try {
      _discoveredDevices = [];
      _scanSub = await _client!.startScan(
        (devices) {
          _discoveredDevices = devices;
          _log('BLE: ${devices.length} appareil(s) trouvé(s)');
          onDevicesFound?.call(devices);
        },
        onError: (e) {
          _logError('BLE scan error: $e');
        },
        onDone: () {
          _scanning = false;
          _log('Scan BLE terminé');
        },
        timeout: scanTimeout,
      );
      _scanning = true;
      _log('Scan BLE démarré (timeout: ${scanTimeout.inSeconds}s)');
      return true;
    } catch (e) {
      _logError('Démarrage scan BLE: $e');
      _scanning = false;
      return false;
    }
  }

  /// Arrête le scan BLE.
  Future<void> stopScanning() async {
    if (!_scanning) return;
    _scanSub?.cancel();
    _scanSub = null;
    try {
      await _client?.stopScan();
    } catch (_) {}
    _scanning = false;
    _discoveredDevices = [];
    _log('Scan BLE arrêté');
  }

  /// Se connecte à un hôte découvert via BLE.
  ///
  /// Flux automatique :
  ///   1. Connecte au BLE GATT de l'hôte
  ///   2. Lit les caractéristiques SSID + PSK
  ///   3. Déconnecte du BLE
  ///   4. Connecte au hotspot WiFi avec les identifiants reçus
  ///   5. Initialise le transport P2P TCP
  ///
  /// [device] — appareil BLE découvert via le scan
  /// [bleTimeout] — durée max pour l'échange BLE (défaut: 20s)
  Future<bool> connectToHost(
    BleDiscoveredDevice device, {
    Duration bleTimeout = const Duration(seconds: 20),
  }) async {
    if (!_initialized) return false;

    try {
      _log('Connexion → ${device.deviceName} (${device.deviceAddress})...');

      // Arrêter le scan si en cours
      await stopScanning();

      // ConnectWithDevice fait tout : BLE → read creds → WiFi → transport
      await _client!.connectWithDevice(device, timeout: bleTimeout);

      // Mettre à jour l'état local
      _hostGatewayIp = _client!.isConnected ? '(connected)' : '';
      _log('Connecté à l\'hôte via WiFi Direct');
      onConnectedToHost?.call(_hostGatewayIp);
      return true;
    } catch (e) {
      _logError('Connexion à l\'hôte échouée: $e');
      return false;
    }
  }

  /// Se connecte directement au hotspot si on connaît déjà SSID+PSK.
  ///
  /// Utile quand les identifiants sont échangés via le mesh signaling
  /// (relais WebSocket) plutôt que via BLE.
  Future<bool> connectWithCredentials(String ssid, String psk) async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return false;
    }

    try {
      _log('Connexion au hotspot: $ssid...');
      await _client!.connectWithCredentials(ssid, psk);

      _hostGatewayIp = _client!.isConnected ? '(connected)' : '';
      _log('Connecté au hotspot $ssid');
      onConnectedToHost?.call(_hostGatewayIp);
      return true;
    } catch (e) {
      _logError('Connexion hotspot échouée: $e');
      return false;
    }
  }

  /// Se déconnecte du hotspot.
  Future<void> disconnectFromHost() async {
    try {
      await _client?.disconnect();
    } catch (_) {}
    _clientState = null;
    _hostGatewayIp = '';
    _log('Déconnecté du hotspot');
    onDisconnected?.call();
  }

  /// Envoie un message texte à l'hôte et aux autres clients.
  Future<void> sendText(String text) async {
    try {
      await _client?.broadcastText(text);
    } catch (e) {
      _logError('Envoi texte échoué: $e');
    }
  }

  // ═══════════════════════════════════════════
  // STREAMS — Messages entrants
  // ═══════════════════════════════════════════

  /// Stream de textes reçus (en tant qu'hôte).
  Stream<String>? get hostReceivedTexts => _host?.streamReceivedTexts();

  /// Stream de textes reçus (en tant qu'invité).
  Stream<String>? get clientReceivedTexts => _client?.streamReceivedTexts();

  // ═══════════════════════════════════════════
  // DISPOSE
  // ═══════════════════════════════════════════

  Future<void> dispose() async {
    _log('Dispose WifiDirectService');
    await stopHosting();
    await stopScanning();
    await disconnectFromHost();
    try {
      await _host?.dispose();
      await _client?.dispose();
    } catch (_) {}
    _host = null;
    _client = null;
    _initialized = false;
    _discoveredDevices = [];
  }

  // ═══════════════════════════════════════════
  // LOGGING
  // ═══════════════════════════════════════════

  void _log(String msg) {
    debugPrint('[WifiDirect] $msg');
    onLog?.call(msg);
  }

  void _logError(String msg) {
    debugPrint('[WifiDirect] ❌ $msg');
    onError?.call(msg);
  }
}
