class ApiEndpoints {
  // Override at build time:
  // flutter build apk --dart-define=API_BASE_URL=https://example.com/api/v1
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://rioaja.haikara.biz.id/api/v1',
  );

  // Optional read-only fallback, for deployments where the VPS API is offline.
  // The file must use the same CloudConfigResponse JSON shape.
  static const String fallbackTemplatesUrl = String.fromEnvironment(
    'TEMPLATES_FALLBACK_URL',
    defaultValue: '',
  );

  // Endpoints
  static const String templates = "$baseUrl/templates";
  static const String appInfo = "$baseUrl/info";
  static const String health = "$baseUrl/health";

  // Master Secret Key for Anti-Sniffing (AES-256-GCM)
  // Must match APP_SECRET_KEY in VPS .env exactly
  static const String masterSecretKey =
      "01328905915b4945420cd862dfde5244132604c643c6ea05fc46c41558795637";
}
