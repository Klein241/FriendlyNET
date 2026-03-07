import 'package:bufferwave_core/bufferwave_core.dart';
import 'package:logger/logger.dart';

/// ════════════════════════════════════════════════════════════════
/// BufferwaveApiService — Pont FriendlyNET ↔ bufferwave_core
///
/// Utilise les vraies API statiques de BufferWaveApi et DohResolver:
///   - BufferWaveApi.healthCheck()     → santé du Worker Cloudflare
///   - BufferWaveApi.registerNode()    → enregistrement mesh
///   - BufferWaveApi.heartbeat()       → keepalive API
///   - DohResolver.resolve()           → DNS-over-HTTPS (anti-blocage FAI)
///
/// Avantage "Orange 100 Mo" :
///   Le DoH résout les domaines via HTTPS (port 443) au lieu du DNS
///   standard (port 53, bloqué/espionné quand le forfait est épuisé).
/// ════════════════════════════════════════════════════════════════
class BufferwaveApiService {
  static final _log = Logger(
    printer: SimplePrinter(colors: false),
    level: Level.info,
  );

  static const _workerBase     = 'https://bufferwave-tunnel.sfrfrfr.workers.dev';
  static const _meshEndpointWs = 'wss://bufferwave-tunnel.sfrfrfr.workers.dev/mesh';

  bool _initialized    = false;
  bool _workerHealthy  = false;
  bool get isInitialized   => _initialized;
  bool get isWorkerOnline  => _workerHealthy;

  // DoH Resolver (singleton bufferwave_core)
  final _doh = DohResolver();

  // ═══════════════════════════════════════════
  // INITIALISATION
  // ═══════════════════════════════════════════

  Future<void> initialize(String nodeId) async {
    if (_initialized) return;

    // 1. Pointer le BufferWaveApi sur notre Worker
    BufferWaveApi.setBaseUrl(_workerBase);

    // 2. Activer DoH (résolution DNS via HTTPS — protège contre blocage FAI)
    _doh.setEndpoint('$_workerBase/resolve');
    _doh.enable();

    // 3. Vérifier la santé du Worker
    _workerHealthy = await BufferWaveApi.healthCheck();
    _log.i('Worker ${_workerHealthy ? "✅ en ligne" : "⚠️ hors ligne (mode dégradé)"}');

    // 4. Enregistrer le nœud si Worker disponible
    if (_workerHealthy) {
      try {
        await BufferWaveApi.registerNode(
          userId: nodeId,
          country: 'auto',
          bandwidthMbps: 5.0,
        );
        _log.i('Nœud $nodeId enregistré sur le mesh BufferWave');
      } catch (e) {
        _log.w('Enregistrement nœud échoué: $e');
      }
    }

    _initialized = true;
  }

  // ═══════════════════════════════════════════
  // DOH — DNS-OVER-HTTPS
  // ═══════════════════════════════════════════

  /// Résout un hostname via DoH (bypasse les blocages DNS du FAI).
  /// Utile avant d'ouvrir le WebSocket mesh : si DNS bloqué, utilise
  /// l'IP directe hardcodée comme fallback.
  Future<String?> resolveDoH(String hostname) async {
    try {
      final ips = await _doh.resolve(hostname);
      if (ips.isNotEmpty) {
        _log.d('DoH: $hostname → ${ips.first}');
        return ips.first;
      }
    } catch (e) {
      _log.w('DoH échec ($hostname): $e');
    }
    return null;
  }

  // ═══════════════════════════════════════════
  // HEARTBEAT API BUFFERWAVE
  // ═══════════════════════════════════════════

  /// Heartbeat vers l'API BufferWave (garde le nœud enregistré).
  Future<void> heartbeat(String nodeId) async {
    try {
      await BufferWaveApi.heartbeat(nodeId);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════
  // HEALTH CHECK
  // ═══════════════════════════════════════════

  Future<bool> checkHealth() async {
    _workerHealthy = await BufferWaveApi.healthCheck();
    _log.d('Health check: ${_workerHealthy ? "OK" : "FAIL"}');
    return _workerHealthy;
  }

  // ═══════════════════════════════════════════
  // DISCONNEXION
  // ═══════════════════════════════════════════

  Future<void> deregisterNode(String nodeId) async {
    try {
      await BufferWaveApi.disconnect(nodeId);
    } catch (_) {}
    _doh.dispose();
  }

  // ═══════════════════════════════════════════
  // MESH WSS URL
  // ═══════════════════════════════════════════

  String get meshWssUrl => _meshEndpointWs;
}
