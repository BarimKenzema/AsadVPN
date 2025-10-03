import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';

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
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = [];
  static List<ServerInfo> allPingableServers = [];
  static bool isConnected = false;
  static String? currentSubscriptionLink;
  static bool isSubscriptionValid = false;
  static bool isScanning = false;
  static Timer? backgroundScanTimer;
  static StreamController<List<ServerInfo>> serversStreamController = StreamController<List<ServerInfo>>.broadcast();
  
  // V2Ray instance
  static FlutterV2ray flutterV2ray = FlutterV2ray(
    onStatusChanged: (status) {
      isConnected = status.state == 'CONNECTED';
    },
  );
  
  // Initialize
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Get device ID for tracking
      if (!kIsWeb) {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          androidId = androidInfo.id ?? 'unknown';
        } else {
          androidId = 'ios_device';
        }
      } else {
        androidId = 'web_test_${DateTime.now().millisecondsSinceEpoch}';
      }
      
      // Initialize V2Ray
      if (!kIsWeb && Platform.isAndroid) {
        await flutterV2ray.initializeV2Ray();
      }
      
      // Load saved subscription link
      currentSubscriptionLink = prefs.getString('subscription_link');
      
      // If we have a saved subscription, validate it
      if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
        await validateSubscription();
      }
    } catch (e) {
      print('Init error: $e');
      androidId = 'fallback_${DateTime.now().millisecondsSinceEpoch}';
    }
  }
  
  // Validate and fetch configs from subscription link - VLESS ONLY
  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      isSubscriptionValid = false;
      return false;
    }
    
    try {
      print('Validating subscription: $currentSubscriptionLink');
      
      // Fetch configs from the subscription link
      final response = await http.get(Uri.parse(currentSubscriptionLink!))
          .timeout(Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        String content = response.body;
        
        // Check if subscription is expired
        if (content.contains('SUBSCRIPTION_EXPIRED')) {
          print('Subscription expired');
          isSubscriptionValid = false;
          configServers = [];
          return false;
        }
        
        // Parse ALL configs first
        var allConfigs = content
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .where((line) => !line.startsWith('#'))
            .toList();
        
        // FILTER ONLY VLESS CONFIGS
        configServers = allConfigs
            .where((config) => config.toLowerCase().startsWith('vless://'))
            .toList();
        
        print('Loaded ${configServers.length} VLESS servers (filtered from ${allConfigs.length} total)');
        isSubscriptionValid = configServers.isNotEmpty;
        return isSubscriptionValid;
      } else if (response.statusCode == 403) {
        print('Invalid subscription token');
        isSubscriptionValid = false;
        return false;
      }
    } catch (e) {
      print('Error validating subscription: $e');
      isSubscriptionValid = false;
    }
    
    return false;
  }
  
  // Save subscription link
  static Future<bool> saveSubscriptionLink(String link) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Clean the link
      link = link.trim();
      
      // Basic validation
      if (!link.contains('pythonanywhere.com/sub/')) {
        return false;
      }
      
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);
      
      // Validate the new subscription
      bool isValid = await validateSubscription();
      return isValid;
    } catch (e) {
      print('Error saving subscription: $e');
      return false;
    }
  }
  
  // Smart server selection with batch scanning (10 VLESS servers, 3 seconds)
  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    if (configServers.isEmpty) {
      return {'success': false, 'error': 'No servers available'};
    }
    
    isScanning = true;
    fastestServers.clear();
    
    // ALL servers are already VLESS (filtered in validateSubscription)
    List<String> vlessServers = List.from(configServers);
    vlessServers.shuffle(Random());
    
    // Test random batch of 10 VLESS servers
    List<String> batchToTest = vlessServers.take(min(10, vlessServers.length)).toList();
    
    print('Testing ${batchToTest.length} VLESS servers...');
    
    // Test batch for 3 seconds
    List<Future<ServerInfo?>> tests = [];
    for (String config in batchToTest) {
      tests.add(_testServerWithPing(config, 3));
    }
    
    // Wait for results
    final results = await Future.wait(tests);
    
    // Filter successful pings and sort by speed
    List<ServerInfo> workingServers = results
        .where((server) => server != null)
        .cast<ServerInfo>()
        .toList();
    
    workingServers.sort((a, b) => a.ping.compareTo(b.ping));
    
    // Update fastest servers list
    fastestServers = workingServers.take(5).toList();
    serversStreamController.add(fastestServers);
    
    print('Found ${workingServers.length} working VLESS servers');
    
    // Select best (fastest) VLESS server
    ServerInfo? bestServer = workingServers.isNotEmpty ? workingServers.first : null;
    
    isScanning = false;
    
    if (bestServer != null) {
      return {
        'success': true,
        'server': bestServer.config,
        'protocol': bestServer.protocol,
        'ping': bestServer.ping,
        'candidates': workingServers.length
      };
    }
    
    return {'success': false, 'error': 'No working servers found'};
  }
  
  // Background scanning for 44 servers (VLESS only)
  static void startBackgroundScanning() {
    if (backgroundScanTimer != null) return;
    
    backgroundScanTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
      if (allPingableServers.length >= 44) {
        timer.cancel();
        backgroundScanTimer = null;
        print('Found 44 pingable VLESS servers, stopping background scan');
        return;
      }
      
      // Test random batch of servers
      List<String> untested = configServers.where((config) {
        return !allPingableServers.any((server) => server.config == config);
      }).toList();
      
      if (untested.isEmpty) return;
      
      untested.shuffle(Random());
      List<String> batch = untested.take(10).toList();
      
      List<Future<ServerInfo?>> tests = [];
      for (String config in batch) {
        tests.add(_testServerWithPing(config, 2));
      }
      
      final results = await Future.wait(tests);
      
      for (var server in results) {
        if (server != null && !allPingableServers.any((s) => s.config == server.config)) {
          allPingableServers.add(server);
        }
      }
      
      // Sort by ping
      allPingableServers.sort((a, b) => a.ping.compareTo(b.ping));
      
      print('Background scan: ${allPingableServers.length} pingable VLESS servers found');
    });
  }
  
  // Test server with ping measurement
  static Future<ServerInfo?> _testServerWithPing(String config, int timeoutSeconds) async {
    try {
      String protocol = _getProtocol(config);
      String name = _extractServerName(config);
      
      if (kIsWeb) {
        // Simulate ping for web
        return ServerInfo(
          config: config,
          protocol: protocol,
          ping: Random().nextInt(200) + 20,
          name: name,
        );
      }
      
      // Extract host
      String host = _extractHost(config);
      if (host.isEmpty || host == '127.0.0.1') return null;
      
      // Measure ping time
      final stopwatch = Stopwatch()..start();
      
      final result = await InternetAddress.lookup(host)
          .timeout(Duration(seconds: timeoutSeconds));
      
      stopwatch.stop();
      
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        return ServerInfo(
          config: config,
          protocol: protocol,
          ping: stopwatch.elapsedMilliseconds,
          name: name,
        );
      }
    } catch (e) {
      // Server not reachable
    }
    return null;
  }
  
  // Extract host from config
  static String _extractHost(String config) {
    try {
      if (config.contains('://') && config.contains('@')) {
        String afterProtocol = config.split('://')[1];
        if (afterProtocol.contains('@')) {
          String hostPart = afterProtocol.split('@')[1];
          return hostPart.split(':')[0].split('?')[0].split('#')[0];
        }
      }
    } catch (e) {}
    return '';
  }
  
  // Extract server name from config
  static String _extractServerName(String config) {
    try {
      if (config.contains('#')) {
        return config.split('#').last;
      }
      return _extractHost(config);
    } catch (e) {
      return 'Unknown';
    }
  }
  
  // Get protocol type from config string
  static String _getProtocol(String config) {
    if (config.toLowerCase().startsWith('vless://')) return 'VLESS';
    if (config.toLowerCase().startsWith('vmess://')) return 'VMESS';
    if (config.toLowerCase().startsWith('trojan://')) return 'Trojan';
    if (config.toLowerCase().startsWith('ss://')) return 'Shadowsocks';
    return 'Unknown';
  }
  
  // Connect to VPN - REAL V2RAY CONNECTION
  static Future<bool> connect(String config) async {
    try {
      // Real V2Ray connection for Android
      if (!kIsWeb && Platform.isAndroid) {
        try {
          // Start V2Ray with config
          await flutterV2ray.startV2Ray(
            remark: "AsadVPN VLESS Server",
            config: config,
            blocked: [],
            bypass: ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"],
          );
          
          isConnected = true;
          
          // Start background scanning after connection
          startBackgroundScanning();
          
          // Save last config
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_config', config);
          
          return true;
        } catch (e) {
          print('V2Ray connection error: $e');
          return false;
        }
      }
      
      // Web fallback simulation
      if (kIsWeb) {
        await Future.delayed(Duration(seconds: 2));
        isConnected = true;
        startBackgroundScanning();
        return true;
      }
      
      return false;
    } catch (e) {
      print('Connection error: $e');
      return false;
    }
  }
  
  // Disconnect VPN
  static Future<void> disconnect() async {
    try {
      backgroundScanTimer?.cancel();
      backgroundScanTimer = null;
      
      if (!kIsWeb && Platform.isAndroid) {
        try {
          // Stop V2Ray
          await flutterV2ray.stopV2Ray();
        } catch (e) {
          print('V2Ray disconnect error: $e');
        }
      }
      
      await Future.delayed(Duration(milliseconds: 500));
      isConnected = false;
      fastestServers.clear();
      serversStreamController.add([]);
    } catch (e) {
      print('Disconnect error: $e');
    }
  }
  
  // Cleanup
  static void dispose() {
    backgroundScanTimer?.cancel();
    serversStreamController.close();
  }
}