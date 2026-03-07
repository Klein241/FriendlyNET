import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service de notifications locales pour FriendlyNET.
/// Notifie l'utilisateur des événements réseau importants :
///  - Nouveau pair sur le mesh
///  - Demande de connexion entrante
///  - Connexion établie / perdue
///  - Mode éco-data activé automatiquement
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  // ─── Canaux de notification ───
  static const _meshChannel = AndroidNotificationChannel(
    'fn_mesh',
    'Réseau FriendlyNET',
    description: 'Événements du réseau mesh (nouveaux pairs, connexions)',
    importance: Importance.high,
  );

  static const _systemChannel = AndroidNotificationChannel(
    'fn_system',
    'Système FriendlyNET',
    description: 'Alertes système (éco-data, batterie)',
    importance: Importance.defaultImportance,
  );

  /// Initialise le service de notifications.
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        debugPrint('[FN-Notif] Tapped: ${response.payload}');
      },
    );

    // Créer les canaux Android
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      AndroidNotificationChannel(
        _meshChannel.id,
        _meshChannel.name,
        description: _meshChannel.description,
        importance: _meshChannel.importance,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      AndroidNotificationChannel(
        _systemChannel.id,
        _systemChannel.name,
        description: _systemChannel.description,
        importance: _systemChannel.importance,
      ),
    );

    _initialized = true;
    debugPrint('[FN-Notif] Service initialisé');
  }

  // ═══════════════════════════════════════════
  // NOTIFICATIONS MESH
  // ═══════════════════════════════════════════

  /// Un nouveau pair a rejoint le mesh.
  Future<void> notifyNewPeer(String peerName, {String? region}) async {
    await _show(
      id: 1001,
      channel: _meshChannel,
      title: '🟢 Nouveau pair FriendlyNET',
      body: '$peerName est en ligne${region != null ? ' ($region)' : ''}',
      payload: 'peer_joined',
    );
  }

  /// Demande de connexion entrante.
  Future<void> notifyConnectionRequest(String peerName) async {
    await _show(
      id: 1002,
      channel: _meshChannel,
      title: '🤝 Demande de connexion',
      body: '$peerName veut utiliser ton internet',
      payload: 'bridge_request',
    );
  }

  /// Connexion établie avec un pair.
  Future<void> notifyConnected(String peerName, {bool asHost = false}) async {
    await _show(
      id: 1003,
      channel: _meshChannel,
      title: asHost ? '✅ Partage actif' : '✅ Connecté',
      body: asHost
          ? '$peerName utilise ton internet'
          : 'Tu utilises l\'internet de $peerName',
      payload: 'connected',
    );
  }

  /// Connexion perdue.
  Future<void> notifyDisconnected(String peerName) async {
    await _show(
      id: 1004,
      channel: _meshChannel,
      title: '🔴 Connexion perdue',
      body: 'Déconnecté de $peerName — tentative de reconnexion...',
      payload: 'disconnected',
    );
  }

  /// Un pair a quitté le réseau.
  Future<void> notifyPeerLeft(String peerName) async {
    await _show(
      id: 1005,
      channel: _meshChannel,
      title: '👋 Pair déconnecté',
      body: '$peerName a quitté le réseau',
      payload: 'peer_left',
    );
  }

  // ═══════════════════════════════════════════
  // NOTIFICATIONS SYSTÈME
  // ═══════════════════════════════════════════

  /// Mode éco-data activé automatiquement.
  Future<void> notifyEcoMode(bool enabled) async {
    await _show(
      id: 2001,
      channel: _systemChannel,
      title: enabled ? '📡 Mode éco-data activé' : '📡 Mode normal restauré',
      body: enabled
          ? 'Débit faible détecté — heartbeat réduit pour économiser tes données'
          : 'Débit restauré — mode normal actif',
      payload: 'eco_mode',
    );
  }

  /// Reconnexion en cours.
  Future<void> notifyReconnecting(int attempt, int max) async {
    await _show(
      id: 2002,
      channel: _systemChannel,
      title: '🔄 Reconnexion en cours',
      body: 'Tentative $attempt/$max — le tunnel sera restauré',
      payload: 'reconnecting',
    );
  }

  // ═══════════════════════════════════════════
  // HELPER INTERNE
  // ═══════════════════════════════════════════

  Future<void> _show({
    required int id,
    required AndroidNotificationChannel channel,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) return;

    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          showWhen: true,
        ),
      ),
      payload: payload,
    );
  }

  /// Annule toutes les notifications.
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
