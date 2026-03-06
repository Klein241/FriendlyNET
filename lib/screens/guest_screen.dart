import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/mesh_provider.dart';

/// Écran affiché quand l'utilisateur utilise l'internet d'un ami.
class GuestScreen extends StatefulWidget {
  const GuestScreen({super.key});

  @override
  State<GuestScreen> createState() => _GuestScreenState();
}

class _GuestScreenState extends State<GuestScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  static const _bg = Color(0xFF0D0D1A);
  static const _surface = Color(0xFF161630);
  static const _outline = Color(0xFF2D2D50);
  static const _purple = Color(0xFF6C63FF);
  static const _mint = Color(0xFF00E5A0);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MeshProvider>(
      builder: (ctx, prov, _) {
        if (prov.isIdle) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        }
        final host = prov.bridge;
        final hostName = host?.nickname ?? 'un ami';

        return Scaffold(
          backgroundColor: _bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  _header(),
                  const Spacer(),
                  _visual(),
                  const SizedBox(height: 30),
                  _infoCard(prov, hostName),
                  const SizedBox(height: 20),
                  _stats(prov),
                  const Spacer(),
                  _tips(),
                  const SizedBox(height: 16),
                  _disconnectBtn(),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header() {
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: _surface, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _outline),
            ),
            child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
          ),
        ),
        const SizedBox(width: 14),
        const Expanded(child: Text('Connecté',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _mint.withAlpha(20), borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _mint.withAlpha(60)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield, color: _mint, size: 14),
              const SizedBox(width: 4),
              Text('TUNNEL ACTIF', style: TextStyle(color: _mint, fontSize: 10, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _visual() {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        final scale = 1.0 + 0.03 * sin(_pulse.value * pi * 2);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 120, height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _purple.withAlpha((60 + 40 * sin(_pulse.value * pi * 2)).round()),
                  blurRadius: 30, spreadRadius: 3,
                ),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [_purple.withAlpha(40), _purple.withAlpha(12), _bg]),
                border: Border.all(color: _purple.withAlpha(120), width: 3),
              ),
              child: const Center(child: Icon(Icons.shield_outlined, size: 48, color: _purple)),
            ),
          ),
        );
      },
    );
  }

  Widget _infoCard(MeshProvider prov, String hostName) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [_purple.withAlpha(15), _purple.withAlpha(5)]),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _purple.withAlpha(50)),
      ),
      child: Column(
        children: [
          Text('Connecté via $hostName',
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text('Tout ton trafic Internet passe\npar la connexion de $hostName',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 13, height: 1.5)),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _appIcon('📺', 'YouTube'),
              const SizedBox(width: 10),
              _appIcon('💬', 'WhatsApp'),
              const SizedBox(width: 10),
              _appIcon('🌐', 'Chrome'),
              const SizedBox(width: 10),
              _appIcon('📱', 'Tout'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _appIcon(String emoji, String label) {
    return Column(children: [
      Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: _surface, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _outline),
        ),
        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 20))),
      ),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 9)),
    ]);
  }

  Widget _stats(MeshProvider prov) {
    final m = prov.metrics;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: _surface, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _outline),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statItem(Icons.timer_outlined, 'Durée', m.timer),
          Container(width: 1, height: 35, color: _outline),
          _statItem(Icons.arrow_downward, 'Reçu', m.downText),
          Container(width: 1, height: 35, color: _outline),
          _statItem(Icons.arrow_upward, 'Envoyé', m.upText),
        ],
      ),
    );
  }

  Widget _statItem(IconData icon, String label, String val) {
    return Column(children: [
      Icon(icon, color: _purple.withAlpha(150), size: 16),
      const SizedBox(height: 4),
      Text(val, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
      Text(label, style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 10)),
    ]);
  }

  Widget _tips() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _mint.withAlpha(8), borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _mint.withAlpha(30)),
      ),
      child: Row(children: [
        const Text('💡', style: TextStyle(fontSize: 18)),
        const SizedBox(width: 12),
        Expanded(child: Text(
          'YouTube, WhatsApp, Chrome…\nTout passe automatiquement par le tunnel.',
          style: TextStyle(color: _mint.withAlpha(200), fontSize: 11, height: 1.5),
        )),
      ]),
    );
  }

  Widget _disconnectBtn() {
    return SizedBox(
      width: double.infinity, height: 56,
      child: ElevatedButton.icon(
        onPressed: () async {
          await context.read<MeshProvider>().leaveFriend();
          if (mounted) Navigator.pop(context);
        },
        icon: const Icon(Icons.link_off, size: 22),
        label: const Text('Déconnecter',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.redAccent.withAlpha(30),
          foregroundColor: Colors.redAccent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          side: BorderSide(color: Colors.redAccent.withAlpha(80)),
          elevation: 0,
        ),
      ),
    );
  }
}
