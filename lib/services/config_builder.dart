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
    final normalizedProtocol = protocol.toLowerCase();
    final normalizedTransport = transport.toLowerCase();
    final network = normalizedTransport == "grpc" ? "grpc" : (normalizedTransport == "tcp" ? "tcp" : "ws");
    final xrayOutbound = <String, dynamic>{
      "protocol": normalizedProtocol,
      "settings": <String, dynamic>{},
      "streamSettings": <String, dynamic>{
        "network": network,
        "security": security == "tls" ? "tls" : "none",
      },
    };

    if (normalizedProtocol == "vmess") {
      xrayOutbound["settings"] = {"vnext": [{"address": server, "port": port, "users": [{"id": uuid, "alterId": 0, "security": "auto"}]}]};
    } else if (normalizedProtocol == "vless") {
      xrayOutbound["settings"] = {"vnext": [{"address": server, "port": port, "users": [{"id": uuid, "encryption": "none"}]}]};
    } else if (normalizedProtocol == "trojan") {
      xrayOutbound["settings"] = {"servers": [{"address": server, "port": port, "password": uuid}]};
    } else if (normalizedProtocol == "shadowsocks") {
      xrayOutbound["protocol"] = "shadowsocks";
      xrayOutbound["settings"] = {"servers": [{"address": server, "port": port, "method": "aes-128-gcm", "password": uuid}]};
      (xrayOutbound["streamSettings"] as Map<String, dynamic>).clear();
    } else {
      throw ArgumentError("Unsupported Xray protocol: $protocol");
    }

    final stream = xrayOutbound["streamSettings"] as Map<String, dynamic>;
    if (network == "ws") {
      stream["wsSettings"] = {"path": path.isNotEmpty ? path : "/", "host": sni.isNotEmpty ? sni : server};
    } else if (network == "grpc") {
      stream["grpcSettings"] = {"serviceName": path.isNotEmpty ? path : "grpc-service"};
    }
    if (security == "tls") {
      stream["tlsSettings"] = {"serverName": sni.isNotEmpty ? sni : server};
    }

    return _wrapXray(outbound: xrayOutbound);

  }

  static String _wrapXray({required Map<String, dynamic> outbound}) {
    return json.encode({
      "log": {"loglevel": "warning"},
      "inbounds": [{
        "tag": "socks-in",
        "listen": "127.0.0.1",
        "port": 10808,
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": true}
      }],
      "outbounds": [outbound, {"protocol": "freedom", "tag": "direct"}],
      "routing": {"domainStrategy": "AsIs", "rules": []}
    });
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
