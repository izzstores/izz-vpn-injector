import 'dart:convert';
import '../models/template_model.dart';

class ConfigBuilder {
  /// Builds a complete runtime sing-box config JSON from a cloud template
  static String buildFromTemplate({
    required TemplateModel template,
    required String username,
    required String password,
  }) {
    final protocol = template.protocol.toLowerCase();
    final sni = template.sni ?? "";
    final payload = template.payload ?? "";

    Map<String, dynamic> proxyOutbound;

    if (protocol.contains("ssh")) {
      proxyOutbound = {
        "type": "ssh",
        "tag": "proxy-out",
        "server": template.server,
        "server_port": template.port,
        "user": username,
        "password": password,
      };

      // If WebSocket transport with SNI/Host header
      if (sni.isNotEmpty || payload.isNotEmpty) {
        final hostHeader = sni.isNotEmpty ? sni : template.server;
        proxyOutbound["transport"] = {
          "type": "ws",
          "path": "/",
          "headers": {
            "Host": hostHeader,
            "Upgrade": "websocket",
          }
        };
      }
    } else if (protocol.contains("vmess")) {
      proxyOutbound = {
        "type": "vmess",
        "tag": "proxy-out",
        "server": template.server,
        "server_port": template.port,
        "uuid": password, // For Xray, password field holds UUID
        "security": "auto",
        "alter_id": 0,
      };

      if (template.port == 443 || protocol.contains("tls")) {
        proxyOutbound["tls"] = {
          "enabled": true,
          "server_name": sni.isNotEmpty ? sni : template.server,
          "insecure": true,
        };
      }

      if (protocol.contains("grpc")) {
        proxyOutbound["transport"] = {
          "type": "grpc",
          "service_name": payload.isNotEmpty ? payload : "vmess-grpc",
        };
      } else {
        proxyOutbound["transport"] = {
          "type": "ws",
          "path": payload.isNotEmpty ? payload : "/vmess",
          "headers": {
            "Host": sni.isNotEmpty ? sni : template.server,
          }
        };
      }
    } else if (protocol.contains("vless")) {
      proxyOutbound = {
        "type": "vless",
        "tag": "proxy-out",
        "server": template.server,
        "server_port": template.port,
        "uuid": password,
      };

      if (template.port == 443 || protocol.contains("tls")) {
        proxyOutbound["tls"] = {
          "enabled": true,
          "server_name": sni.isNotEmpty ? sni : template.server,
          "insecure": true,
        };
      }

      if (protocol.contains("grpc")) {
        proxyOutbound["transport"] = {
          "type": "grpc",
          "service_name": payload.isNotEmpty ? payload : "vless-grpc",
        };
      } else {
        proxyOutbound["transport"] = {
          "type": "ws",
          "path": payload.isNotEmpty ? payload : "/vless",
          "headers": {
            "Host": sni.isNotEmpty ? sni : template.server,
          }
        };
      }
    } else if (protocol.contains("trojan")) {
      proxyOutbound = {
        "type": "trojan",
        "tag": "proxy-out",
        "server": template.server,
        "server_port": template.port,
        "password": password,
        "tls": {
          "enabled": true,
          "server_name": sni.isNotEmpty ? sni : template.server,
          "insecure": true,
        }
      };

      if (protocol.contains("grpc")) {
        proxyOutbound["transport"] = {
          "type": "grpc",
          "service_name": payload.isNotEmpty ? payload : "trojan-grpc",
        };
      } else {
        proxyOutbound["transport"] = {
          "type": "ws",
          "path": payload.isNotEmpty ? payload : "/trojan-ws",
          "headers": {
            "Host": sni.isNotEmpty ? sni : template.server,
          }
        };
      }
    } else {
      // Default direct fallback
      proxyOutbound = {
        "type": "direct",
        "tag": "proxy-out",
      };
    }

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
      "outbounds": [
        proxyOutbound,
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
      ],
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

  /// Builds a config for Custom / Manual Mode
  static String buildCustom({
    required String protocol,
    required String server,
    required int port,
    required String username,
    required String password,
    required String sni,
    required String payload,
  }) {
    final customTemplate = TemplateModel(
      id: 99999,
      name: "Custom Config",
      category: "Custom",
      protocol: protocol,
      server: server,
      port: port,
      encryptedConfig: "",
      sni: sni,
      payload: payload,
    );

    return buildFromTemplate(
      template: customTemplate,
      username: username,
      password: password,
    );
  }
}
