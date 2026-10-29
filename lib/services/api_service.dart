import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import '../models/app_info_model.dart';
import '../models/template_model.dart';
import 'crypto_service.dart';

class ApiService {
  /// Fetches cloud templates from VPS and decrypts anti-sniffing payloads
  static Future<CloudConfigResponse?> fetchTemplates({
    String clientVersion = "1.0.0",
  }) async {
    try {
      final primary = Uri.parse("${ApiEndpoints.templates}?client_version=$clientVersion");
      http.Response? response;
      final endpoints = <Uri>[primary];
      if (ApiEndpoints.fallbackTemplatesUrl.trim().isNotEmpty) {
        endpoints.add(Uri.parse("${ApiEndpoints.fallbackTemplatesUrl}?client_version=$clientVersion"));
      }
      for (final uri in endpoints) {
        try {
          final candidate = await http.get(uri).timeout(const Duration(seconds: 12));
          if (candidate.statusCode == 200 && candidate.body.trim().isNotEmpty) {
            response = candidate;
            break;
          }
        } catch (_) {
          // Try the next configured endpoint.
        }
      }
      if (response == null) return null;

      final Map<String, dynamic> jsonBody = json.decode(response.body) as Map<String, dynamic>;
      final cloudResponse = CloudConfigResponse.fromJson(jsonBody);

      // Decrypt each template's sensitive fields (SNI & Payload) in memory
      final List<TemplateModel> decryptedTemplates = [];
      for (final t in cloudResponse.templates) {
        if (t.encryptedConfig.isNotEmpty) {
          final decryptedMap =
              await CryptoService.decryptTemplateConfig(t.encryptedConfig);
          if (decryptedMap != null) {
            decryptedTemplates.add(t.copyWith(
              sni: decryptedMap['sni'] as String? ?? '',
              payload: decryptedMap['payload'] as String? ?? '',
              proxy: decryptedMap['proxy'] as String? ?? '',
            ));
            continue;
          }
        }
        decryptedTemplates.add(t);
      }

      return CloudConfigResponse(
        appName: cloudResponse.appName,
        appVersion: cloudResponse.appVersion,
        minVersion: cloudResponse.minVersion,
        updateUrl: cloudResponse.updateUrl,
        forceUpdate: cloudResponse.forceUpdate,
        announcement: cloudResponse.announcement,
        categories: cloudResponse.categories,
        templates: decryptedTemplates,
      );
    } catch (e) {
      return null;
    }
  }

  /// Check server health
  static Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse(ApiEndpoints.health))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
