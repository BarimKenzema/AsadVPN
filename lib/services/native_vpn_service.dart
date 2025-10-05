import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'singbox_config.dart';

class ServerInfo {
  final String config;
  final String protocol;
  final int ping;
  final String name;
  ServerInfo({required this.config, required this.protocol, required this.ping, required this.name});
}

class NativeVPNService {
  static const MethodChannel _channel = MethodChannel('com.asad.vpn/vpn');

  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static bool isSubscriptionValid = false;

  static bool isConnected = false;
  static String? currentConnectedConfig;
  static int? currentConnectedPing;

  static List<ServerInfo> fastestServers = [];
  static List<ServerInfo> allPingableServers = [];
  static bool isScanning = false;
  static Timer? backgroundScanTimer;
  static StreamController<List<ServerInfo>> serversStreamController = StreamController<List<ServerInfo>>.broadcast();
  static StreamController<bool> connectionStateController = StreamController<bool>.broadcast();

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    currentSubscriptionLink = prefs.getString('subscription_link');
    if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
      await validateSubscription();
    }
  }

  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      isSubscriptionValid = false; return false;
    }
    try {
      final resp = await http.get(Uri.parse(currentSubscriptionLink!), headers: {'User-Agent':'AsadVPN/1.0'}).timeout(Duration(seconds: 15));
      if (resp.statusCode != 200) { isSubscriptionValid = false; return false; }
      var content = resp.body;
      try { if (!content.contains('://')) content = utf8.decode(base64.decode(content.trim())); } catch (_) {}
      final lines = content.split('\n').map((e)=>e.trim()).where((e)=>e.isNotEmpty && !e.startsWith('#')).toList();
      final vless = lines.where((e)=>e.toLowerCase().startsWith('vless://')).toList();
      configServers = vless.isNotEmpty ? vless : lines;
      isSubscriptionValid = configServers.isNotEmpty;
      return isSubscriptionValid;
    } catch (_) { isSubscriptionValid = false; return false; }
  }

  static Future<bool> saveSubscriptionLink(String link) async {
    final prefs = await SharedPreferences.getInstance();
    link = link.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'),'');
    if (!link.startsWith('http://') && !link.startsWith('https://')) return false;
    currentSubscriptionLink = link;
    await prefs.setString('subscription_link', link);
    final ok = await validateSubscription();
    if (!ok) { await prefs.remove('subscription_link'); currentSubscriptionLink=null; }
    return ok;
  }

  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    if (configServers.isEmpty) return {'success': false, 'error':'No servers'};
    isScanning = true; fastestServers.clear();
    final shuffled = List<String>.from(configServers)..shuffle(Random());
    final batch = shuffled.take(min(10, shuffled.length)).toList();
    final tests = batch.map((e)=>_test(e, 3)).toList();
    final res = await Future.wait(tests);
    final working = res.whereType<ServerInfo>().toList()..sort((a,b)=>a.ping.compareTo(b.ping));
    fastestServers = working; serversStreamController.add(fastestServers);
    isScanning = false;
    if (working.isNotEmpty) {
      return {'success':true,'server':working.first.config,'protocol':working.first.protocol,'ping':working.first.ping};
    }
    return {'success':false,'error':'No working servers'};
  }

  static Future<ServerInfo?> _test(String uri, int timeoutSec) async {
    try {
      final u = Uri.parse(uri.split('#').first);
      final host = u.host; int port = u.port;
      final qp = u.queryParameters;
      if (port <= 0) port = (qp['security']=='tls')?443:80;
      final sw = Stopwatch()..start();
      final sock = await Socket.connect(host, port, timeout: Duration(seconds: timeoutSec));
      sw.stop(); await sock.close();
      var ping = sw.elapsedMilliseconds; if (ping < 20) ping = 20 + Random().nextInt(30);
      final name = uri.contains('#') ? Uri.decodeComponent(uri.split('#').last) : host;
      return ServerInfo(config: uri, protocol: 'VLESS', ping: ping, name: name);
    } catch (_) { return null; }
  }

  static Future<bool> connect(String vlessUri, {int? ping}) async {
    try {
      final configJson = SingBoxConfig.vlessToConfig(vlessUri);
      final ok = await _channel.invokeMethod('startVPN', {'config': configJson});
      isConnected = ok; currentConnectedConfig = vlessUri; currentConnectedPing = ping;
      connectionStateController.add(ok); return ok;
    } catch (_) { isConnected=false; connectionStateController.add(false); return false; }
  }

  static Future<bool> disconnect() async {
    try {
      final ok = await _channel.invokeMethod('stopVPN');
      isConnected = false; currentConnectedConfig=null; currentConnectedPing=null;
      connectionStateController.add(false);
      fastestServers.clear(); allPingableServers.clear(); serversStreamController.add([]);
      return ok;
    } catch (_) { return false; }
  }
}