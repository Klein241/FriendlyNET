# FriendlyNET 🌐

> **Partage internet coopératif entre amis — Survie Orange 100 Mo garantie**

[![Flutter](https://img.shields.io/badge/Flutter-3.27-blue)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-API%2021+-green)](https://developer.android.com)
[![License](https://img.shields.io/badge/License-MIT-purple)](LICENSE)
[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-orange)](https://workers.cloudflare.com)

---

## 🎯 C'est quoi FriendlyNET ?

FriendlyNET est une application Android Flutter qui permet à deux personnes de **partager une connexion internet** sans application tierce, sans abonnement, et sans exposer ses données.

**Scénario typique :**
> Jean a épuisé son forfait Orange (100 Mo → 2G throttlé à 32 Kbps).
> Marie a encore de la data. En 3 secondes, Marie clique "Partager" et Jean navigue normalement — le tout via un tunnel chiffré E2E, même si Orange limite le débit.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    FriendlyNET App                      │
│                                                         │
│  Flutter/Dart Layer          Android Native Layer       │
│  ─────────────────           ──────────────────────    │
│  MeshProvider                FriendlyNetVpnService      │
│  ├── E2EService (X25519)    ├── TailscaleMode           │
│  ├── ConnectivityMonitor    │   ├── WiFi Direct Path    │
│  └── BufferwaveApiService   │   ├── LAN Direct Path     │
│                             │   ├── Cloudflare Path     │
│  bufferwave_core            │   └── Multi-hop Path      │
│  ├── BufferWaveApi          FriendlyNetRelayService      │
│  ├── DohResolver            ├── TCP Relay (port 8899)   │
│  └── SmartServers           └── Worker WS Bridge        │
└─────────────────────────────────────────────────────────┘
                         │
              Cloudflare Workers (Edge)
              wss://bufferwave-tunnel.sfrfrfr.workers.dev
              ├── /mesh    — Signaling WebSocket
              ├── /tunnel  — VPN Tunnel (guest)
              └── /relay   — Relay Bridge (host)
```

### Sélection de chemin adaptative (TailscaleMode)

```
Priorité 1: WiFi Direct P2P ─────────── 0 Mo data, 0ms overhead
Priorité 2: LAN direct (même hotspot) ── <5ms latence
Priorité 3: Cloudflare Worker WSS ────── RTT ~80ms
Priorité 4: Multi-hop Workers ─────────── fallback si P3 bloqué
```

---

## ✨ Fonctionnalités complètes

| Fonctionnalité | Statut | Détails |
|---|---|---|
| **Partage internet** | ✅ | Host mode via TCP relay (port 8899) |
| **Tunnel VPN invité** | ✅ | Interface TUN + WebSocket Cloudflare |
| **WiFi Direct** | ✅ | P2P local → 0 Mo data utilisé |
| **TailscaleMode** | ✅ | Multi-path adaptive (4 niveaux) |
| **E2E Chiffrement** | ✅ | X25519 ECDH + AES-256-GCM |
| **Auto Low-Bandwidth** | ✅ | Détection RTT > 600ms → mode éco |
| **bufferwave_core** | ✅ | DoH + health-check + heartbeat |
| **Foreground Service** | ✅ | Anti-kill Android |
| **Battery Exemption** | ✅ | Background illimité |
| **Unrestricted Data** | ✅ | Bypass Data Saver |
| **Auto-Consent** | ✅ | Partage automatique |
| **Path Healing** | ✅ | Reconnexion auto (max 20×) |
| **Métriques session** | ✅ | Upload/Download/Durée |
| **Cache pairs offline** | ✅ | Retrouve les amis sans connexion |

---

## 🔐 Sécurité E2E

FriendlyNET implémente un échange de clés **X25519 ECDH** à chaque nouvelle session pair-à-pair :

```
Jean                    Marie
 │                        │
 │── bridge_offer ───────►│
 │   + pubKey_jean        │
 │                        │── dérive secret ECDH
 │◄────────── bridge_accept ─│
 │            + pubKey_marie  │
 │── dérive secret ECDH       │
 │                        │
 │══ AES-256-GCM chiffré ══│
```

**Vérification anti-MITM :**
Chaque appareil affiche un **fingerprint 8 hex** (visible dans Paramètres > Sécurité).
Comparez-le avec votre ami par voix/SMS — si identique, connexion sécurisée.

---

## 📱 Mode Éco-Data (Orange 100 Mo)

### Détection automatique
`ConnectivityMonitor` mesure la latence toutes les 60s :
- **Ping TCP** vers `1.1.1.1:443` × 5 requêtes
- Si RTT moyen **> 600ms** ou perte **> 40%** → bascule en mode éco
- Retour automatique en mode normal quand le débit s'améliore

### Optimisations en mode éco
| Paramètre | Normal | Mode Éco |
|---|---|---|
| Heartbeat WS | 15s | 45s |
| Keepalive TailscaleMode | 15s | 45-120s |
| Refresh pairs | 5s | 30s |
| Reconnect patience | 60s max | 120s max |
| Consommation estimée | ~1.5 MB/h | ~0.3 MB/h |

---

## 🚀 Installation

### Prérequis
- Flutter `>=3.27` (stable)
- Android SDK API 21+
- Dart `>=3.5.0`

### Dépendances clés
```yaml
dependencies:
  bufferwave_core:      # Moteur réseau (local path)
    path: ../bufferwave_core
  cryptography: ^2.7.0  # X25519 + AES-GCM (E2E)
  connectivity_plus: ^5.0.2  # Détection réseau
  logger: ^2.4.0        # Monitoring / logs
  web_socket_channel: ^3.0.0
  provider: ^6.1.2
  shared_preferences: ^2.2.0
  permission_handler: ^11.0.0
```

### Build
```bash
git clone https://github.com/Klein241/FriendlyNET.git
cd FriendlyNET
flutter pub get
flutter run --debug  # ou flutter build apk --release
```

---

## 💻 Utilisation — Exemple code

### 1. Démarrer FriendlyNET (MeshProvider bootstrap)
```dart
// main.dart — déjà configuré
void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => MeshProvider()..bootstrap(),
      child: const FriendlyNetApp(),
    ),
  );
}
```

### 2. Mode Hôte (partager sa connexion)
```dart
final prov = context.read<MeshProvider>();
final ok = await prov.startHosting();
if (ok) {
  // TailscaleMode actif → multi-hop automatique
  // Notification persistante affichée
  Navigator.push(context, MaterialPageRoute(
    builder: (_) => const HostingScreen(),
  ));
}
```

### 3. Mode Invité (utiliser l'internet d'un ami)
```dart
// Chercher les amis disponibles
await prov.startSearch();

// Se connecter au meilleur ami
final host = prov.friends.firstWhere((f) => f.hosting);
await prov.joinFriend(host);
// → TailscaleMode sélectionne automatiquement WiFi Direct ou Cloudflare
```

### 4. Configuration TailscaleMode (native Android)
```kotlin
// Configuré automatiquement dans FriendlyNetVpnService
val engine = TailscaleMode(
    nodeId = nodeId,
    userId = userId,
    onDataReceived = { bytes -> writeToTun(fd, bytes) },
    onPathChanged  = { type, addr -> updateNotification(...) },
    onConnected    = { startTunReadLoop() },
)
engine.setEcoMode(lowBandwidth)  // Auto via ConnectivityMonitor
engine.start(localIp)  // LAN direct si disponible
```

### 5. Bypass DNS avec DoH (bufferwave_core)
```dart
// Déjà intégré dans BufferwaveApiService.initialize()
final resolver = DohResolver();
resolver.setEndpoint('https://bufferwave-tunnel.sfrfrfr.workers.dev/resolve');
resolver.enable();
final ips = await resolver.resolve('cloudflare.com');
// → Résolution HTTPS, invisible pour Orange/FAI
```

---

## 🧪 Tests — Simuler Orange throttle

### Via Android Emulator (Network Throttling)
```
Android Studio → Device Manager → émulateur
→ ⁝ (More) → Cellular → Network Type: EDGE (2G)
→ Download speed: 32 Kbps / Upload: 32 Kbps
```

### Via ADB Shell
```bash
# Limiter à 32 Kbps (simule Orange épuisé)
adb shell tc qdisc add dev wlan0 root tbf rate 32kbit burst 16kbit latency 300ms
# Supprimer la limitation
adb shell tc qdisc del dev wlan0 root
```

### Test manuel du mode éco
```bash
# Surveiller les logs FriendlyNET
adb logcat -s FN-VPN FN-Relay FN-WifiDirect ConnectivityMonitor MeshProvider

# Chercher ces lignes :
# I/ConnectivityMonitor: ⚠️ LOW BANDWIDTH — Orange throttle détecté (650ms, 60% perte)
# I/MeshProvider: Auto low-bandwidth: true
# I/FN-VPN: 🔀 Chemin actif: CLOUDFLARE_DIRECT @ bufferwave-tunnel.sfrfrfr.workers.dev
```

---

## 📂 Structure du projet

```
friendly_net/
├── android/app/src/main/kotlin/com/sygmatech/friendly_net/
│   ├── MainActivity.kt              # Channels Flutter ↔ Native
│   ├── FriendlyNetVpnService.kt     # VPN TUN + TailscaleMode
│   ├── FriendlyNetRelayService.kt   # TCP Relay (mode hôte)
│   ├── FriendlyNetForegroundService.kt  # Anti-kill Android
│   ├── TailscaleMode.kt             # Moteur multi-path adaptatif
│   └── WifiDirectManager.kt         # WiFi Direct P2P
│
├── lib/
│   ├── main.dart                    # Entry point + routing
│   ├── models/
│   │   └── friend_peer.dart         # FriendPeer, SessionMetrics
│   ├── providers/
│   │   └── mesh_provider.dart       # Orchestrateur central
│   ├── screens/
│   │   ├── welcome_screen.dart      # Écran bienvenue
│   │   ├── mesh_home_screen.dart    # Écran principal (scan)
│   │   ├── hosting_screen.dart      # Mode hôte
│   │   ├── guest_screen.dart        # Mode invité
│   │   └── settings_screen.dart     # Paramètres (E2E, éco, etc.)
│   └── services/
│       ├── wifi_direct_service.dart  # Bridge Flutter ↔ WifiDirectManager
│       ├── e2e_service.dart          # X25519 ECDH + AES-256-GCM
│       ├── connectivity_monitor.dart # Auto-détection low-bandwidth
│       └── bufferwave_api_service.dart  # bufferwave_core integration
│
└── pubspec.yaml
```

---

## 🌐 Cloudflare Worker

Le Worker `bufferwave-tunnel.sfrfrfr.workers.dev` fournit :
- **`/mesh`** — WebSocket de signaling (announce, bridge_offer, bridge_accept)
- **`/tunnel`** — Relay de paquets IP entre invité et Worker (VPN guest)
- **`/relay`** — Bridge entre Worker et hôte (VPN host)
- **`/health`** — Health check (utilisé par BufferWaveApi)
- **`/resolve`** — DNS-over-HTTPS (utilisé par DohResolver)

---

## 🛡️ Permissions Android requises

```xml
<!-- Réseau -->
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE"/>

<!-- WiFi Direct (API 33+ = NEARBY_WIFI_DEVICES) -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>

<!-- VPN -->
<uses-permission android:name="android.permission.BIND_VPN_SERVICE"/>

<!-- Background -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```

---

## 🤝 Contributeurs

- **SYGMA-TECH** — Architecture, Android natif, Flutter UI
- **bufferwave_core** — Moteur réseau commun (DoH, API, SmartServers)

---

## 📄 Licence

MIT © 2025 SYGMA-TECH

---

*Conçu pour résister à Orange, Free, MTN et tous les FAI qui throttlent. 💪*
