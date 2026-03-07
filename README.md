# FriendlyNET 🌐

**Internet coopératif entre amis — sans frontières.**

FriendlyNET permet à deux téléphones Android de partager leur connexion Internet de manière sécurisée. Un ami avec du data partage sa connexion, un autre s'y connecte — comme un hotspot, mais à distance et chiffré.

## 🎯 Comment ça marche

```
📱 Hôte (a Internet)          📱 Invité (pas d'Internet)
     │                              │
     ├── Ouvre un relay ◄───────────┤ Se connecte au relay
     │                              │
     ├── Reçoit les paquets ◄───────┤ VPN capture le trafic
     │                              │
     └── Forward vers Internet ─────┘ Réponse arrive via VPN
```

### Chemins réseau (du meilleur au fallback)

| Priorité | Chemin | Data | Latence |
|----------|--------|------|---------|
| 1 | WiFi Direct | 0 Mo | ~5ms |
| 2 | LAN (même réseau) | 0 Mo | ~10ms |
| 3 | Cloudflare Edge | Minimale | ~50-200ms |
| 4 | Multi-hop (fallback) | Variable | ~200-500ms |

## ✅ Ce qui marche

- [x] **Signaling mesh** via Cloudflare Worker (WebSocket)
- [x] **VPN Android natif** (VpnService + TUN interface)
- [x] **Moteur relay adaptatif** (TailscaleMode — path finding automatique)
- [x] **Forwarding TCP complet** (PacketProcessor — parsing IP + TCP + DNS)
- [x] **Relay edge** (EdgeRelay avec rate limiting, health monitoring)
- [x] **Reconnexion automatique** (backoff exponentiel + jitter + path healing)
- [x] **Chiffrement E2E** (X25519 ECDH + AES-256-GCM)
- [x] **Mode éco** (keepalive adaptatif pour réseau throttlé)
- [x] **Métriques réseau** (bytes envoyés/reçus, connexions actives)
- [x] **Consentement hôte** (auto-consent ou approbation manuelle)
- [x] **Foreground service** (fonctionne en arrière-plan)
- [x] **Protection batterie** (exemption d'optimisation Android)
- [x] **Permission VPN runtime** (demande au moment de la connexion)

## ⚠️ Ce qui ne marche pas encore

- [ ] WiFi Direct (découverte + connexion P2P réelle)
- [ ] OTA updates (Shorebird à configurer)
- [ ] Tests automatisés complets
- [ ] Signed release APK
- [ ] Support iOS
- [ ] UDP forwarding (hors DNS)
- [ ] IPv6

## 🏗 Architecture

```
┌─────────────────────────────────────────────────┐
│                  Flutter (Dart)                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │ Mesh     │  │ Hosting  │  │ Guest Screen  │  │
│  │ Provider │  │ Screen   │  │               │  │
│  └────┬─────┘  └──────────┘  └───────────────┘  │
│       │                                         │
│  ┌────▼─────────────────────────────────────┐   │
│  │        bufferwave_core (v14.0)           │   │
│  │  EdgeRelay │ PathSelector │ PacketCodec  │   │
│  │  TcpForwarder │ ConnectionTable         │   │
│  └────┬────────────────────────────────────┘   │
├───────┼─────────── MethodChannel ──────────────┤
│       │         Android (Kotlin)                │
│  ┌────▼─────┐  ┌──────────┐  ┌──────────────┐  │
│  │ Packet   │  │ VPN      │  │ Tailscale    │  │
│  │Processor │  │ Service  │  │ Mode         │  │
│  └──────────┘  └──────────┘  └──────────────┘  │
└─────────────────────────────────────────────────┘
          │                         │
          ▼                         ▼
    ┌──────────┐            ┌──────────────┐
    │ Internet │            │ Cloudflare   │
    │ (TCP/DNS)│            │ Worker Relay │
    └──────────┘            └──────────────┘
```

## 🔧 Setup développeur

### Prérequis
- Flutter 3.x (canal stable)
- Android SDK 34+
- Kotlin 1.9+

### Installation

```bash
git clone https://github.com/Klein241/FriendlyNET.git
cd FriendlyNET
flutter pub get
flutter run
```

### Build APK

```bash
flutter build apk --debug
# APK → build/app/outputs/flutter-apk/app-debug.apk
```

## 📦 Dépendances

| Paquet | Usage |
|--------|-------|
| `bufferwave_core` | Moteur relay (EdgeRelay, PacketCodec, etc.) |
| `web_socket_channel` | WebSocket client |
| `provider` | State management |
| `shared_preferences` | Persistance locale |
| `cryptography` | E2E encryption |
| `connectivity_plus` | Monitoring réseau |
| `permission_handler` | Permissions Android |
| `logger` | Logging structuré |

## 🔐 Sécurité

- Chiffrement E2E avec X25519 (échange de clés) + AES-256-GCM (données)
- Toutes les connexions relay passent par WebSocket sécurisé (WSS)
- Les paquets IP sont relayés sans être inspectés par le serveur relay
- Aucune donnée utilisateur n'est stockée sur le serveur

## 📄 Licence

Projet privé — © SYGMA-TECH
