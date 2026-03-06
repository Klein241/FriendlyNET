import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/mesh_provider.dart';

/// Écran affiché quand l'utilisateur partage son internet.
class HostingScreen extends StatefulWidget {
  const HostingScreen({super.key});

  @override
  State<HostingScreen> createState() => _HostingScreenState();
}

class _HostingScreenState extends State<HostingScreen>
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
        if (prov.isIdle && !prov.isHosting) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        }
        final guest = prov.bridge;
        final hasGuest = guest != null;

        return Scaffold(
          backgroundColor: _bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  _buildHeader(),
                  const Spacer(),
                  _buildRing(hasGuest),
                  const SizedBox(height: 24),
                  Text(
                    hasGuest ? 'Connexion partagée !' : 'En attente d\'un ami...',
                    style: TextStyle(
                      color: hasGuest ? _mint : Colors.white,
                      fontSize: 20, fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(prov.statusLine,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 13)),
                  const SizedBox(height: 24),
                  if (hasGuest) _connectedGuest(guest),
                  if (prov.pendingAsk != null) _askBanner(prov),
                  const Spacer(),
                  _statsRow(prov),
                  const SizedBox(height: 16),
                  _stopBtn(),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
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
        const Expanded(child: Text('Partage actif',
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
              Container(width: 6, height: 6,
                decoration: BoxDecoration(color: _mint, shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: _mint, blurRadius: 4)])),
              const SizedBox(width: 6),
              Text('EN LIGNE', style: TextStyle(color: _mint, fontSize: 10, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRing(bool active) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        final g = 0.3 + 0.5 * sin(_pulse.value * pi * 2);
        return Container(
          width: 160, height: 160,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _mint.withAlpha((80 * g).round()), blurRadius: 40, spreadRadius: 5)],
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                _mint.withAlpha(active ? 50 : 30),
                _mint.withAlpha(active ? 15 : 8),
                _bg,
              ]),
              border: Border.all(color: _mint.withAlpha(active ? 150 : 80), width: 3),
            ),
            child: const Center(child: Icon(Icons.wifi_tethering, size: 56, color: _mint)),
          ),
        );
      },
    );
  }

  Widget _connectedGuest(dynamic guest) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _mint.withAlpha(12), borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _mint.withAlpha(60)),
      ),
      child: Row(
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: _mint.withAlpha(30), border: Border.all(color: _mint.withAlpha(100))),
            child: Center(child: Text(guest.letter,
              style: TextStyle(color: _mint, fontSize: 20, fontWeight: FontWeight.w800))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(guest.nickname,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('Utilise ton Internet', style: TextStyle(color: _mint, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Icon(Icons.link, color: _mint, size: 22),
        ],
      ),
    );
  }

  Widget _askBanner(MeshProvider prov) {
    final req = prov.pendingAsk!;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9800).withAlpha(15), borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFF9800).withAlpha(60)),
      ),
      child: Column(
        children: [
          Row(children: [
            const Icon(Icons.person_add, color: Color(0xFFFF9800), size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('${req.nickname} veut se connecter',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: SizedBox(height: 42,
              child: OutlinedButton(
                onPressed: prov.rejectGuest,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Refuser', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            )),
            const SizedBox(width: 10),
            Expanded(child: SizedBox(height: 42,
              child: ElevatedButton(
                onPressed: prov.acceptGuest,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _mint, foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('✓ Accepter', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            )),
          ]),
        ],
      ),
    );
  }

  Widget _statsRow(MeshProvider prov) {
    final m = prov.metrics;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: _surface, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _outline),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat('⏱', 'Durée', m.timer),
          Container(width: 1, height: 30, color: _outline),
          _stat('↑', 'Envoyé', m.upText),
          Container(width: 1, height: 30, color: _outline),
          _stat('↓', 'Reçu', m.downText),
        ],
      ),
    );
  }

  Widget _stat(String icon, String label, String val) {
    return Column(children: [
      Text(icon, style: const TextStyle(fontSize: 14)),
      const SizedBox(height: 2),
      Text(val, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
      Text(label, style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 10)),
    ]);
  }

  Widget _stopBtn() {
    return SizedBox(
      width: double.infinity, height: 56,
      child: ElevatedButton.icon(
        onPressed: () async {
          await context.read<MeshProvider>().stopHosting();
          if (mounted) Navigator.pop(context);
        },
        icon: const Icon(Icons.stop_circle_outlined, size: 22),
        label: const Text('Arrêter le partage',
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
