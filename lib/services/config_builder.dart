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
    final protocol = template.protocol.toLowerCase();
    final sni = template.sni ?? "";
    final payload = template.payload ?? "";
    final remoteProxy = template.proxy ?? "";

    final bool enableSsl = template.enableSsl;
    final bool enableProxy = template.enableProxy || remoteProxy.isNotEmpty;
    final bool enablePayload = template.enablePayload || payload.isNotEmpty;
    final int finalPort = memberPort > 0 ? memberPort : (enableSsl ? 443 : 80);

    if (protocol.contains("ssh")) {
      return buildSsh(
        server: finalServer,
        port: finalPort,
        username: username,
        password: password,
        enableSsl: enableSsl,
        sni: sni,
        enablePayload: enablePayload,
        payload: payload,
        enableProxy: enableProxy,
        remoteProxy: remoteProxy,
      );
    } else {
      // V2Ray protocols (vmess, vless, trojan, shadowsocks)
      final v2proto = protocol.replaceFirst("-ws", "").replaceFirst("-grpc", "");
      final transport = protocol.contains("grpc") ? "grpc" : "ws";
      final isTls = finalPort == 443 || sni.isNotEmpty;
      return buildV2Ray(
        protocol: v2proto,
        server: finalServer,
        port: finalPort,
        uuid: username.isNotEmpty ? username : "00000000-0000-0000-0000-000000000000",
        transport: transport,
        path: payload.isNotEmpty ? payload : "/$v2proto-ws",
        sni: sni,
        security: isTls ? "tls" : "none",
      );
    }
  }

  /// Builds sing-box config for SSH Inject (Dark Tunnel style)
  static String buildSsh({
    required String server,
    required int port,
    required String username,
    required String password,
    bool enableSsl = true,
    String sni = "",
    bool enablePayload = true,
    String payload = "",
    bool enableProxy = false,
    String remoteProxy = "",
    String? method, // legacy fallback
  }) {
    // If legacy method string was passed, map it
    if (method != null) {
      if (method == "ws_ssl" || method == "ssl_payload") {
        enableSsl = true;
        enablePayload = true;
        enableProxy = false;
      } else if (method == "ssl_direct") {
        enableSsl = true;
        enablePayload = false;
        enableProxy = false;
      } else if (method == "ws_direct") {
        enableSsl = false;
        enablePayload = true;
        enableProxy = false;
      } else if (method == "http_proxy") {
        enableSsl = false;
        enablePayload = true;
        enableProxy = true;
      } else if (method == "direct") {
        enableSsl = false;
        enablePayload = false;
        enableProxy = false;
      }
    }

    Map<String, dynamic> proxyOutbound = {
      "type": "ssh",
      "tag": "proxy-out",
      "server": server,
      "server_port": port,
      "user": username,
      "password": password,
      "_enable_ssl": enableSsl,
      "_sni": sni,
      "_enable_payload": enablePayload,
      "_payload": payload,
      "_enable_proxy": enableProxy,
      "_remote_proxy": remoteProxy,
    };

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
    required String uuid,
    String transport = "ws", // 'ws', 'grpc', 'tcp'
    String path = "/vmess-ws",
    String sni = "",
    String security = "tls", // 'none', 'tls'
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

    // sing-box does not allow TLS/transport fields on Shadowsocks.
    if (protocol.toLowerCase() != "shadowsocks" && security == "tls") {
      proxyOutbound["tls"] = {
        "enabled": true,
        "server_name": sni.isNotEmpty ? sni : server,
        "insecure": true,
      };
    }

    if (protocol.toLowerCase() != "shadowsocks" && transport == "ws") {
      proxyOutbound["transport"] = {
        "type": "ws",
        "path": path.isNotEmpty ? path : "/",
        "headers": {
          "Host": sni.isNotEmpty ? sni : server,
        }
      };
    } else if (protocol.toLowerCase() != "shadowsocks" && transport == "grpc") {
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
          "type": "mixed",
          "tag": "mixed-in",
          "listen": "127.0.0.1",
          "listen_port": 10808,
          "sniff": true,
          "sniff_override_destination": true,
        }
      ],
      "outbounds": outbounds,
      "route": {
        "rules": [
          {"protocol": "dns", "outbound": "direct"},
          {"ip_is_private": true, "outbound": "direct"},
        ],
        "final": "proxy-out",
        // Do not use auto_detect_interface on Android. sing-box attempts
        // netlink access, which is blocked for regular Android apps.
      }
    };

    return json.encode(singBoxConfig);
  }
}
