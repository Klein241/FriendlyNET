import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:logger/logger.dart';

/// ════════════════════════════════════════════════════════════════
/// ConnectivityMonitor — FriendlyNET
///
/// Détecte automatiquement les conditions réseau dégradées :
///   - Orange forfait épuisé → throttling 32-64 Kbps
///   - Mode Économie de données Android activé
///   - Connexion 2G / Edge
///
/// Réaction :
///   onLowBandwidth(true)  → active le mode éco dans MeshProvider
///   onLowBandwidth(false) → réactive le mode normal
///
/// Algorithme de détection :
///   1. connectivity_plus détecte le type réseau (mobile/wifi)
///   2. Si mobile → ping vers 1.1.1.1 sur 5 requêtes
///   3. Si RTT moyen > 600ms OU perte > 40% → low bandwidth
///   4. Réévaluation toutes les 60s (mode normal) / 30s (mode éco)
/// ════════════════════════════════════════════════════════════════
class ConnectivityMonitor {
  static final _log = Logger(
    printer: SimplePrinter(colors: false),
    level: Level.info,
  );

  // ─── Callbacks ───
  void Function(bool isLow)? onLowBandwidth;
  void Function(ConnectivityResult type)? onTypeChanged;
  void Function(String message)? onStatusMessage;

  // ─── État ───
  bool _isLow = false;
  bool _running = false;
  ConnectivityResult _lastType = ConnectivityResult.none;

  Timer? _checkTimer;
  StreamSubscription? _connectivitySub;

  bool get isLowBandwidth => _isLow;
  ConnectivityResult get connectionType => _lastType;

  // Seuils de détection
  static const int _pingTimeoutMs    = 3000;  // Timeout ping individuel
  static const int _highLatencyMs    = 600;   // RTT moyen → low bandwidth
  static const double _highLossRatio = 0.4;   // 40% perte → low bandwidth
  static const int _pingCount        = 5;     // Nombre de pings de mesure

  // ═══════════════════════════════════════════
  // DÉMARRAGE
  // ═══════════════════════════════════════════

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _log.i('ConnectivityMonitor démarré');

    // Abonnement aux changements de connectivité
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      (result) {
        // connectivity_plus v5 returns a single ConnectivityResult
        final type = result is List
            ? (result as List).isNotEmpty
                ? (result as List).first as ConnectivityResult
                : ConnectivityResult.none
            : result as ConnectivityResult;
        _onTypeChanged(type);
      },
    );

    // Vérification initiale
    final initial = await Connectivity().checkConnectivity();
    // Handle both List and single result (API varies by version)
    final ConnectivityResult initResult;
    if (initial is List) {
      initResult = (initial as List).isNotEmpty
          ? (initial as List).first as ConnectivityResult
          : ConnectivityResult.none;
    } else {
      initResult = initial as ConnectivityResult;
    }
    _onTypeChanged(initResult);

    // Vérification périodique
    _scheduleCheck();
  }

  void stop() {
    _running = false;
    _checkTimer?.cancel();
    _connectivitySub?.cancel();
    _log.i('ConnectivityMonitor arrêté');
  }

  // ═══════════════════════════════════════════
  // DÉTECTION DU TYPE DE CONNEXION
  // ═══════════════════════════════════════════

  void _onTypeChanged(ConnectivityResult result) {
    if (result == _lastType) return;
    _lastType = result;
    onTypeChanged?.call(result);

    _log.i('Réseau : ${_typeName(result)}');

    // Sur mobile → probabilité de throttle ↑ → vérifier plus vite
    if (result == ConnectivityResult.mobile) {
      onStatusMessage?.call('Réseau mobile — vérification bande passante...');
      _doSpeedCheck();
    } else if (result == ConnectivityResult.wifi) {
      // WiFi → supposer bon débit sauf si ping dit autrement
      _setLowBandwidth(false, 'WiFi détecté');
    } else if (result == ConnectivityResult.none) {
      _setLowBandwidth(true, 'Aucune connexion');
    }
  }

  // ═══════════════════════════════════════════
  // MESURE DE LATENCE (estimation de bande passante)
  // ═══════════════════════════════════════════

  Future<void> _doSpeedCheck() async {
    if (!_running) return;
    _log.d('Début mesure latence réseau...');

    int success = 0;
    int totalMs = 0;

    for (int i = 0; i < _pingCount; i++) {
      final ms = await _pingOnce('1.1.1.1');
      if (ms >= 0) {
        success++;
        totalMs += ms;
      }
      // Petite pause entre pings
      await Future.delayed(const Duration(milliseconds: 200));
    }

    final lossRatio  = 1.0 - (success / _pingCount);
    final avgRtt     = success > 0 ? (totalMs / success).round() : 9999;

    _log.i('Ping résultat: avg=${avgRtt}ms, perte=${(lossRatio * 100).round()}%');
    onStatusMessage?.call('RTT: ${avgRtt}ms · Perte: ${(lossRatio * 100).round()}%');

    final isLow = avgRtt > _highLatencyMs || lossRatio >= _highLossRatio;

    if (isLow) {
      _setLowBandwidth(true,
          'Orange throttle détecté (${avgRtt}ms, ${(lossRatio * 100).round()}% perte)');
    } else {
      _setLowBandwidth(false,
          'Débit normal (${avgRtt}ms)');
    }
  }

  /// Ping TCP vers l'hôte sur port 443 (passe les firewalls).
  /// Retourne le RTT en ms, ou -1 si timeout.
  Future<int> _pingOnce(String host) async {
    final start = DateTime.now().millisecondsSinceEpoch;
    try {
      final socket = await Socket.connect(
        host, 443,
        timeout: const Duration(milliseconds: _pingTimeoutMs),
      );
      socket.destroy();
      return DateTime.now().millisecondsSinceEpoch - start;
    } catch (_) {
      return -1; // timeout ou refusé
    }
  }

  // ═══════════════════════════════════════════
  // CHANGEMENT D'ÉTAT
  // ═══════════════════════════════════════════

  void _setLowBandwidth(bool isLow, String reason) {
    if (_isLow == isLow) return;
    _isLow = isLow;
    _log.i('${isLow ? "⚠️ LOW BANDWIDTH" : "✅ NORMAL"} — $reason');
    onLowBandwidth?.call(isLow);
  }

  // ═══════════════════════════════════════════
  // VÉRIFICATION PÉRIODIQUE
  // ═══════════════════════════════════════════

  void _scheduleCheck() {
    _checkTimer?.cancel();
    // Vérification toutes les 60s (normal) ou 30s (low bandwidth)
    final interval = _isLow ? 30 : 60;
    _checkTimer = Timer(Duration(seconds: interval), () async {
      if (!_running) return;
      if (_lastType == ConnectivityResult.mobile) {
        await _doSpeedCheck();
      }
      _scheduleCheck(); // re-planifier
    });
  }

  // ═══════════════════════════════════════════
  // UTILITAIRES
  // ═══════════════════════════════════════════

  String _typeName(ConnectivityResult r) {
    switch (r) {
      case ConnectivityResult.wifi:     return 'WiFi';
      case ConnectivityResult.mobile:   return 'Mobile';
      case ConnectivityResult.ethernet: return 'Ethernet';
      case ConnectivityResult.bluetooth:return 'Bluetooth';
      case ConnectivityResult.none:     return 'Aucun';
      default:                          return 'Inconnu';
    }
  }

  /// Retourne un résumé lisible de l'état actuel.
  String get statusSummary {
    final type = _typeName(_lastType);
    final bw   = _isLow ? '⚠️ Éco-data' : '✅ Normal';
    return '$type · $bw';
  }
}
