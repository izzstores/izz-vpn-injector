import 'dart:convert';

class V2RayConfigData {
  final String protocol; // vmess, vless, trojan, shadowsocks
  final String name;
  final String server;
  final int port;
  final String uuid; // or password
  final String transport; // ws, grpc, tcp
  final String path;
  final String sni;
  final String security; // none, tls, reality

  V2RayConfigData({
    required this.protocol,
    required this.name,
    required this.server,
    required this.port,
    required this.uuid,
    required this.transport,
    required this.path,
    required this.sni,
    required this.security,
  });
}

class V2RayParser {
  static V2RayConfigData? parse(String rawUrl) {
    try {
      final uri = rawUrl.trim();
      if (uri.startsWith("vmess://")) {
        return _parseVMess(uri);
      } else if (uri.startsWith("vless://")) {
        return _parseVLess(uri);
      } else if (uri.startsWith("trojan://")) {
        return _parseTrojan(uri);
      } else if (uri.startsWith("ss://")) {
        return _parseShadowsocks(uri);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static V2RayConfigData? _parseVMess(String uriStr) {
    final b64Part = uriStr.substring(8);
    // Add padding if needed
    String normalized = b64Part;
    while (normalized.length % 4 != 0) {
      normalized += "=";
    }
    final jsonStr = utf8.decode(base64Decode(normalized));
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;

    return V2RayConfigData(
      protocol: "vmess",
      name: map['ps'] ?? "VMess Config",
      server: map['add'] ?? "",
      port: int.tryParse(map['port']?.toString() ?? "443") ?? 443,
      uuid: map['id'] ?? "",
      transport: (map['net'] ?? "ws").toString().toLowerCase(),
      path: map['path'] ?? "/vmess-ws",
      sni: map['sni'] ?? map['host'] ?? "",
      security: (map['tls'] == "tls" || map['tls'] == "1") ? "tls" : "none",
    );
  }

  static V2RayConfigData? _parseVLess(String uriStr) {
    final parsed = Uri.parse(uriStr);
    final uuid = parsed.userInfo;
    final server = parsed.host;
    final port = parsed.port != 0 ? parsed.port : 443;
    final query = parsed.queryParameters;
    final name = Uri.decodeComponent(parsed.fragment.isNotEmpty ? parsed.fragment : "VLess Config");

    return V2RayConfigData(
      protocol: "vless",
      name: name,
      server: server,
      port: port,
      uuid: uuid,
      transport: query['type'] ?? "ws",
      path: query['path'] != null ? Uri.decodeComponent(query['path']!) : "/vless-ws",
      sni: query['sni'] ?? query['host'] ?? "",
      security: query['security'] ?? "tls",
    );
  }

  static V2RayConfigData? _parseTrojan(String uriStr) {
    final parsed = Uri.parse(uriStr);
    final password = parsed.userInfo;
    final server = parsed.host;
    final port = parsed.port != 0 ? parsed.port : 443;
    final query = parsed.queryParameters;
    final name = Uri.decodeComponent(parsed.fragment.isNotEmpty ? parsed.fragment : "Trojan Config");

    return V2RayConfigData(
      protocol: "trojan",
      name: name,
      server: server,
      port: port,
      uuid: password,
      transport: query['type'] ?? "ws",
      path: query['path'] != null ? Uri.decodeComponent(query['path']!) : "/trojan-ws",
      sni: query['sni'] ?? query['host'] ?? "",
      security: query['security'] ?? "tls",
    );
  }

  static V2RayConfigData? _parseShadowsocks(String uriStr) {
    final parsed = Uri.parse(uriStr);
    final server = parsed.host;
    final port = parsed.port != 0 ? parsed.port : 8388;
    final name = Uri.decodeComponent(parsed.fragment.isNotEmpty ? parsed.fragment : "Shadowsocks Config");

    return V2RayConfigData(
      protocol: "shadowsocks",
      name: name,
      server: server,
      port: port,
      uuid: parsed.userInfo,
      transport: "tcp",
      path: "",
      sni: "",
      security: "none",
    );
  }
}
