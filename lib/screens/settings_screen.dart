import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/mesh_provider.dart';

/// Écran Paramètres FriendlyNET.
/// Contient les réglages critiques pour le scénario Orange 100 Mo.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _bg      = Color(0xFF0D0D1A);
  static const _surface = Color(0xFF161630);
  static const _outline = Color(0xFF2D2D50);
  static const _purple  = Color(0xFF6C63FF);
  static const _mint    = Color(0xFF00E5A0);
  static const _orange  = Color(0xFFFF9800);
  static const _red     = Color(0xFFFF5252);

  @override
  Widget build(BuildContext context) {
    return Consumer<MeshProvider>(
      builder: (ctx, prov, _) {
        return Scaffold(
          backgroundColor: _bg,
          appBar: AppBar(
            backgroundColor: _bg,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
            title: const Text('Paramètres',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // ─── Section : Statut réseau ───
              _sectionTitle('🌐 Statut réseau'),
              const SizedBox(height: 8),
              _card(child: _networkStatusSection(prov)),
              const SizedBox(height: 20),

              // ─── Section : Sécurité E2E ───
              _sectionTitle('🔐 Sécurité & Chiffrement'),
              const SizedBox(height: 8),
              _card(child: _e2eSection(context, prov)),
              const SizedBox(height: 20),

              // ─── Section : Mode Économie de Data ───
              _sectionTitle('📡 Mode Éco-Data'),
              const SizedBox(height: 8),
              _card(
                child: Column(
                  children: [
                    _toggle(
                      icon: Icons.data_saver_on,
                      color: _orange,
                      title: 'Mode basse consommation',
                      subtitle: 'Réduit la data utilisée par FriendlyNET.\n'
                          'Heartbeat toutes les 45s au lieu de 15s.\n'
                          'Idéal quand ton forfait Orange est presque fini.',
                      value: prov.lowBandwidth,
                      onChanged: (v) => prov.setLowBandwidth(v),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ─── Section : Auto-Consentement ───
              _sectionTitle('🤝 Partage automatique'),
              const SizedBox(height: 8),
              _card(
                child: Column(
                  children: [
                    _toggle(
                      icon: Icons.verified_user,
                      color: _mint,
                      title: 'Accepter automatiquement',
                      subtitle: 'Quand tu partages ton internet, les amis\n'
                          'peuvent se connecter sans ton approbation.\n'
                          'Tu peux les déconnecter à tout moment.',
                      value: prov.autoConsent,
                      onChanged: (v) => prov.setAutoConsent(v),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ─── Section : Protection Android ───
              _sectionTitle('🛡 Protection Android'),
              const SizedBox(height: 8),
              _card(
                child: Column(
                  children: [
                    _actionTile(
                      icon: Icons.battery_charging_full,
                      color: const Color(0xFF4CAF50),
                      title: 'Désactiver l\'optimisation batterie',
                      subtitle: 'Empêche Android de tuer FriendlyNET\n'
                          'quand ton écran est éteint.',
                      onTap: () async {
                        final ok = await prov.requestBatteryExemption();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(ok
                                ? 'Optimisation batterie désactivée ✓'
                                : 'Autorise FriendlyNET dans les paramètres'),
                            backgroundColor: ok ? _mint : _orange,
                          ));
                        }
                      },
                    ),
                    Divider(color: _outline, height: 1),
                    _actionTile(
                      icon: Icons.battery_alert,
                      color: const Color(0xFFFFEB3B),
                      title: 'Paramètres batterie (direct)',
                      subtitle: 'Ouvre directement les réglages batterie\n'
                          'pour désactiver les restrictions en arrière-plan.',
                      onTap: () => prov.openBatterySettings(),
                    ),
                    Divider(color: _outline, height: 1),
                    _actionTile(
                      icon: Icons.signal_cellular_alt,
                      color: const Color(0xFF2196F3),
                      title: 'Données non restreintes',
                      subtitle: 'Zéro restriction data en arrière-plan.\n'
                          'Critique quand Orange active le mode Économie.',
                      onTap: () => prov.openDataSaverSettings(),
                    ),
                    Divider(color: _outline, height: 1),
                    _actionTile(
                      icon: Icons.signal_cellular_connected_no_internet_4_bar,
                      color: const Color(0xFF9C27B0),
                      title: 'Données illimitées (page app)',
                      subtitle: 'Permet à FriendlyNET d\'utiliser la data\n'
                          'même en mode "Economie de données".',
                      onTap: () async {
                        await prov.requestUnrestrictedData();
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ─── Section : WiFi Direct ───
              _sectionTitle('📶 WiFi Direct — Zéro data'),
              const SizedBox(height: 8),
              _card(
                child: Column(
                  children: [
                    _toggle(
                      icon: Icons.wifi_find,
                      color: const Color(0xFF00BCD4),
                      title: 'Découverte WiFi Direct',
                      subtitle: 'Trouve des amis FriendlyNET proches\n'
                          'sans aucune data mobile (0 Mo).\n'
                          'Fonctionne même forfait épuisé !',
                      value: prov.wifiDirectActive,
                      onChanged: (v) async {
                        if (v) {
                          await prov.startWifiDirect();
                        } else {
                          await prov.stopWifiDirect();
                        }
                      },
                    ),
                    if (prov.wifiPeers.isNotEmpty) ...[
                      Divider(color: _outline, height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${prov.wifiPeers.length} pair(s) WiFi Direct trouvé(s)',
                              style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            ...prov.wifiPeers.map((p) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Container(
                                    width: 32, height: 32,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF00BCD4).withAlpha(30),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: const Color(0xFF00BCD4).withAlpha(80)),
                                    ),
                                    child: Center(child: Text(p.letter,
                                      style: const TextStyle(color: Color(0xFF00BCD4),
                                          fontWeight: FontWeight.w700))),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(p.name, style: const TextStyle(color: Colors.white,
                                          fontSize: 13, fontWeight: FontWeight.w600)),
                                      Text(p.statusLabel, style: TextStyle(
                                          color: Colors.white.withAlpha(100), fontSize: 10)),
                                    ],
                                  )),
                                  if (p.isAvailable)
                                    GestureDetector(
                                      onTap: () => prov.connectWifiDirect(p.mac),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00BCD4).withAlpha(25),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: const Color(0xFF00BCD4).withAlpha(80)),
                                        ),
                                        child: const Text('Connecter',
                                          style: TextStyle(color: Color(0xFF00BCD4),
                                              fontSize: 11, fontWeight: FontWeight.w700)),
                                      ),
                                    ),
                                ],
                              ),
                            )),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ─── Section : Info ───
              _sectionTitle('ℹ️ Info technique'),
              const SizedBox(height: 8),
              _card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _infoRow('Node ID', prov.nodeId),
                      const SizedBox(height: 8),
                      _infoRow('Nom', prov.displayName),
                      const SizedBox(height: 8),
                      _infoRow('Mode', prov.lowBandwidth ? 'Éco-Data' : 'Normal'),
                      const SizedBox(height: 8),
                      _infoRow('Auto-accept', prov.autoConsent ? 'Oui' : 'Non'),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _purple.withAlpha(10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _purple.withAlpha(30)),
                        ),
                        child: Text(
                          '💡 Scénario Orange 100 Mo :\n'
                          '1. Active tes données (100 Mo)\n'
                          '2. FriendlyNET établit le tunnel (~5 Mo)\n'
                          '3. Tout passe par l\'ami → forfait non débité\n'
                          '4. Quand Orange coupe, le tunnel survit\n'
                          '   grâce au mode éco-data + foreground service',
                          style: TextStyle(
                            color: Colors.white.withAlpha(140),
                            fontSize: 11,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ─── Version ───
              Center(
                child: Text(
                  'FriendlyNET v1.0.0\nPowered by BufferWave Core',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withAlpha(40), fontSize: 10),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String text) {
    return Text(text,
      style: TextStyle(
        color: Colors.white.withAlpha(180),
        fontSize: 14,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _outline),
      ),
      child: child,
    );
  }

  Widget _toggle({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: color.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(subtitle,
                  style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 11, height: 1.4)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: color,
            activeTrackColor: color.withAlpha(60),
          ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                    style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 11, height: 1.4)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.white.withAlpha(50), size: 22),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String key, String val) {
    return Row(
      children: [
        Text('$key : ',
          style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 12)),
        Expanded(child: Text(val,
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
          textAlign: TextAlign.end)),
      ],
    );
  }

  // ═══════════════════════════════════════════
  // NOUVELLES SECTIONS
  // ═══════════════════════════════════════════

  /// Section : statut Worker Cloudflare + type de connexion détecté
  Widget _networkStatusSection(MeshProvider prov) {
    final online  = prov.workerOnline;
    final bwMode  = prov.lowBandwidth;
    final workerColor = online ? _mint : _red;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Statut Worker
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: workerColor.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  online ? Icons.cloud_done : Icons.cloud_off,
                  color: workerColor, size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      online ? 'Worker Cloudflare en ligne' : 'Worker hors ligne',
                      style: TextStyle(
                        color: workerColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      online
                        ? 'bufferwave-tunnel.sfrfrfr.workers.dev'
                        : 'Mode dégradé — WiFi Direct uniquement',
                      style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 10),
                    ),
                  ],
                ),
              ),
              // Badge live
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: workerColor.withAlpha(20),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        color: workerColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(online ? 'LIVE' : 'OFF',
                      style: TextStyle(color: workerColor, fontSize: 9, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(color: _outline, height: 1),
          const SizedBox(height: 14),
          // Mode bande passante auto-détecté
          Row(
            children: [
              Icon(
                bwMode ? Icons.speed : Icons.network_check,
                color: bwMode ? _orange : _mint,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bwMode
                    ? 'Débit lent détecté — Mode éco actif (auto)'
                    : 'Débit normal — Mode standard actif',
                  style: TextStyle(
                    color: Colors.white.withAlpha(160),
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Le moniteur vérifie la latence toutes les 60s.\nSi RTT > 600ms ou perte > 40%, bascule auto en mode éco.',
            style: TextStyle(color: Colors.white.withAlpha(70), fontSize: 10, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// Section : fingerprint E2E + bouton copier + explication
  Widget _e2eSection(BuildContext context, MeshProvider prov) {
    final fp    = prov.e2eFingerprint;
    final ready = prov.e2eReady;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: _purple.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.lock, color: _purple, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ready ? 'Chiffrement X25519 + AES-256-GCM' : 'Initialisation...',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'Protection anti-MITM entre pairs',
                      style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 10),
                    ),
                  ],
                ),
              ),
              if (ready)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: _mint.withAlpha(20),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('E2E ON',
                    style: TextStyle(color: _mint, fontSize: 9, fontWeight: FontWeight.w800)),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Fingerprint
          if (ready) ...[
            Text('Ton fingerprint (8 hex)', style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 11)),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: fp));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Fingerprint copié !'),
                    backgroundColor: _purple,
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: _purple.withAlpha(15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _purple.withAlpha(60)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      fp.isNotEmpty ? fp.replaceAllMapped(RegExp(r'.{2}'), (m) => '${m.group(0)} ').trim() : '????????',
                      style: TextStyle(
                        color: _purple,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Icon(Icons.copy, color: _purple.withAlpha(120), size: 16),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _mint.withAlpha(8),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _mint.withAlpha(30)),
              ),
              child: Row(
                children: [
                  const Text('💡', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Compare ces 8 caractères avec ton ami.\n'
                      'S\'ils correspondent → connexion sécurisée.',
                      style: TextStyle(color: _mint.withAlpha(200), fontSize: 10, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const Center(
              child: SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
