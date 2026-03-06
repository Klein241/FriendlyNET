import 'dart:math';
import 'package:flutter/material.dart';

/// Écran d'accueil FriendlyNET — première ouverture.
/// L'utilisateur entre son prénom/pseudo.
class WelcomeScreen extends StatefulWidget {
  final void Function(String name) onReady;
  const WelcomeScreen({super.key, required this.onReady});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  late AnimationController _glow;

  static const _bg = Color(0xFF0D0D1A);
  static const _purple = Color(0xFF6C63FF);
  static const _pink = Color(0xFFE040FB);

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _glow.dispose();
    super.dispose();
  }

  void _continue() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    widget.onReady(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),
              // Logo animé
              AnimatedBuilder(
                animation: _glow,
                builder: (_, __) {
                  final g = _glow.value;
                  return Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          _purple.withAlpha((50 + 60 * g).round()),
                          _purple.withAlpha((15 + 20 * g).round()),
                          _bg,
                        ],
                      ),
                      border: Border.all(
                        color: _purple.withAlpha((100 + 55 * g).round()),
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _purple.withAlpha((40 + 40 * g).round()),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text('🤝', style: TextStyle(fontSize: 48)),
                    ),
                  );
                },
              ),
              const SizedBox(height: 30),
              // Titre
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [_purple, _pink],
                ).createShader(bounds),
                child: const Text(
                  'FriendlyNET',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Partage Internet entre amis,\nsans frontières.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withAlpha(150),
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 50),
              // Champ nom
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(7),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _purple.withAlpha(60)),
                ),
                child: TextField(
                  controller: _ctrl,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'Ton prénom ou pseudo',
                    hintStyle: TextStyle(color: Colors.white.withAlpha(60)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 18,
                    ),
                  ),
                  onSubmitted: (_) => _continue(),
                ),
              ),
              const SizedBox(height: 20),
              // Bouton
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _continue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 8,
                    shadowColor: _purple.withAlpha(100),
                  ),
                  child: const Text(
                    'Commencer',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const Spacer(flex: 3),
              // Footer
              Text(
                'FriendlyNET — Powered by BufferWave Core',
                style: TextStyle(
                  color: Colors.white.withAlpha(40),
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
