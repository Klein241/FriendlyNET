# FriendlyNET — Partage Internet Coopératif 🤝

FriendlyNET permet de partager sa connexion Internet avec des amis, même dans un autre pays, grâce au réseau mesh mondial.

## Architecture

```
FriendlyNET (App Flutter autonome)
    ├── lib/
    │   ├── main.dart                    # Entry point
    │   ├── models/friend_peer.dart      # Modèle de pair
    │   ├── providers/mesh_provider.dart  # État global
    │   └── screens/
    │       ├── welcome_screen.dart      # Onboarding
    │       ├── mesh_home_screen.dart    # Écran principal
    │       ├── hosting_screen.dart      # Mode partage
    │       └── guest_screen.dart        # Mode connecté
    ├── android/                         # Build APK indépendant
    └── pubspec.yaml                     # Dépend de bufferwave_core
```

## Écosystème

| Projet | Rôle | Repo |
|--------|------|------|
| **FriendlyNET** | App de partage internet | `Klein241/FriendlyNET` |
| **BufferWave** | App VPN complète | `Klein241/bufferwave` |
| **bufferwave-core** | Moteur réseau partagé | `Klein241/bufferwave-core` |
| **bufferwave-cloudflare** | Worker Cloudflare (signaling + tunnel) | Déployé |

## Build APK

```bash
cd friendly_net
flutter build apk --release
```

## Shorebird (Code Push)

```bash
# Installer Shorebird
curl --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/shorebirdtech/install/main/install.ps1 | iex

# Initialiser
shorebird init

# Premier release
shorebird release android

# Push update
shorebird patch android
```

## Comment ça marche

1. **Marie (France, bon internet)** → Ouvre FriendlyNET → "Partager mon internet"
2. **Jean (Cameroun, data minimale)** → Ouvre FriendlyNET → Voit Marie → "Connecter"
3. **Tout le trafic de Jean** passe par Marie via le tunnel Cloudflare
4. Jean peut utiliser YouTube, WhatsApp, Chrome normalement
