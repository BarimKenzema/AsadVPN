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
  final String config;
  final String protocol;
  final int ping;
  final String name;

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

  static StreamController<List<ServerInfo>> serversStreamController =
      StreamController<List<ServerInfo>>.broadcast();

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!kIsWeb) {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          androidId = androidInfo.id ?? 'unknown';
        }
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
    }
  }

  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      isSubscriptionValid = false;
      return false;
    }
    try {
      final resp = await http.get(Uri.parse(currentSubscriptionLink!),
          headers: {'User-Agent': 'AsadVPN/1.0'}).timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200) {
        isSubscriptionValid = false;
        return false;
      }

      var content = resp.body;

      if (content.contains('<!DOCTYPE')) {
        isSubscriptionValid = false;
        return false;
      }
      if (!content.contains('://')) {
        try {
          content = utf8.decode(base64.decode(content.trim()));
        } catch (_) {}
      }

      final lines = content
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();

      final vless = lines.where((l) => l.toLowerCase().startsWith('vless://')).toList();
      configServers = vless.isNotEmpty ? vless : lines;

      isSubscriptionValid = configServers.isNotEmpty;
      return isSubscriptionValid;
    } catch (e) {
      isSubscriptionValid = false;
      return false;
    }
  }

  static Future<bool> saveSubscriptionLink(String link) async {
    try {
      link = link.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
      if (!link.startsWith('http')) return false;
      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);

      final ok = await validateSubscription();
      if (!ok) {
        await prefs.remove('subscription_link');
        currentSubscriptionLink = null;
      }
      return ok;
    } catch (e) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    if (configServers.isEmpty) return {'success': false, 'error': 'No servers'};

    isScanning = true;
    fastestServers.clear();
    serversStreamController.add([]);

    final shuffled = List<String>.from(configServers)..shuffle(Random());
    final batch = shuffled.take(min(10, shuffled.length)).toList();

    final tests = batch.map((cfg) => _testServerWithPing(cfg, 3)).toList();
    final results = await Future.wait(tests);

    final working = results.whereType<ServerInfo>().toList()
      ..sort((a, b) => a.ping.compareTo(b.ping));
    fastestServers = working;
    serversStreamController.add(fastestServers);
    isScanning = false;

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

  static Future<ServerInfo?> _testServerWithPing(String uri, int timeoutSec) async {
    try {
      final name = _extractName(uri);
      final host = _extractHost(uri);
      var port = _extractPort(uri);
      if (host.isEmpty) return null;

      final sw = Stopwatch()..start();
      final socket = await Socket.connect(host, port, timeout: Duration(seconds: timeoutSec));
      sw.stop();
      await socket.close();
      var ping = sw.elapsedMilliseconds;
      if (ping < 20) ping = 20 + Random().nextInt(30);
      return ServerInfo(config: uri, protocol: 'VLESS', ping: ping, name: name);
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
      return u.port > 0 ? u.port : 443;
    } catch (_) { return 443; }
  }

  static String _extractName(String uri) {
    if (uri.contains('#')) {
      final tail = uri.split('#').last;
      try { return Uri.decodeComponent(tail); } catch (_) { return tail; }
    }
    return _extractHost(uri);
  }

  // DEFINITIVE V2Ray JSON generator using string templates
  static String generateV2RayConfig(String vlessUri) {
    try {
      final uri = Uri.parse(vlessUri.split('#').first);
      final qp = uri.queryParameters;

      final uuid = uri.userInfo;
      final address = uri.host;
      final port = uri.port > 0 ? uri.port : 443;
      final type = qp['type'] ?? 'tcp';
      final security = qp['security'] ?? 'none';
      final sni = qp['sni'] ?? address;
      final path = qp['path'] ?? '/';
      final hostHeader = qp['host'] ?? address;

      String tlsSettings = '';
      if (security == 'tls') {
        tlsSettings = '''
        ,"tlsSettings": {
          "serverName": "$sni",
          "allowInsecure": true
        }
        ''';
      }

      String transportSettings = '';
      if (type == 'ws') {
        transportSettings = '''
        ,"wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$hostHeader"
          }
        }
        ''';
      }

      final jsonString = '''
      {
        "log": { "loglevel": "warning" },
        "inbounds": [{
          "port": 10808,
          "protocol": "socks",
          "settings": { "auth": "noauth", "udp": true }
        }],
        "outbounds": [{
          "protocol": "vless",
          "settings": {
            "vnext": [{
              "address": "$address",
              "port": $port,
              "users": [{ "id": "$uuid", "encryption": "none" }]
            }]
          },
          "streamSettings": {
            "network": "$type",
            "security": "$security"
            $tlsSettings
            $transportSettings
          }
        }]
      }
      ''';
      return jsonString;
    } catch (e) {
      debugPrint("Error generating V2Ray config: $e");
      return '';
    }
  }

  static Future<bool> connect(String vlessUri) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      await flutterV2ray.requestPermission();

      final jsonConfig = generateV2RayConfig(vlessUri);
      if (jsonConfig.isEmpty) return false;

      await flutterV2ray.startV2Ray(
        remark: 'AsadVPN',
        config: jsonConfig,
        bypassSubnets: const [], // Route all traffic
      );

      isConnected = true;
      return true;
    } catch (e) {
      debugPrint('V2Ray connection error: $e');
      return false;
    }
  }

  static Future<void> disconnect() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        await flutterV2ray.stopV2Ray();
      }
      isConnected = false;
      fastestServers.clear();
      serversStreamController.add([]);
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }
  }
}