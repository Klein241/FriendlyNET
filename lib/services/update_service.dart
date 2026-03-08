import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Service de mise à jour in-app.
///
/// Interroge le Worker /version au démarrage (max 1 fois par heure).
/// Si une nouvelle version existe → affiche un dialog.
/// Si `forced` est true → bloque l'usage jusqu'à mise à jour.
class UpdateService {
  static const _workerUrl =
      'https://friendlynet-mesh.bufferwave.workers.dev/version';
  static const _prefLastCheck = 'fn_update_last_check';
  static const _prefSkippedVersion = 'fn_update_skipped';
  static const _checkIntervalHours = 1;

  /// Vérifie les mises à jour et affiche un dialog si nécessaire.
  /// À appeler dans le `build` du MeshHomeScreen ou après bootstrap.
  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      // Ne pas vérifier plus d'une fois par heure
      final prefs = await SharedPreferences.getInstance();
      final lastCheck = prefs.getInt(_prefLastCheck) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastCheck < _checkIntervalHours * 3600 * 1000) return;
      await prefs.setInt(_prefLastCheck, now);

      // Récupérer la version distante
      final response = await http
          .get(Uri.parse(_workerUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final remoteVersion = data['version'] as String? ?? '';
      final buildNumber = data['buildNumber'] as int? ?? 0;
      final apkUrl = data['apkUrl'] as String? ?? '';
      final releaseUrl = data['releaseUrl'] as String? ?? '';
      final changelog = (data['changelog'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      final forced = data['forced'] as bool? ?? false;

      if (remoteVersion.isEmpty || apkUrl.isEmpty) return;

      // Récupérer la version locale
      final info = await PackageInfo.fromPlatform();
      final localVersion = info.version; // ex: "1.0.0"
      final localBuild = int.tryParse(info.buildNumber) ?? 0;

      // Comparer
      if (!_isNewer(remoteVersion, buildNumber, localVersion, localBuild)) {
        return;
      }

      // Version déjà ignorée par l'utilisateur ?
      final skipped = prefs.getString(_prefSkippedVersion) ?? '';
      if (!forced && skipped == remoteVersion) return;

      // Afficher le dialog
      if (context.mounted) {
        _showUpdateDialog(
          context,
          version: remoteVersion,
          changelog: changelog,
          apkUrl: apkUrl,
          releaseUrl: releaseUrl,
          forced: forced,
        );
      }
    } catch (_) {
      // Silencieux — pas de mise à jour n'est pas critique
    }
  }

  /// Compare semver + buildNumber
  static bool _isNewer(
    String remote,
    int remoteBuild,
    String local,
    int localBuild,
  ) {
    final rParts = remote.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final lParts = local.split('.').map((s) => int.tryParse(s) ?? 0).toList();

    // Pad to 3 parts
    while (rParts.length < 3) rParts.add(0);
    while (lParts.length < 3) lParts.add(0);

    for (int i = 0; i < 3; i++) {
      if (rParts[i] > lParts[i]) return true;
      if (rParts[i] < lParts[i]) return false;
    }
    // Same semver → compare build number
    return remoteBuild > localBuild;
  }

  static void _showUpdateDialog(
    BuildContext context, {
    required String version,
    required List<String> changelog,
    required String apkUrl,
    required String releaseUrl,
    required bool forced,
  }) {
    showDialog(
      context: context,
      barrierDismissible: !forced,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF161630),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ─── Icône ───
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6C63FF), Color(0xFF00E5A0)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6C63FF).withOpacity(0.3),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.system_update_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),

              const SizedBox(height: 16),

              // ─── Titre ───
              Text(
                forced
                    ? 'Mise à jour obligatoire'
                    : 'Nouvelle version disponible',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'Version $version',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 16),

              // ─── Changelog ───
              if (changelog.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D0D1A),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nouveautés :',
                        style: TextStyle(
                          color: const Color(0xFF00E5A0),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...changelog.map(
                        (item) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '• ',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.7),
                                  fontSize: 13,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  item,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.7),
                                    fontSize: 13,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 20),

              // ─── Bouton télécharger ───
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse(apkUrl);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5A0),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 20),
                  label: const Text(
                    'Télécharger la mise à jour',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),

              // ─── Bouton ignorer (sauf si forced) ───
              if (!forced) ...[
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString(_prefSkippedVersion, version);
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: Text(
                    'Plus tard',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
