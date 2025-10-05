import 'dart:convert';

class SingBoxConfig {
  static String vlessToConfig(String vlessUri) {
    final v = _parseVless(vlessUri);

    final config = {
      "log": {"level": "info", "timestamp": true},
      "dns": {
        "servers": [
          {"tag": "google", "address": "8.8.8.8"},
          {"tag": "cloudflare", "address": "1.1.1.1"}
        ],
        "rules": [],
        "final": "google"
      },
      "inbounds": [
        {
          "type": "tun",
          "tag": "tun-in",
          "auto_route": true,
          "strict_route": false,
          "sniff": true,
          "stack": "gvisor",
          "inet4_address": "172.19.0.1/30"
        }
      ],
      "outbounds": [
        _buildVlessOutbound(v),
        {"type": "direct", "tag": "direct"},
        {
          "type": "block",
          "tag": "block",
          "options": {"response": {"type": "http"}}
        }
      ],
      "route": {
        "auto_detect_interface": true,
        "rules": [
          {"ip_cidr": ["224.0.0.0/3", "ff00::/8"], "outbound": "block"},
          {
            "ip_cidr": [
              "10.0.0.0/8",
              "172.16.0.0/12",
              "192.168.0.0/16",
              "127.0.0.0/8",
              "::1/128",
              "fc00::/7",
              "fe80::/10"
            ],
            "outbound": "direct"
          }
        ],
        "final": "proxy"
      }
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  static Map<String, dynamic> _buildVlessOutbound(_Vless v) {
    final out = <String, dynamic>{
      "type": "vless",
      "tag": "proxy",
      "server": v.host,
      "server_port": v.port,
      "uuid": v.uuid
    };

    if (v.security == 'tls') {
      out["tls"] = {
        "enabled": true,
        "server_name": v.sni ?? v.host,
        "insecure": true,
        if (v.alpn != null && v.alpn!.isNotEmpty) "alpn": v.alpn!.split(',')
      };
    }
    out["transport"] = _transport(v);
    if (v.flow != null && v.flow!.isNotEmpty && v.flow != 'none') {
      out["flow"] = v.flow;
    }
    return out;
  }

  static Map<String, dynamic> _transport(_Vless v) {
    switch (v.type) {
      case 'ws':
        return {
          "type": "ws",
          "path": v.path ?? "/",
          if (v.hostHeader != null && v.hostHeader!.isNotEmpty)
            "headers": {"Host": v.hostHeader}
        };
      case 'grpc':
        return {
          "type": "grpc",
          "service_name": v.serviceName ?? "",
          "idle_timeout": "15s",
          "permit_without_stream": true
        };
      case 'tcp':
      default:
        if (v.headerType == 'http') {
          return {
            "type": "http",
            if (v.hostHeader != null && v.hostHeader!.isNotEmpty)
              "host": [v.hostHeader],
            if (v.path != null && v.path!.isNotEmpty) "path": v.path
          };
        }
        return {"type": "tcp"};
    }
  }

  static _Vless _parseVless(String s) {
    final full = s.split('#').first;
    final uri = Uri.parse(full);
    if (uri.scheme.toLowerCase() != 'vless') {
      throw ArgumentError('Only vless:// supported here');
    }
    final qp = uri.queryParameters;
    final type = qp['type'] ?? 'tcp';
    final security = qp['security'] ?? 'tls';
    var port = uri.port;
    if (port <= 0) port = (security == 'tls') ? 443 : (type == 'ws' ? 80 : 443);

    return _Vless(
      uuid: uri.userInfo,
      host: uri.host,
      port: port,
      type: type,
      security: security,
      sni: qp['sni'] ?? qp['serverName'],
      alpn: qp['alpn'],
      flow: qp['flow'],
      path: qp['path'],
      hostHeader: qp['host'],
      headerType: qp['headerType'],
      serviceName: qp['serviceName'],
    );
  }
}

class _Vless {
  final String uuid, host, type, security;
  final int port;
  final String? sni, alpn, flow, path, hostHeader, headerType, serviceName;
  _Vless({
    required this.uuid,
    required this.host,
    required this.port,
    required this.type,
    required this.security,
    this.sni,
    this.alpn,
    this.flow,
    this.path,
    this.hostHeader,
    this.headerType,
    this.serviceName,
  });
}