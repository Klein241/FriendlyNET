import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/friend_peer.dart';
import '../providers/mesh_provider.dart';
import '../services/update_service.dart';
import 'hosting_screen.dart';
import 'guest_screen.dart';
import 'settings_screen.dart';

/// Écran principal FriendlyNET.
/// Affiche les amis sur le mesh et permet de se connecter ou partager.
class MeshHomeScreen extends StatefulWidget {
  const MeshHomeScreen({super.key});

  @override
  State<MeshHomeScreen> createState() => _MeshHomeScreenState();
}

class _MeshHomeScreenState extends State<MeshHomeScreen>
    with TickerProviderStateMixin {
  late AnimationController _scanAnim;
  late AnimationController _shareBtn;
  bool _navigated = false; // Guard pour éviter boucle de navigation

  static const _bg = Color(0xFF0D0D1A);
  static const _surface = Color(0xFF161630);
  static const _outline = Color(0xFF2D2D50);
  static const _purple = Color(0xFF6C63FF);
  static const _mint = Color(0xFF00E5A0);
  static const _orange = Color(0xFFFF9800);

  @override
  void initState() {
    super.initState();
    _scanAnim = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _shareBtn = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final prov = context.read<MeshProvider>();
      if (prov.isIdle) {
        prov.startSearch();
        // Lancer aussi le scan WiFi Direct BLE en parallèle
        prov.startWifiDirect();
        _scanAnim.repeat(reverse: true);
      }
      // Vérifier les mises à jour en arrière-plan
      UpdateService.checkForUpdate(context);
    });
  }

  @override
  void dispose() {
    _scanAnim.dispose();
    _shareBtn.dispose();
    super.dispose();
  }

  void _onHostTap() async {
    final prov = context.read<MeshProvider>();
    final ok = await prov.startHosting();
    if (ok && mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const HostingScreen()));
    }
  }

  void _onJoinTap(FriendPeer friend) async {
    final prov = context.read<MeshProvider>();
    final ok = await prov.joinFriend(friend);
    if (ok && mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const GuestScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MeshProvider>(
      builder: (ctx, prov, _) {
        // Navigation fiable : un seul push, avec garde anti-boucle
        if (!_navigated && prov.isHosting) {
          _navigated = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HostingScreen()));
            }
          });
        }
        if (!_navigated && prov.isGuest) {
          _navigated = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const GuestScreen()));
            }
          });
        }

        return Scaffold(
          backgroundColor: _bg,
          body: SafeArea(
            child: Column(
              children: [
                _header(prov),
                _status(prov),
                Expanded(child: _friendList(prov)),
                _shareButton(prov),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(MeshProvider prov) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_purple, Color(0xFF9C27B0)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: _purple.withAlpha(40), blurRadius: 12)],
            ),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset('assets/friendlynet_logo.png',
                  width: 28, height: 28, fit: BoxFit.cover),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('FriendlyNET',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
              Text('Salut ${prov.displayName} 👋',
                style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 12)),
              ],
          ),
          const Spacer(),
          // Low bandwidth badge
          if (prov.lowBandwidth)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _orange.withAlpha(20),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _orange.withAlpha(60)),
              ),
              child: Text('ÉCO',
                style: TextStyle(color: _orange, fontSize: 9, fontWeight: FontWeight.w800)),
            ),
          // Settings button
          GestureDetector(
            onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
            child: Container(
              width: 42, height: 42,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(8),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
              child: const Icon(Icons.settings, color: Colors.white54, size: 20),
            ),
          ),
          GestureDetector(
            onTap: () {
              if (prov.isSearching) {
                prov.stopSearch();
                _scanAnim.stop();
              } else {
                prov.startSearch();
                _scanAnim.repeat(reverse: true);
              }
            },
            child: AnimatedBuilder(
              animation: _scanAnim,
              builder: (_, __) => Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: prov.isSearching ? _purple.withAlpha(25) : Colors.white.withAlpha(8),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: prov.isSearching ? _purple.withAlpha(100) : Colors.white24,
                  ),
                  boxShadow: prov.isSearching
                      ? [BoxShadow(color: _purple.withAlpha((40 * _scanAnim.value).round()), blurRadius: 15)]
                      : [],
                ),
                child: Icon(
                  prov.isSearching ? Icons.radar : Icons.search,
                  color: prov.isSearching ? _purple : Colors.white54,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _status(MeshProvider prov) {
    if (prov.pendingAsk != null) return _askBanner(prov);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [_purple.withAlpha(15), _purple.withAlpha(5)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _purple.withAlpha(40)),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _scanAnim,
            builder: (_, __) => Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: prov.isSearching ? _mint : Colors.white30,
                boxShadow: prov.isSearching
                    ? [BoxShadow(color: _mint.withAlpha((120 * _scanAnim.value).round()), blurRadius: 8)]
                    : [],
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(prov.statusLine,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${prov.friends.length} ami${prov.friends.length > 1 ? 's' : ''} sur le réseau',
                  style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 11)),
              ],
            ),
          ),
          Icon(prov.isSearching ? Icons.wifi_tethering : Icons.wifi_find,
            color: _purple.withAlpha(150), size: 22),
        ],
      ),
    );
  }

  Widget _askBanner(MeshProvider prov) {
    final peer = prov.pendingAsk!;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [_orange.withAlpha(25), _orange.withAlpha(10)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _orange.withAlpha(80)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.person_add, color: _orange, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text('${peer.nickname} veut utiliser ton internet',
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600))),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SizedBox(height: 44,
                  child: OutlinedButton(
                    onPressed: prov.rejectGuest,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Refuser', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(height: 44,
                  child: ElevatedButton(
                    onPressed: prov.acceptGuest,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _mint,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Accepter', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _friendList(MeshProvider prov) {
    final list = prov.friends;
    if (list.isEmpty) return _emptyState(prov);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
          child: Row(
            children: [
              Text('Amis sur le réseau',
                style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 14, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('${list.length}',
                style: const TextStyle(color: _purple, fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            physics: const BouncingScrollPhysics(),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _friendCard(list[i]),
          ),
        ),
      ],
    );
  }

  Widget _friendCard(FriendPeer f) {
    final color = _barColor(f.strength);
    return GestureDetector(
      onTap: () => _onJoinTap(f),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _outline),
        ),
        child: Row(
          children: [
            Container(
              width: 50, height: 50,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [color.withAlpha(50), color.withAlpha(20)]),
                shape: BoxShape.circle,
                border: Border.all(color: color.withAlpha(100)),
              ),
              child: Center(child: Text(f.letter,
                style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w800))),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(f.nickname,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))),
                      if (f.country.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _purple.withAlpha(15), borderRadius: BorderRadius.circular(4)),
                          child: Text(f.country,
                            style: TextStyle(color: _purple.withAlpha(200), fontSize: 9, fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _bars(f.bars, color),
                      const SizedBox(width: 8),
                      Text(f.strengthLabel,
                        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(12), borderRadius: BorderRadius.circular(4)),
                        child: Text(f.netLabel,
                          style: TextStyle(color: Colors.white.withAlpha(150), fontSize: 10, fontWeight: FontWeight.w700)),
                      ),
                      if (f.hosting) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: _mint.withAlpha(20), borderRadius: BorderRadius.circular(4)),
                          child: Text('● Partage',
                            style: TextStyle(color: _mint, fontSize: 9, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [_purple.withAlpha(40), _purple.withAlpha(20)]),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _purple.withAlpha(80)),
              ),
              child: const Text('Connecter',
                style: TextStyle(color: _purple, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bars(int n, Color color) {
    return Row(
      children: List.generate(4, (i) => Container(
        width: 4, height: 6.0 + i * 3.5,
        margin: const EdgeInsets.only(right: 2),
        decoration: BoxDecoration(
          color: i < n ? color : Colors.white.withAlpha(30),
          borderRadius: BorderRadius.circular(2),
        ),
      )),
    );
  }

  Widget _emptyState(MeshProvider prov) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _scanAnim,
              builder: (_, __) => Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _purple.withAlpha(10),
                  border: Border.all(color: _purple.withAlpha(
                    prov.isSearching ? (40 + (30 * _scanAnim.value).round()) : 20)),
                ),
                child: Icon(prov.isSearching ? Icons.radar : Icons.wifi_find,
                  color: _purple.withAlpha(80), size: 36),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              prov.isSearching ? 'Recherche d\'amis...' : 'Personne en vue',
              style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              prov.isSearching
                  ? 'Les amis avec FriendlyNET\napparaîtront ici automatiquement\nmême s\'ils sont dans un autre pays !'
                  : 'Appuie sur le radar\npour chercher des amis',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withAlpha(60), fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _surface, borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _outline),
              ),
              child: Column(
                children: [
                  const Text('💡 Comment ça marche ?',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 12),
                  _tip('🌍', 'Fonctionne entre pays différents'),
                  _tip('📱', 'Un minimum de réseau suffit'),
                  _tip('🤝', 'Un ami partage son internet avec toi'),
                  _tip('🛡', 'Connexion chiffrée de bout en bout'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tip(String icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 10),
          Expanded(child: Text(text,
            style: TextStyle(color: Colors.white.withAlpha(130), fontSize: 12, height: 1.4))),
        ],
      ),
    );
  }

  Widget _shareButton(MeshProvider prov) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: AnimatedBuilder(
        animation: _shareBtn,
        builder: (_, __) => GestureDetector(
          onTap: _onHostTap,
          child: Container(
            width: double.infinity, height: 60,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [_purple, _purple.withAlpha(200), const Color(0xFF5546CC)]),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: _purple.withAlpha((60 + 30 * sin(_shareBtn.value * pi * 2)).round()),
                  blurRadius: 20, offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_tethering, color: Colors.white, size: 24),
                SizedBox(width: 12),
                Text('Partager mon internet',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _barColor(int s) {
    if (s >= 75) return _mint;
    if (s >= 50) return const Color(0xFF8BC34A);
    if (s >= 25) return _orange;
    return Colors.redAccent;
  }
}
