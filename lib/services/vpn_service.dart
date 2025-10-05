import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
  static final V2ray v2ray = V2ray(
    onStatusChanged: (status) {
      _updateConnectionState(status);
    },
  );

  static bool isConnected = false;
  static bool isSubscriptionValid = false;
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = [];
  static bool isScanning = false;
  static String? currentConnectedConfig;
  static int? currentConnectedPing;

  static final StreamController<List<ServerInfo>> serversStreamController =
      StreamController<List<ServerInfo>>.broadcast();
  static final StreamController<bool> connectionStateController =
      StreamController<bool>.broadcast();

  static void _updateConnectionState(V2RayStatus status) {
    final newIsConnected = status.state == 'CONNECTED';
    if (isConnected != newIsConnected) {
      isConnected = newIsConnected;
      connectionStateController.add(isConnected);
      debugPrint('V2Ray status changed: ${status.state}');
    }
  }

  static Future<void> init() async {
    try {
      await v2ray.initialize(
        notificationIconResourceName: "ic_launcher",
        notificationIconResourceType: "mipmap",
      );
      final prefs = await SharedPreferences.getInstance();
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

      if (resp.statusCode != 200 || resp.body.contains('<!DOCTYPE')) {
        isSubscriptionValid = false;
        return false;
      }

      var content = resp.body;
      if (!content.contains('://')) {
        try {
          content = utf8.decode(base64.decode(content.trim()));
        } catch (_) {}
      }

      final lines = content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
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

    final tests = batch.map((cfg) => _testServerWithPing(cfg)).toList();
    final results = await Future.wait(tests);

    final working = results.whereType<ServerInfo>().toList()..sort((a, b) => a.ping.compareTo(b.ping));
    fastestServers = working;
    serversStreamController.add(fastestServers);
    isScanning = false;

    if (working.isNotEmpty) {
      return {'success': true, 'server': working.first.config, 'ping': working.first.ping};
    }
    return {'success': false, 'error': 'No working servers'};
  }

  static Future<ServerInfo?> _testServerWithPing(String uri) async {
    try {
      final parser = V2ray.parseFromURL(uri);
      final delay = await v2ray.getServerDelay(config: parser.getFullConfiguration());

      if (delay != -1) {
        return ServerInfo(config: uri, protocol: 'VLESS', ping: delay, name: parser.remark);
      }
      return null;
    } catch (e) {
      return null;
    }
  }
  
  static Future<bool> connect({required String vlessUri, int? ping}) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      if (isConnected) {
        await disconnect();
        await Future.delayed(const Duration(milliseconds: 500)); // Give time for disconnection
      }
      
      final parser = V2ray.parseFromURL(vlessUri);
      
      if (await v2ray.requestPermission()) {
        await v2ray.startV2Ray(
          remark: parser.remark,
          config: parser.getFullConfiguration(),
          proxyOnly: false,
          bypassSubnets: [],
        );
        currentConnectedConfig = vlessUri;
        currentConnectedPing = ping;
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('V2Ray connection error: $e');
      return false;
    }
  }

  static Future<void> disconnect() async {
    try {
      await v2ray.stopV2Ray();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    } finally {
      isConnected = false;
      currentConnectedConfig = null;
      currentConnectedPing = null;
      fastestServers.clear();
      serversStreamController.add([]);
      connectionStateController.add(false);
    }
  }
}
