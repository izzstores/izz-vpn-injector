import 'dart:convert';

class SavedConfigModel {
  final String id;
  final String name;
  final String note;
  final String mode; // 'ssh' or 'v2ray'
  final String sshMethod; // 'direct', 'http_proxy', 'ssl_direct', 'ssl_payload', 'ws_direct', 'ws_ssl'
  final String server;
  final int port;
  final String username;
  final String password;
  final String sni;
  final String payload;
  final String remoteProxy;

  // V2Ray fields
  final String v2rayProtocol;
  final String v2rayUuid;
  final String v2rayTransport;
  final String v2rayPath;
  final String v2rayTls;

  // Locks (Classic HTTP Custom)
  final bool isLocked; // lock payload, sni, proxy from editing/viewing
  final bool isAccountLocked; // lock user/pass or allow user to use their own
  final DateTime? expiryDate;
  final bool blockRoot;
  final String? configPassword;
  final DateTime createdAt;

  SavedConfigModel({
    required this.id,
    required this.name,
    this.note = "",
    this.mode = "ssh",
    this.sshMethod = "ws_ssl",
    this.server = "",
    this.port = 443,
    this.username = "",
    this.password = "",
    this.sni = "",
    this.payload = "",
    this.remoteProxy = "",
    this.v2rayProtocol = "vmess",
    this.v2rayUuid = "",
    this.v2rayTransport = "ws",
    this.v2rayPath = "/vmess-ws",
    this.v2rayTls = "tls",
    this.isLocked = false,
    this.isAccountLocked = false,
    this.expiryDate,
    this.blockRoot = false,
    this.configPassword,
    required this.createdAt,
  });

  bool get isExpired {
    if (expiryDate == null) return false;
    return DateTime.now().isAfter(expiryDate!);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'note': note,
      'mode': mode,
      'sshMethod': sshMethod,
      'server': server,
      'port': port,
      'username': username,
      'password': password,
      'sni': sni,
      'payload': payload,
      'remoteProxy': remoteProxy,
      'v2rayProtocol': v2rayProtocol,
      'v2rayUuid': v2rayUuid,
      'v2rayTransport': v2rayTransport,
      'v2rayPath': v2rayPath,
      'v2rayTls': v2rayTls,
      'isLocked': isLocked,
      'isAccountLocked': isAccountLocked,
      'expiryDate': expiryDate?.toIso8601String(),
      'blockRoot': blockRoot,
      'configPassword': configPassword,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory SavedConfigModel.fromJson(Map<String, dynamic> json) {
    return SavedConfigModel(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name'] ?? 'Config',
      note: json['note'] ?? '',
      mode: json['mode'] ?? 'ssh',
      sshMethod: json['sshMethod'] ?? 'ws_ssl',
      server: json['server'] ?? '',
      port: json['port'] is int ? json['port'] : int.tryParse(json['port']?.toString() ?? '443') ?? 443,
      username: json['username'] ?? '',
      password: json['password'] ?? '',
      sni: json['sni'] ?? '',
      payload: json['payload'] ?? '',
      remoteProxy: json['remoteProxy'] ?? '',
      v2rayProtocol: json['v2rayProtocol'] ?? 'vmess',
      v2rayUuid: json['v2rayUuid'] ?? '',
      v2rayTransport: json['v2rayTransport'] ?? 'ws',
      v2rayPath: json['v2rayPath'] ?? '/vmess-ws',
      v2rayTls: json['v2rayTls'] ?? 'tls',
      isLocked: json['isLocked'] == true,
      isAccountLocked: json['isAccountLocked'] == true,
      expiryDate: json['expiryDate'] != null ? DateTime.tryParse(json['expiryDate']) : null,
      blockRoot: json['blockRoot'] == true,
      configPassword: json['configPassword'],
      createdAt: json['createdAt'] != null ? DateTime.tryParse(json['createdAt']) ?? DateTime.now() : DateTime.now(),
    );
  }

  // Encrypted export string (Format: IZZCONFIG::<base64_encoded>)
  String toExportString() {
    final rawJson = jsonEncode(toJson());
    final b64 = base64Encode(utf8.encode(rawJson));
    return "IZZCFG::$b64";
  }

  static SavedConfigModel? fromExportString(String exportStr, {String? enteredPassword}) {
    try {
      String clean = exportStr.trim();
      if (clean.startsWith("IZZCFG::")) {
        clean = clean.substring(8);
      } else if (clean.startsWith("HC::")) {
        clean = clean.substring(4);
      }
      final rawJson = utf8.decode(base64Decode(clean));
      final map = jsonDecode(rawJson) as Map<String, dynamic>;
      final config = SavedConfigModel.fromJson(map);

      if (config.configPassword != null && config.configPassword!.isNotEmpty) {
        if (enteredPassword == null || enteredPassword != config.configPassword) {
          throw Exception("PASSWORD_REQUIRED");
        }
      }

      if (config.isExpired) {
        throw Exception("CONFIG_EXPIRED");
      }

      return config;
    } catch (e) {
      rethrow;
    }
  }
}
