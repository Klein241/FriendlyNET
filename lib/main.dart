import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/mesh_provider.dart';
import 'screens/welcome_screen.dart';
import 'screens/mesh_home_screen.dart';
import 'screens/permission_gateway_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const FriendlyNetApp());
}

class FriendlyNetApp extends StatelessWidget {
  const FriendlyNetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MeshProvider()..bootstrap(),
      child: MaterialApp(
        title: 'FriendlyNET',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6C63FF),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          fontFamily: 'Roboto',
        ),
        home: const _EntryRouter(),
      ),
    );
  }
}

/// Routeur d'entrée :
///   1. Permissions non accordées → PermissionGatewayScreen
///   2. Pas de nom configuré → WelcomeScreen
///   3. Sinon → MeshHomeScreen
class _EntryRouter extends StatefulWidget {
  const _EntryRouter();

  @override
  State<_EntryRouter> createState() => _EntryRouterState();
}

class _EntryRouterState extends State<_EntryRouter> {
  bool? _permissionsGranted;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _permissionsGranted = prefs.getBool('fn_permissions_granted') ?? false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Attendre le check permissions
    if (_permissionsGranted == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D1A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
        ),
      );
    }

    // Permissions pas encore accordées → gateway
    if (!_permissionsGranted!) {
      return PermissionGatewayScreen(
        onComplete: () {
          setState(() => _permissionsGranted = true);
        },
      );
    }

    return Consumer<MeshProvider>(
      builder: (ctx, prov, _) {
        // Attendre que le provider ait fini le bootstrap
        if (!prov.isReady) {
          return const Scaffold(
            backgroundColor: Color(0xFF0D0D1A),
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
            ),
          );
        }

        // Si le nom est vide → écran d'accueil
        if (prov.displayName.isEmpty) {
          return WelcomeScreen(
            onReady: (name) {
              prov.updateLabel(name);
            },
          );
        }

        // Sinon → écran principal
        return const MeshHomeScreen();
      },
    );
  }
}
