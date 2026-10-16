import 'dart:convert';

import 'package:dio/dio.dart';

/// Runtime backend configuration that can be changed **without shipping a new
/// app build**.
///
/// The app reads a tiny JSON file (`config.json`) from the sources below and
/// switches its backend address when the value changes. Everything here is
/// best-effort: if every source fails — offline, DNS blocked, malformed
/// payload, unreachable host — the caller keeps the address it already had, so
/// the app never breaks because of this lookup.
class RemoteConfig {
  const RemoteConfig._();

  /// Cloudflare Worker URL (free tier), if it has been deployed.
  ///
  /// Deploy `cloudflare/api-config` (see its README) and paste the printed
  /// `https://…workers.dev/config.json` URL here. While this is `null` the
  /// GitHub source below is used, which is already live.
  static const String? workerUrl = null;

  /// Always-available fallback: a raw file in the project's GitHub repo.
  /// Editing that file on github.com takes effect on the next app launch.
  static const String githubUrl =
      'https://raw.githubusercontent.com/Champsg/vidkwaii/main/config.json';

  /// Sources are tried in order; the first valid payload wins.
  static List<String> get sources => [
        if (workerUrl != null) workerUrl!,
        githubUrl,
      ];

  static const Duration timeout = Duration(seconds: 4);

  /// Returns the configured backend base URL, or `null` when unavailable.
  static Future<String?> fetchApiBaseUrl() async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );

    for (final source in sources) {
      try {
        final response = await dio.get<dynamic>(source);
        final data = response.data;
        final decoded = data is String ? jsonDecode(data) : data;
        if (decoded is! Map) continue;

        final candidate = decoded['api_base_url']?.toString().trim();
        if (isUsableUrl(candidate)) return trimTrailingSlash(candidate!);
      } catch (_) {
        // Try the next source.
      }
    }
    return null;
  }

  /// Confirms a candidate backend actually answers before we switch to it.
  ///
  /// This is what stops a typo in `config.json` from taking the app down: a
  /// bad value is simply ignored and the current address stays in use.
  static Future<bool> isHealthy(String baseUrl) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    try {
      final response = await dio.get<dynamic>('${trimTrailingSlash(baseUrl)}/health');
      final status = response.statusCode;
      return status != null && status < 400;
    } catch (_) {
      return false;
    }
  }

  /// Whether [value] looks like an http(s) base URL.
  static bool isUsableUrl(String? value) {
    if (value == null || value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  static String trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
