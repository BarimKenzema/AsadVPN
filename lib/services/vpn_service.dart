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
    debugPrint('🔵 V2Ray status update: ${status.state}');
    if (isConnected != newIsConnected) {
      isConnected = newIsConnected;
      connectionStateController.add(isConnected);
      debugPrint('🔵 V2Ray connection state changed to: ${status.state}');
    }
  }

  static Future<void> init() async {
    try {
      debugPrint('🔵 Initializing VPN Service...');
      
      await v2ray.initialize(
        notificationIconResourceName: "ic_launcher",
        notificationIconResourceType: "mipmap",
      );
      debugPrint('🔵 V2Ray initialized');
      
      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      debugPrint('🔵 Loaded subscription link: ${currentSubscriptionLink != null ? "EXISTS (${currentSubscriptionLink!.substring(0, min(50, currentSubscriptionLink!.length))}...)" : "NULL"}');
      
      if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
        debugPrint('🔵 Validating subscription...');
        final valid = await validateSubscription();
        debugPrint('🔵 Subscription valid: $valid, servers found: ${configServers.length}');
      } else {
        debugPrint('🔵 No subscription link found');
      }
    } catch (e, stack) {
      debugPrint('❌ Init error: $e');
      debugPrint('Stack: $stack');
    }
  }

  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      debugPrint('❌ Subscription link is null or empty');
      isSubscriptionValid = false;
      return false;
    }
    
    try {
      debugPrint('🔵 Fetching subscription from: ${currentSubscriptionLink!.substring(0, min(50, currentSubscriptionLink!.length))}...');
      
      final resp = await http.get(
        Uri.parse(currentSubscriptionLink!),
        headers: {'User-Agent': 'AsadVPN/1.0'}
      ).timeout(const Duration(seconds: 20));

      debugPrint('🔵 Response status: ${resp.statusCode}');
      debugPrint('🔵 Response length: ${resp.body.length} bytes');
      debugPrint('🔵 First 100 chars: ${resp.body.substring(0, min(100, resp.body.length))}');

      if (resp.statusCode != 200 || resp.body.contains('<!DOCTYPE')) {
        debugPrint('❌ Invalid response (HTML or bad status)');
        isSubscriptionValid = false;
        return false;
      }

      var content = resp.body;
      if (!content.contains('://')) {
        debugPrint('🔵 Content appears to be base64, decoding...');
        try {
          content = utf8.decode(base64.decode(content.trim()));
          debugPrint('🔵 Decoded length: ${content.length}');
        } catch (e) {
          debugPrint('❌ Failed to decode base64: $e');
        }
      }

      final lines = content.split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      
      debugPrint('🔵 Total lines after filtering: ${lines.length}');
      
      final vless = lines.where((l) => l.toLowerCase().startsWith('vless://')).toList();
      final vmess = lines.where((l) => l.toLowerCase().startsWith('vmess://')).toList();
      final trojan = lines.where((l) => l.toLowerCase().startsWith('trojan://')).toList();
      
      debugPrint('🔵 Found: ${vless.length} VLESS, ${vmess.length} VMESS, ${trojan.length} Trojan');
      
      configServers = vless.isNotEmpty ? vless : (vmess.isNotEmpty ? vmess : (trojan.isNotEmpty ? trojan : lines));
      debugPrint('🔵 Using ${configServers.length} servers');
      
      if (configServers.isNotEmpty) {
        debugPrint('🔵 First server: ${configServers.first.substring(0, min(80, configServers.first.length))}...');
      }
      
      isSubscriptionValid = configServers.isNotEmpty;
      return isSubscriptionValid;
    } catch (e, stack) {
      debugPrint('❌ Validation error: $e');
      debugPrint('Stack: $stack');
      isSubscriptionValid = false;
      return false;
    }
  }

  static Future<bool> saveSubscriptionLink(String link) async {
    try {
      debugPrint('🔵 Saving subscription link...');
      link = link.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
      
      if (!link.startsWith('http')) {
        debugPrint('❌ Link does not start with http');
        return false;
      }
      
      debugPrint('🔵 Link: ${link.substring(0, min(50, link.length))}...');
      
      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);
      
      debugPrint('🔵 Saved to SharedPreferences, verifying...');
      final saved = prefs.getString('subscription_link');
      debugPrint('🔵 Verification read: ${saved != null ? "SUCCESS" : "FAILED"}');
      
      final ok = await validateSubscription();
      if (!ok) {
        debugPrint('❌ Validation failed, removing subscription');
        await prefs.remove('subscription_link');
        currentSubscriptionLink = null;
      } else {
        debugPrint('✅ Subscription saved and validated successfully');
      }
      return ok;
    } catch (e, stack) {
      debugPrint('❌ Save error: $e');
      debugPrint('Stack: $stack');
      return false;
    }
  }

  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    debugPrint('🔵 scanAndSelectBestServer called');
    debugPrint('🔵 configServers count: ${configServers.length}');
    
    if (configServers.isEmpty) {
      debugPrint('❌ No servers available');
      return {'success': false, 'error': 'No servers'};
    }
    
    isScanning = true;
    fastestServers.clear();
    serversStreamController.add([]);

    final shuffled = List<String>.from(configServers)..shuffle(Random());
    final batch = shuffled.take(min(10, shuffled.length)).toList();
    
    debugPrint('🔵 Testing ${batch.length} servers...');

    final tests = batch.map((cfg) => _testServerWithPing(cfg)).toList();
    final results = await Future.wait(tests);

    final working = results.whereType<ServerInfo>().toList()
      ..sort((a, b) => a.ping.compareTo(b.ping));
    
    debugPrint('🔵 Found ${working.length} working servers');
    
    fastestServers = working;
    serversStreamController.add(fastestServers);
    isScanning = false;

    if (working.isNotEmpty) {
      debugPrint('✅ Best server: ${working.first.name} (${working.first.ping}ms)');
      return {'success': true, 'server': working.first.config, 'ping': working.first.ping};
    }
    
    debugPrint('❌ No working servers found');
    return {'success': false, 'error': 'No working servers'};
  }

  static Future<ServerInfo?> _testServerWithPing(String uri) async {
    try {
      debugPrint('🔵 Testing server: ${uri.substring(0, min(50, uri.length))}...');
      
      final parser = V2ray.parseFromURL(uri);
      final config = parser.getFullConfiguration();
      
      debugPrint('🔵 Generated config for ${parser.remark}');
      
      final delay = await v2ray.getServerDelay(config: config);
      
      debugPrint('🔵 ${parser.remark}: ${delay}ms');

      if (delay != -1) {
        return ServerInfo(
          config: uri,
          protocol: 'VLESS',
          ping: delay,
          name: parser.remark
        );
      }
      return null;
    } catch (e) {
      debugPrint('❌ Test error: $e');
      return null;
    }
  }
  
  static Future<bool> connect({required String vlessUri, int? ping}) async {
    if (kIsWeb || !Platform.isAndroid) {
      debugPrint('❌ Not Android or is Web');
      return false;
    }
    
    try {
      debugPrint('🔵 Connecting to VPN...');
      
      if (isConnected) {
        debugPrint('🔵 Already connected, disconnecting first...');
        await disconnect();
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      final parser = V2ray.parseFromURL(vlessUri);
      final config = parser.getFullConfiguration();
      
      debugPrint('🔵 Requesting VPN permission...');
      final hasPermission = await v2ray.requestPermission();
      debugPrint('🔵 Permission granted: $hasPermission');
      
      if (hasPermission) {
        debugPrint('🔵 Starting V2Ray with config for: ${parser.remark}');
        
        await v2ray.startV2Ray(
          remark: parser.remark,
          config: config,
          proxyOnly: false,
          bypassSubnets: [],
        );
        
        currentConnectedConfig = vlessUri;
        currentConnectedPing = ping;
        
        debugPrint('✅ V2Ray started successfully');
        return true;
      } else {
        debugPrint('❌ VPN permission denied');
      }
      return false;
    } catch (e, stack) {
      debugPrint('❌ Connection error: $e');
      debugPrint('Stack: $stack');
      return false;
    }
  }

  static Future<void> disconnect() async {
    try {
      debugPrint('🔵 Disconnecting VPN...');
      await v2ray.stopV2Ray();
      debugPrint('✅ Disconnected');
    } catch (e) {
      debugPrint('❌ Disconnect error: $e');
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
