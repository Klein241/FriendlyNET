import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

/// ════════════════════════════════════════════════════════════════
/// BufferwaveApiService — Version autonome sans bufferwave_core
///
/// ✅ CORRIGÉ — Plus de dépendance à bufferwave_core.
/// Utilise http natif pour communiquer avec le Worker Cloudflare.
///
/// Fonctionnalités conservées :
///   - Health check du Worker
///   - Heartbeat keepalive
///   - Enregistrement/désenregistrement nœud
///
/// Fonctionnalités retirées :
///   - DoH (DNS-over-HTTPS) → pas utilisé en pratique,
///     le mesh se connecte directement au domaine Workers
/// ════════════════════════════════════════════════════════════════
class BufferwaveApiService {
  static final _log = Logger(
    printer: SimplePrinter(colors: false),
    level: Level.info,
  );

  static const _workerBase     = 'https://friendlynet-mesh.bufferwave.workers.dev';
  static const _meshEndpointWs = 'wss://friendlynet-mesh.bufferwave.workers.dev/mesh';

  bool _initialized    = false;
  bool _workerHealthy  = false;
  bool get isInitialized   => _initialized;
  bool get isWorkerOnline  => _workerHealthy;

  // ═══════════════════════════════════════════
  // INITIALISATION
  // ═══════════════════════════════════════════

  Future<void> initialize(String nodeId) async {
    if (_initialized) return;

    // 1. Vérifier la santé du Worker
    _workerHealthy = await checkHealth();
    _log.i('Worker ${_workerHealthy ? "✅ en ligne" : "⚠️ hors ligne (mode dégradé)"}');

    _initialized = true;
  }

  // ═══════════════════════════════════════════
  // HEALTH CHECK
  // ═══════════════════════════════════════════

  Future<bool> checkHealth() async {
    try {
      final resp = await http
          .get(Uri.parse('$_workerBase/health'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _workerHealthy = data['ok'] == true;
        _log.d('Health check: ${_workerHealthy ? "OK" : "FAIL"}');
        return _workerHealthy;
      }
    } catch (e) {
      _log.w('Health check échec: $e');
    }
    _workerHealthy = false;
    return false;
  }

  // ═══════════════════════════════════════════
  // HEARTBEAT
  // ═══════════════════════════════════════════

  /// Heartbeat léger — garde la présence du nœud sur le Worker.
  Future<void> heartbeat(String nodeId) async {
    try {
      await http
          .post(
            Uri.parse('$_workerBase/mesh/heartbeat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'nodeId': nodeId}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Silencieux — un heartbeat raté n'est pas critique
    }
  }

  // ═══════════════════════════════════════════
  // DÉSENREGISTREMENT
  // ═══════════════════════════════════════════

  Future<void> deregisterNode(String nodeId) async {
    try {
      await http
          .post(
            Uri.parse('$_workerBase/mesh/disconnect'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'nodeId': nodeId}),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  // ═══════════════════════════════════════════
  // URLS
  // ═══════════════════════════════════════════

  String get meshWssUrl    => _meshEndpointWs;
  String get workerBaseUrl => _workerBase;
}
