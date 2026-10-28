import 'dart:convert';
import '../models/template_model.dart';

class ConfigBuilder {
  /// Builds sing-box config from a cloud template, allowing member to provide their own server
  static String buildFromTemplate({
    required TemplateModel template,
    required String memberServer,
    required int memberPort,
    required String username,
    required String password,
  }) {
    final finalServer = memberServer.trim();
    final finalPort = memberPort > 0 ? memberPort : 443;
    final protocol = template.protocol.toLowerCase();
    final sni = template.sni ?? "";
    final payload = template.payload ?? "";

    return buildSsh(
      method: protocol.contains("ssl") || finalPort == 443 ? "ws_ssl" : "ws_direct",
      server: finalServer,
      port: finalPort,
      username: username,
      password: password,
      sni: sni,
      payload: payload,
    );
  }

  /// Builds sing-box config for any SSH method
  static String buildSsh({
    required String method, // 'direct', 'http_proxy', 'ssl_direct', 'ssl_payload', 'ws_direct', 'ws_ssl', 'slowdns'
    required String server,
    required int port,
    required String username,
    required String password,
    String sni = "",
    String payload = "",
    String remoteProxy = "",
  }) {
    Map<String, dynamic> proxyOutbound = {
      "type": "ssh",
      "tag": "proxy-out",
      "server": server,
      "server_port": port,
      "user": username,
      "password": password,
    };

    if (method == "ws_ssl" || method == "ssl_payload") {
      proxyOutbound["transport"] = {
        "type": "ws",
        "path": "/",
        "headers": {
          "Host": sni.isNotEmpty ? sni : server,
          "Upgrade": "websocket",
        }
      };
      proxyOutbound["tls"] = {
        "enabled": true,
        "server_name": sni.isNotEmpty ? sni : server,
        "insecure": true,
      };
    } else if (method == "ws_direct") {
      proxyOutbound["transport"] = {
        "type": "ws",
        "path": "/",
        "headers": {
          "Host": sni.isNotEmpty ? sni : server,
          "Upgrade": "websocket",
        }
      };
    } else if (method == "ssl_direct") {
      proxyOutbound["tls"] = {
        "enabled": true,
        "server_name": sni.isNotEmpty ? sni : server,
        "insecure": true,
      };
    } else if (method == "http_proxy" && remoteProxy.isNotEmpty) {
      final proxyParts = remoteProxy.split(":");
      final proxyHost = proxyParts[0];
      final proxyPort = proxyParts.length > 1 ? int.tryParse(proxyParts[1]) ?? 8080 : 8080;

      proxyOutbound["detour"] = "http-proxy-out";
      // We also add an http proxy outbound
      return _wrapSingBox(
        outbounds: [
          proxyOutbound,
          {
            "type": "http",
            "tag": "http-proxy-out",
            "server": proxyHost,
            "server_port": proxyPort,
          },
          {"type": "direct", "tag": "direct"},
          {"type": "block", "tag": "block"},
        ],
      );
    }

    return _wrapSingBox(outbounds: [
      proxyOutbound,
      {"type": "direct", "tag": "direct"},
      {"type": "block", "tag": "block"},
    ]);
  }

  /// Builds sing-box config for V2Ray / Xray (VMess, VLess, Trojan, Shadowsocks)
  static String buildV2Ray({
    required String protocol, // 'vmess', 'vless', 'trojan', 'shadowsocks'
    required String server,
    required int port,
    required String uuid, // or password
    String transport = "ws", // 'ws', 'grpc', 'tcp'
    String path = "/vmess-ws",
    String sni = "",
    String security = "tls", // 'none', 'tls', 'reality'
  }) {
    Map<String, dynamic> proxyOutbound = {
      "type": protocol.toLowerCase(),
      "tag": "proxy-out",
      "server": server,
      "server_port": port,
    };

    if (protocol.toLowerCase() == "vmess") {
      proxyOutbound["uuid"] = uuid;
      proxyOutbound["security"] = "auto";
      proxyOutbound["alter_id"] = 0;
    } else if (protocol.toLowerCase() == "vless") {
      proxyOutbound["uuid"] = uuid;
    } else if (protocol.toLowerCase() == "trojan") {
      proxyOutbound["password"] = uuid;
    } else if (protocol.toLowerCase() == "shadowsocks") {
      proxyOutbound["password"] = uuid;
      proxyOutbound["method"] = "aes-128-gcm";
    }

    if (security == "tls") {
      proxyOutbound["tls"] = {
        "enabled": true,
        "server_name": sni.isNotEmpty ? sni : server,
        "insecure": true,
      };
    }

    if (transport == "ws") {
      proxyOutbound["transport"] = {
        "type": "ws",
        "path": path.isNotEmpty ? path : "/",
        "headers": {
          "Host": sni.isNotEmpty ? sni : server,
        }
      };
    } else if (transport == "grpc") {
      proxyOutbound["transport"] = {
        "type": "grpc",
        "service_name": path.isNotEmpty ? path : "grpc-service",
      };
    }

    return _wrapSingBox(outbounds: [
      proxyOutbound,
      {"type": "direct", "tag": "direct"},
      {"type": "block", "tag": "block"},
    ]);
  }

  static String _wrapSingBox({required List<Map<String, dynamic>> outbounds}) {
    final singBoxConfig = {
      "log": {
        "level": "warn",
        "timestamp": true,
      },
      "dns": {
        "servers": [
          {"tag": "dns-remote", "address": "tcp://1.1.1.1"},
          {"tag": "dns-direct", "address": "local", "detour": "direct"},
        ]
      },
      "inbounds": [
        {
          "type": "tun",
          "tag": "tun-in",
          "interface_name": "izz-tun0",
          "inet4_address": "172.19.0.1/30",
          "auto_route": true,
          "strict_route": true,
          "stack": "system",
          "sniff": true,
        }
      ],
      "outbounds": outbounds,
      "route": {
        "rules": [
          {"protocol": "dns", "outbound": "dns-remote"},
          {"ip_is_private": true, "outbound": "direct"},
        ],
        "auto_detect_interface": true,
      }
    };

    return json.encode(singBoxConfig);
  }
}
