import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String downloadUrl;
  final String assetName;
  final String tagName;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.assetName,
    required this.tagName,
  });
}

class AppUpdateCheckException implements Exception {
  final String message;

  const AppUpdateCheckException(this.message);

  @override
  String toString() => message;
}

class AppUpdateService {
  static const String _repoOwner = String.fromEnvironment(
    'QUICKBILL_UPDATE_REPO_OWNER',
    defaultValue: 'abdullah-moorad-x',
  );
  static const String _repoName = String.fromEnvironment(
    'QUICKBILL_UPDATE_REPO_NAME',
    defaultValue: 'quickbooks',
  );
  static const String _latestReleaseUrl =
      'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest';

  static Future<AppUpdateInfo?> checkForUpdate() async {
    if (!Platform.isWindows) return null;

    final package = await PackageInfo.fromPlatform();
    final currentVersion = package.version.trim();
    final response = await _getJson(_latestReleaseUrl);
    final tagName = (response['tag_name'] ?? '').toString().trim();
    final latestVersion = _normalizeVersion(tagName);
    if (latestVersion.isEmpty) return null;

    final assets = (response['assets'] as List? ?? const []);
    String downloadUrl = '';
    String assetName = '';
    for (final rawAsset in assets) {
      if (rawAsset is! Map) continue;
      final name = (rawAsset['name'] ?? '').toString().trim();
      final url = (rawAsset['browser_download_url'] ?? '').toString().trim();
      final lower = name.toLowerCase();
      if (url.isEmpty) continue;
      if (lower.endsWith('.exe') && lower.contains('installer')) {
        downloadUrl = url;
        assetName = name;
        break;
      }
    }
    if (downloadUrl.isEmpty) return null;
    if (_compareVersions(latestVersion, currentVersion) <= 0) {
      return null;
    }
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      releaseNotes: (response['body'] ?? '').toString().trim(),
      downloadUrl: downloadUrl,
      assetName: assetName,
      tagName: tagName,
    );
  }

  static Future<File> downloadInstaller(AppUpdateInfo info) async {
    final tempDir = await getTemporaryDirectory();
    final targetDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}quickbill_updates',
    );
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final targetFile = File(
      '${targetDir.path}${Platform.pathSeparator}${info.assetName}',
    );

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(info.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'QuickBill-Updater');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download failed with status ${response.statusCode}.',
          uri: Uri.parse(info.downloadUrl),
        );
      }
      final sink = targetFile.openWrite();
      await response.pipe(sink);
      await sink.close();
      return targetFile;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> launchInstallerAndExit(File installerFile) async {
    await Process.start(
      installerFile.path,
      const [],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  static Future<Map<String, dynamic>> _getJson(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'QuickBill-Updater');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      if (response.statusCode == HttpStatus.notFound) {
        throw const AppUpdateCheckException(
          'Update feed not found. Publish a GitHub release or check the updater repository settings.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppUpdateCheckException(
          'Update server returned status ${response.statusCode}.',
        );
      }
      final body = await utf8.decodeStream(response);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid update response.');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  static String _normalizeVersion(String value) {
    var out = value.trim();
    if (out.startsWith('v') || out.startsWith('V')) {
      out = out.substring(1);
    }
    final plusIndex = out.indexOf('+');
    if (plusIndex >= 0) {
      out = out.substring(0, plusIndex);
    }
    return out;
  }

  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final bParts = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final maxLen =
        aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < maxLen; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }
}
