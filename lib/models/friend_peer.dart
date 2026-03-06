/// Modèle de pair réseau FriendlyNET.
/// Représente une personne connectée au réseau mesh.

enum NetKind { lte, fiveG, wifi, offline }

enum FriendRole { idle, host, guest }

enum MeshPhase { dormant, searching, handshake, live, recovering, broken }

class FriendPeer {
  final String uid;
  final String nickname;
  final String hwAddr;
  final String meshIp;
  final NetKind netKind;
  final int strength; // 0-100
  final bool hosting;
  final bool online;
  final DateTime spotted;
  final int bandwidth;
  final String country;

  FriendPeer({
    required this.uid,
    required this.nickname,
    this.hwAddr = '',
    this.meshIp = '',
    this.netKind = NetKind.offline,
    this.strength = 0,
    this.hosting = false,
    this.online = true,
    DateTime? spotted,
    this.bandwidth = 0,
    this.country = '',
  }) : spotted = spotted ?? DateTime.now();

  int get bars {
    if (strength >= 75) return 4;
    if (strength >= 50) return 3;
    if (strength >= 25) return 2;
    return 1;
  }

  String get strengthLabel {
    if (strength >= 75) return 'Excellent';
    if (strength >= 50) return 'Bon';
    if (strength >= 25) return 'Moyen';
    return 'Faible';
  }

  String get netLabel {
    switch (netKind) {
      case NetKind.lte: return '4G';
      case NetKind.fiveG: return '5G';
      case NetKind.wifi: return 'WiFi';
      case NetKind.offline: return '—';
    }
  }

  String get letter =>
      nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';

  bool get isAlive =>
      DateTime.now().difference(spotted).inSeconds < 30;

  FriendPeer refresh({
    String? nickname,
    String? meshIp,
    NetKind? netKind,
    int? strength,
    bool? hosting,
    bool? online,
    DateTime? spotted,
    int? bandwidth,
    String? country,
  }) {
    return FriendPeer(
      uid: uid,
      nickname: nickname ?? this.nickname,
      hwAddr: hwAddr,
      meshIp: meshIp ?? this.meshIp,
      netKind: netKind ?? this.netKind,
      strength: strength ?? this.strength,
      hosting: hosting ?? this.hosting,
      online: online ?? this.online,
      spotted: spotted ?? this.spotted,
      bandwidth: bandwidth ?? this.bandwidth,
      country: country ?? this.country,
    );
  }

  Map<String, dynamic> pack() => {
    'uid': uid,
    'nickname': nickname,
    'hwAddr': hwAddr,
    'meshIp': meshIp,
    'netKind': netKind.name,
    'strength': strength,
    'hosting': hosting,
    'online': online,
    'spotted': spotted.toIso8601String(),
    'bandwidth': bandwidth,
    'country': country,
  };

  factory FriendPeer.unpack(Map<String, dynamic> m) => FriendPeer(
    uid: m['uid'] as String? ?? '',
    nickname: m['nickname'] as String? ?? 'Ami',
    hwAddr: m['hwAddr'] as String? ?? '',
    meshIp: m['meshIp'] as String? ?? '',
    netKind: NetKind.values.firstWhere(
      (e) => e.name == (m['netKind'] as String? ?? ''),
      orElse: () => NetKind.offline,
    ),
    strength: m['strength'] as int? ?? 0,
    hosting: m['hosting'] as bool? ?? false,
    online: m['online'] as bool? ?? true,
    spotted: DateTime.tryParse(m['spotted'] as String? ?? ''),
    bandwidth: m['bandwidth'] as int? ?? 0,
    country: m['country'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FriendPeer && uid == other.uid;

  @override
  int get hashCode => uid.hashCode;
}

/// Métriques de session
class SessionMetrics {
  final int uploaded;
  final int downloaded;
  final Duration elapsed;
  final int tunnels;

  const SessionMetrics({
    this.uploaded = 0,
    this.downloaded = 0,
    this.elapsed = Duration.zero,
    this.tunnels = 0,
  });

  int get total => uploaded + downloaded;

  String get upText => _fmt(uploaded);
  String get downText => _fmt(downloaded);
  String get totalText => _fmt(total);
  String get timer =>
      '${elapsed.inHours.toString().padLeft(2, '0')}:'
      '${(elapsed.inMinutes % 60).toString().padLeft(2, '0')}:'
      '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(2)} GB';
  }

  SessionMetrics evolve({
    int? uploaded,
    int? downloaded,
    Duration? elapsed,
    int? tunnels,
  }) {
    return SessionMetrics(
      uploaded: uploaded ?? this.uploaded,
      downloaded: downloaded ?? this.downloaded,
      elapsed: elapsed ?? this.elapsed,
      tunnels: tunnels ?? this.tunnels,
    );
  }
}
