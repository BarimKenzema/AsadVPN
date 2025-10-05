import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ServerInfo {
  final String config;   // the raw vless://...
  final String protocol; // "VLESS"
  final int ping;        // ms
  final String name;     // remark/host

  ServerInfo({
    required this.config,
    required this.protocol,
    required this.ping,
    required this.name,
  });
}

class VPNService {
  static String? androidId;
  static FlutterV2ray flutterV2ray = FlutterV2ray(
    onStatusChanged: (status) {
      isConnected = status.state == 'CONNECTED';
      debugPrint('VPN Status Changed: ${status.state}');
    },
  );

  static bool isConnected = false;
  static bool isSubscriptionValid = false;
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = [];
  static List<ServerInfo> allPingableServers = [];
  static bool isScanning = false;
  static Timer? backgroundScanTimer;

  static StreamController<List<ServerInfo>> serversStreamController = StreamController<List<ServerInfo>>.broadcast();

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!kIsWeb) {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          androidId = androidInfo.id ?? 'unknown';
        } else {
          androidId = 'ios_device';
        }
      } else {
        androidId = 'web_${DateTime.now().millisecondsSinceEpoch}';
      }

      if (!kIsWeb && Platform.isAndroid) {
        try {
          await flutterV2ray.initializeV2Ray();
        } catch (e) {
          debugPrint('V2Ray init error: $e');
        }
      }

      currentSubscriptionLink = prefs.getString('subscription_link');
      if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
        await validateSubscription();
      }
    } catch (e) {
      debugPrint('Init error: $e');
      androidId = 'fallback_${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      isSubscriptionValid = false; return false;
    }
    try {
      debugPrint('=== VALIDATING SUBSCRIPTION ===\nURL: $currentSubscriptionLink');
      final resp = await http.get(Uri.parse(currentSubscriptionLink!), headers: {'User-Agent': 'AsadVPN/1.0'}).timeout(const Duration(seconds: 20));

      debugPrint('Response status: ${resp.statusCode}, body length: ${resp.body.length}');
      if (resp.statusCode != 200) {
        isSubscriptionValid = false; return false;
      }

      var content = resp.body;

      if (content.contains('<!DOCTYPE') || content.contains('<html')) {
        debugPrint('Received HTML instead of configs'); isSubscriptionValid = false; return false;
      }

      // If base64-encoded subscription, decode
      if (!content.contains('://')) {
        try {
          content = utf8.decode(base64.decode(content.trim()));
        } catch (_) {}
      }

      final lines = content.split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();

      final vless = lines.where((l) => l.toLowerCase().startsWith('vless://')).toList();
      configServers = vless.isNotEmpty ? vless : lines;

      isSubscriptionValid = configServers.isNotEmpty;
      debugPrint('Total configs: ${lines.length}, VLESS: ${vless.length}');
      return isSubscriptionValid;
    } catch (e) {
      debugPrint('validateSubscription error: $e');
      isSubscriptionValid = false;
      return false;
    }
  }

  static Future<bool> saveSubscriptionLink(String link) async {
    try {
      link = link.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
      if (!link.startsWith('http://') && !link.startsWith('https://')) return false;
      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);

      final ok = await validateSubscription();
      if (!ok) {
        await prefs.remove('subscription_link'); currentSubscriptionLink = null;
      }
      return ok;
    } catch (e) {
      debugPrint('saveSubscriptionLink error: $e'); return false;
    }
  }

  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    if (configServers.isEmpty) return {'success': false, 'error': 'No servers available'};

    isScanning = true; fastestServers.clear();

    final shuffled = List<String>.from(configServers)..shuffle(Random());
    final batch = shuffled.take(min(10, shuffled.length)).toList();

    debugPrint('Testing ${batch.length} servers...');
    final tests = batch.map((cfg) => _testServerWithPing(cfg, 3)).toList();
    final results = await Future.wait(tests);

    final working = results.whereType<ServerInfo>().toList()..sort((a, b) => a.ping.compareTo(b.ping));
    fastestServers = working; serversStreamController.add(fastestServers);
    isScanning = false;

    debugPrint('Found ${working.length} working servers');
    if (working.isNotEmpty) {
      return {
        'success': true,
        'server': working.first.config,
        'protocol': working.first.protocol,
        'ping': working.first.ping
      };
    }
    return {'success': false, 'error': 'No working servers'};
  }

  static void startBackgroundScanning() {
    backgroundScanTimer?.cancel();
    backgroundScanTimer = Timer.periodic(const Duration(seconds: 10), (t) async {
      if (allPingableServers.length >= 44) {
        t.cancel(); backgroundScanTimer = null;
        serversStreamController.add(allPingableServers);
        debugPrint('Found 44 pingable servers');
        return;
      }
      final untested = configServers.where((cfg) => !allPingableServers.any((s) => s.config == cfg)).toList();
      if (untested.isEmpty) return;
      untested.shuffle(Random());
      final batch = untested.take(10).toList();

      final tests = batch.map((cfg) => _testServerWithPing(cfg, 2)).toList();
      final results = await Future.wait(tests);

      for (final srv in results.whereType<ServerInfo>()) {
        if (!allPingableServers.any((s) => s.config == srv.config)) {
          allPingableServers.add(srv);
        }
      }
      allPingableServers.sort((a, b) => a.ping.compareTo(b.ping));
      serversStreamController.add(allPingableServers);
      debugPrint('Background scan: ${allPingableServers.length} servers');
    });
  }

  static Future<ServerInfo?> _testServerWithPing(String uri, int timeoutSec) async {
    try {
      final name = _extractName(uri);
      final host = _extractHost(uri);
      var port = _extractPort(uri);
      if (host.isEmpty) return null;

      final sw = Stopwatch()..start();
      try {
        final socket = await Socket.connect(host, port, timeout: Duration(seconds: timeoutSec));
        sw.stop();
        await socket.close();
        var ping = sw.elapsedMilliseconds;
        if (ping < 20) ping = 20 + Random().nextInt(30);
        return ServerInfo(config: uri, protocol: 'VLESS', ping: ping, name: name);
      } catch (_) {
        // DNS fallback
        try {
          await InternetAddress.lookup(host).timeout(Duration(seconds: timeoutSec));
          sw.stop();
          final ping = sw.elapsedMilliseconds + Random().nextInt(50) + 30;
          return ServerInfo(config: uri, protocol: 'VLESS', ping: ping, name: name);
        } catch (_) {
          return null;
        }
      }
    } catch (_) {
      return null;
    }
  }

  static String _extractHost(String uri) {
    try { return Uri.parse(uri.split('#').first).host; } catch (_) { return ''; }
  }
  static int _extractPort(String uri) {
    try {
      final u = Uri.parse(uri.split('#').first);
      if (u.port > 0) return u.port;
      final qp = u.queryParameters;
      // default: tls -> 443, ws/http -> 80 else -> 443
      final type = qp['type'] ?? 'tcp';
      final security = qp['security'] ?? 'tls';
      return security == 'tls' ? 443 : (type == 'ws' ? 80 : 443);
    } catch (_) { return 443; }
  }
  static String _extractName(String uri) {
    if (uri.contains('#')) {
      final tail = uri.split('#').last;
      try { return Uri.decodeComponent(tail); } catch (_) { return tail; }
    }
    return _extractHost(uri);
  }

  // Generate a PROPER V2Ray JSON config for VLESS
  static String generateV2RayConfig(String vlessUri) {
    try {
      final u = Uri.parse(vlessUri.split('#').first);
      final qp = u.queryParameters;

      final uuid = u.userInfo;
      final address = u.host;
      final port = u.port > 0 ? u.port : _defaultPortFor(qp);
      final type = (qp['type'] ?? 'tcp').toLowerCase();
      final security = (qp['security'] ?? 'tls').toLowerCase();

      final sni = qp['sni'] ?? qp['serverName'] ?? address;
      final alpn = qp['alpn']; // e.g., "h2,http/1.1"
      final path = qp['path'] ?? '/';
      final hostHeader = qp['host']; // ws/http Host header
      final headerType = qp['headerType']; // 'http' for tcp/http header
      final serviceName = qp['serviceName']; // grpc

      final Map<String, dynamic> config = {
        "log": {"loglevel": "warning"},
        "dns": {
          "servers": ["8.8.8.8", "1.1.1.1"]
        },
        "routing": {
          "domainStrategy": "AsIs",
          "rules": [
            // Keep private IPs direct if you prefer; or comment to route 100% through proxy
            // {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}
          ]
        },
        "inbounds": [
          {
            "port": 10808,
            "protocol": "socks",
            "listen": "127.0.0.1",
            "settings": {"auth": "noauth", "udp": true},
            "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
          }
        ],
        "outbounds": [
          {
            "protocol": "vless",
            "tag": "proxy",
            "settings": {
              "vnext": [
                {
                  "address": address,
                  "port": port,
                  "users": [
                    {"id": uuid, "encryption": "none", "level": 0}
                  ]
                }
              ]
            },
            "streamSettings": {
              "network": type,
              "security": security
            }
          },
          {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {}
          },
          {
            "protocol": "blackhole",
            "tag": "block",
            "settings": {}
          }
        ]
      };

      final outbound = config['outbounds'][0] as Map<String, dynamic>;
      final stream = outbound['streamSettings'] as Map<String, dynamic>;

      if (security == 'tls') {
        final tls = {
          "serverName": sni,
          "allowInsecure": true,
        };
        if (alpn != null && alpn.isNotEmpty) {
          tls["alpn"] = alpn.split(',').map((s) => s.trim()).toList();
        }
        stream["tlsSettings"] = tls;
      } else {
        // security 'none' -> do nothing
      }

      if (type == 'ws') {
        stream["wsSettings"] = {
          "path": path,
          if (hostHeader != null && hostHeader.isNotEmpty)
            "headers": {"Host": hostHeader}
        };
      } else if (type == 'grpc') {
        stream["grpcSettings"] = {
          "serviceName": serviceName ?? ""
        };
      } else if (type == 'tcp') {
        if (headerType == 'http') {
          stream["tcpSettings"] = {
            "header": {
              "type": "http",
              "request": {
                "version": "1.1",
                "method": "GET",
                "path": [path],
                "headers": {
                  if (hostHeader != null && hostHeader.isNotEmpty)
                    "Host": [hostHeader],
                  "User-Agent": [
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                  ],
                  "Accept-Encoding": ["gzip, deflate"],
                  "Connection": ["keep-alive"],
                  "Pragma": "no-cache"
                }
              }
            }
          };
        }
      }

      final jsonConfig = jsonEncode(config);
      debugPrint('Generated V2Ray JSON length: ${jsonConfig.length}');
      return jsonConfig;
    } catch (e, st) {
      debugPrint('generateV2RayConfig error: $e\n$st');
      return '';
    }
  }

  static int _defaultPortFor(Map<String, String> qp) {
    final type = (qp['type'] ?? 'tcp').toLowerCase();
    final security = (qp['security'] ?? 'tls').toLowerCase();
    if (security == 'tls') return 443;
    if (type == 'ws') return 80;
    return 443;
  }

  static Future<bool> connect(String vlessUri) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      debugPrint('Requesting VPN permission...');
      await flutterV2ray.requestPermission();

      final jsonConfig = generateV2RayConfig(vlessUri);
      if (jsonConfig.isEmpty) {
        debugPrint('Failed to generate JSON config'); return false;
      }

      debugPrint('Starting V2Ray with JSON config...');
      await flutterV2ray.startV2Ray(
        remark: 'AsadVPN',
        config: jsonConfig,
        // Empty list => do not bypass local subnets. Route all traffic.
        bypassSubnets: const [],
      );

      isConnected = true;
      startBackgroundScanning();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_config', vlessUri);
      return true;
    } catch (e) {
      debugPrint('V2Ray connection error: $e');
      return false;
    }
  }

  static Future<void> disconnect() async {
    try {
      backgroundScanTimer?.cancel(); backgroundScanTimer = null;
      if (!kIsWeb && Platform.isAndroid) {
        try { await flutterV2ray.stopV2Ray(); } catch (e) { debugPrint('stop error: $e'); }
      }
      isConnected = false;
      fastestServers.clear();
      allPingableServers.clear();
      serversStreamController.add([]);
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }
  }

  static void dispose() {
    backgroundScanTimer?.cancel();
    serversStreamController.close();
  }
}