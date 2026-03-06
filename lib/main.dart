import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  bool _loading = true;
  bool _firstLaunch = false;

  @override
  void initState() {
    super.initState();
    _checkFirstLaunch();
  }

  Future<void> _checkFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('fn_display_name') ?? '';
    if (mounted) {
      setState(() {
        _loading = false;
        _firstLaunch = name.isEmpty;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D1A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
        ),
      );
    }

    if (_firstLaunch) {
      return WelcomeScreen(
        onReady: (name) {
          final prov = context.read<MeshProvider>();
          prov.updateLabel(name);
          setState(() => _firstLaunch = false);
        },
      );
    }

    return const MeshHomeScreen();
  }
}
