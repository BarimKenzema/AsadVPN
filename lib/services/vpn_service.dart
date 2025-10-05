import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray_client.dart';
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
      final newStatus = status.state == 'CONNECTED';
      if (isConnected != newStatus) {
        isConnected = newStatus;
        connectionStateController.add(isConnected);
      }
      debugPrint('V2Ray status: ${status.state}');
    },
  );

  static bool isConnected = false;
  static String? currentConnectedConfig;
  static int? currentConnectedPing;

  static bool isSubscriptionValid = false;
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = [];
  static List<ServerInfo> allPingableServers = [];
  static bool isScanning = false;
  static Timer? backgroundScanTimer;

  static StreamController<List<ServerInfo>> serversStreamController =
      StreamController<List<ServerInfo>>.broadcast();
  static StreamController<bool> connectionStateController =
      StreamController<bool>.broadcast();

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
    allPingableServers.clear();
    serversStreamController.add([]);

    final shuffled = List<String>.from(configServers)..shuffle(Random());
    final batch = shuffled.take(min(10, shuffled.length)).toList();

    final tests = batch.map((cfg) => _testServerWithPing(cfg, 5)).toList();
    final results = await Future.wait(tests);

    final working = results.whereType<ServerInfo>().toList()..sort((a, b) => a.ping.compareTo(b.ping));
    fastestServers = working;
    allPingableServers.addAll(working);
    serversStreamController.add(fastestServers);
    isScanning = false;

    if (working.isNotEmpty) {
      return {
        'success': true,
        'server': working.first.config,
        'ping': working.first.ping
      };
    }
    return {'success': false, 'error': 'No working servers'};
  }

  static Future<ServerInfo?> _testServerWithPing(String uri, int timeoutSec) async {
    try {
      final parser = V2ray.parseFromURL(uri);
      final configJson = parser.getFullConfiguration();
      
      final delay = await v2ray.getServerDelay(config: configJson, timeout: timeoutSec * 1000);

      if (delay != -1) {
        return ServerInfo(
          config: uri,
          protocol: 'VLESS',
          ping: delay,
          name: parser.remark.isNotEmpty ? parser.remark : parser.address,
        );
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  static void startBackgroundScanning() {
    stopBackgroundScanning();
    backgroundScanTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (allPingableServers.length >= 44 || configServers.isEmpty) {
        timer.cancel();
        backgroundScanTimer = null;
        return;
      }

      final untested = configServers.where((config) => !allPingableServers.any((server) => server.config == config)).toList();
      if (untested.isEmpty) {
        timer.cancel();
        backgroundScanTimer = null;
        return;
      }

      untested.shuffle(Random());
      final batch = untested.take(10).toList();
      final tests = batch.map((cfg) => _testServerWithPing(cfg, 2)).toList();
      final results = await Future.wait(tests);

      bool hasNewServers = false;
      for (var server in results.whereType<ServerInfo>()) {
        if (!allPingableServers.any((s) => s.config == server.config)) {
          allPingableServers.add(server);
          hasNewServers = true;
        }
      }

      if (hasNewServers) {
        allPingableServers.sort((a, b) => a.ping.compareTo(b.ping));
        serversStreamController.add(allPingableServers);
        debugPrint('BG Scan: ${allPingableServers.length} servers found');
      }
    });
  }

  static void stopBackgroundScanning() {
    backgroundScanTimer?.cancel();
    backgroundScanTimer = null;
  }
  
  static Future<bool> connect(String vlessUri, {int? ping}) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    
    if (isConnected && currentConnectedConfig != vlessUri) {
        await disconnect();
        await Future.delayed(const Duration(milliseconds: 500));
    }
    
    try {
      final parser = V2ray.parseFromURL(vlessUri);
      final configJson = parser.getFullConfiguration();
      
      if (await v2ray.requestPermission()) {
        await v2ray.startV2Ray(
          remark: parser.remark,
          config: configJson,
          proxyOnly: false,
          bypassSubnets: [],
        );
        
        await Future.delayed(const Duration(seconds: 1)); 
        if (isConnected) {
          currentConnectedConfig = vlessUri;
          currentConnectedPing = ping;
          startBackgroundScanning();
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('V2Ray connection error: $e');
      await disconnect();
      return false;
    }
  }

  static Future<void> disconnect() async {
    try {
      stopBackgroundScanning();
      await v2ray.stopV2Ray();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    } finally {
      isConnected = false;
      currentConnectedConfig = null;
      currentConnectedPing = null;
      connectionStateController.add(false);
      allPingableServers.clear();
      fastestServers.clear();
      serversStreamController.add([]);
    }
  }
}