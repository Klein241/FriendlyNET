import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/mesh_provider.dart';

/// Écran Paramètres FriendlyNET.
/// Contient les réglages critiques pour le scénario Orange 100 Mo.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _bg = Color(0xFF0D0D1A);
  static const _surface = Color(0xFF161630);
  static const _outline = Color(0xFF2D2D50);
  static const _purple = Color(0xFF6C63FF);
  static const _mint = Color(0xFF00E5A0);
  static const _orange = Color(0xFFFF9800);

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
                      icon: Icons.signal_cellular_alt,
                      color: const Color(0xFF2196F3),
                      title: 'Données illimitées en arrière-plan',
                      subtitle: 'Permet à FriendlyNET d\'utiliser la data\n'
                          'même en mode "Économie de données".',
                      onTap: () async {
                        await prov.requestUnrestrictedData();
                      },
                    ),
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
}
