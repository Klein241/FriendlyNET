import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/mesh_provider.dart';
import 'screens/welcome_screen.dart';
import 'screens/mesh_home_screen.dart';

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

/// Routeur d'entrée : si pas de nom configuré → Welcome, sinon → Home
class _EntryRouter extends StatefulWidget {
  const _EntryRouter();

  @override
  State<_EntryRouter> createState() => _EntryRouterState();
}

class _EntryRouterState extends State<_EntryRouter> {
  @override
  Widget build(BuildContext context) {
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
