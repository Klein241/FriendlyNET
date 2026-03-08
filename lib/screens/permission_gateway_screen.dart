import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/mesh_provider.dart';

/// Écran unique de permissions affiché au premier lancement.
/// Un seul checkbox + bouton → toutes les permissions en séquence.
///
/// Clé SharedPreferences : 'fn_permissions_granted'
/// Ne s'affiche qu'une fois — si la clé est true, skip direct.
class PermissionGatewayScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const PermissionGatewayScreen({super.key, required this.onComplete});

  @override
  State<PermissionGatewayScreen> createState() => _PermissionGatewayScreenState();
}

class _PermissionGatewayScreenState extends State<PermissionGatewayScreen>
    with SingleTickerProviderStateMixin {

  static const _bg     = Color(0xFF0D0D1A);
  static const _purple = Color(0xFF6C63FF);
  static const _mint   = Color(0xFF00E5A0);

  static const _vpnChannel = MethodChannel('friendlynet/vpn');

  bool _accepted    = false;
  bool _processing  = false;
  double _progress  = 0.0;
  String _stepLabel = '';
  String? _error;

  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _grantAll() async {
    setState(() {
      _processing = true;
      _progress = 0.0;
      _error = null;
    });

    final steps = <_PermStep>[
      _PermStep('Permissions WiFi & localisation...', () async {
        await [
          Permission.locationWhenInUse,
          Permission.nearbyWifiDevices,
        ].request();
      }),
      _PermStep('Permission notifications...', () async {
        await Permission.notification.request();
      }),
      _PermStep('Tunnel VPN sécurisé...', () async {
        // Celui-ci déclenche le dialog Android obligatoire
        try {
          await _vpnChannel.invokeMethod('prepareVpn');
        } catch (_) {
          // Si prepareVpn n'est pas implémenté, on continue
        }
      }),
      // ✅ CORRIGÉ — protections système en dernière étape,
      // après consentement explicite de l'utilisateur
      _PermStep('Protections système...', () async {
        if (!mounted) return;
        final provider = context.read<MeshProvider>();
        await provider.activateSystemProtections();
      }),
    ];

    for (int i = 0; i < steps.length; i++) {
      if (!mounted) return;
      setState(() {
        _stepLabel = steps[i].label;
        _progress = (i + 1) / steps.length;
      });

      try {
        await steps[i].action();
      } catch (e) {
        // Continuer même si une étape échoue
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    // Marquer comme fait
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('fn_permissions_granted', true);

    if (mounted) {
      setState(() {
        _processing = false;
        _progress = 1.0;
        _stepLabel = 'Tout est prêt !';
      });
      await Future.delayed(const Duration(milliseconds: 600));
      widget.onComplete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // ─── Icône ───
              AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (_, __) => Transform.scale(
                  scale: 1.0 + _pulseCtrl.value * 0.08,
                  child: Container(
                    width: 100, height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [_purple, _mint],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _purple.withOpacity(0.4),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.shield_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // ─── Titre ───
              const Text(
                'Activer FriendlyNET',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),

              const SizedBox(height: 16),

              // ─── Description ───
              Text(
                'Pour partager et recevoir Internet entre amis, '
                'FriendlyNET a besoin de quelques autorisations. '
                'Tes données restent privées et chiffrées.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 15,
                  height: 1.5,
                ),
              ),

              const SizedBox(height: 32),

              // ─── Checkbox ───
              if (!_processing) ...[
                GestureDetector(
                  onTap: () => setState(() => _accepted = !_accepted),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161630),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _accepted ? _mint : const Color(0xFF2D2D50),
                        width: _accepted ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 26, height: 26,
                          decoration: BoxDecoration(
                            color: _accepted ? _mint : Colors.transparent,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: _accepted ? _mint : Colors.white38,
                              width: 2,
                            ),
                          ),
                          child: _accepted
                              ? const Icon(Icons.check, color: Colors.black, size: 18)
                              : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'J\'autorise FriendlyNET à utiliser le WiFi, '
                            'créer un tunnel sécurisé, et rester actif en '
                            'arrière-plan pour partager ma connexion.',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 13.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // ─── Note VPN ───
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A35),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded, color: _purple, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Android va afficher une confirmation VPN — '
                          'c\'est normal et obligatoire. Ce tunnel ne sort '
                          'jamais tes données vers des tiers.',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // ─── Barre de progression ───
              if (_processing) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 8,
                    backgroundColor: const Color(0xFF2D2D50),
                    valueColor: AlwaysStoppedAnimation<Color>(_mint),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  _stepLabel,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 14,
                  ),
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                ),
              ],

              const Spacer(flex: 3),

              // ─── Bouton ───
              if (!_processing)
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: _accepted ? _grantAll : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accepted ? _mint : const Color(0xFF2D2D50),
                      foregroundColor: _accepted ? Colors.black : Colors.white38,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: _accepted ? 6 : 0,
                    ),
                    child: const Text(
                      'Activer',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermStep {
  final String label;
  final Future<void> Function() action;
  const _PermStep(this.label, this.action);
}
