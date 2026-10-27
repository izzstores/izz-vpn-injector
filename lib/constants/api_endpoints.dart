class ApiEndpoints {
  // Base Cloud API URL
  static const String baseUrl = "https://rioaja.haikara.biz.id/api/v1";

  // Endpoints
  static const String templates = "$baseUrl/templates";
  static const String appInfo = "$baseUrl/info";
  static const String health = "$baseUrl/health";

  // Master Secret Key for Anti-Sniffing (AES-256-GCM)
  // Must match APP_SECRET_KEY in VPS .env exactly
  static const String masterSecretKey =
      "01328905915b4945420cd862dfde5244132604c643c6ea05fc46c41558795637";
}
