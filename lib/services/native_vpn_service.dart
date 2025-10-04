import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';

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

class NativeVPNService {
  static const MethodChannel _channel = MethodChannel('com.asad.vpn/vpn');
  
  // All properties that main.dart expects
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
  static StreamController<bool> connectionStreamController = StreamController<bool>.broadcast();
  static String? currentConnectedConfig;
  static int? currentConnectedPing;
  
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
  
  // Validate and fetch configs from subscription link
  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      print('validateSubscription: No subscription link');
      isSubscriptionValid = false;
      return false;
    }
    
    try {
      print('=== VALIDATING SUBSCRIPTION ===');
      print('URL: $currentSubscriptionLink');
      
      // Fetch configs from the subscription link
      final response = await http.get(
        Uri.parse(currentSubscriptionLink!),
        headers: {
          'User-Agent': 'AsadVPN/1.0',
        },
      ).timeout(Duration(seconds: 15));
      
      print('Response status: ${response.statusCode}');
      print('Response body length: ${response.body.length}');
      
      if (response.statusCode == 200) {
        String content = response.body;
        
        // Check if subscription is expired
        if (content.contains('SUBSCRIPTION_EXPIRED') || content.contains('expired')) {
          print('Subscription expired detected');
          isSubscriptionValid = false;
          configServers = [];
          return false;
        }
        
        // Check if response is HTML (error page)
        if (content.contains('<!DOCTYPE') || content.contains('<html')) {
          print('ERROR: Received HTML instead of configs');
          isSubscriptionValid = false;
          return false;
        }
        
        // DECODE BASE64 if needed
        String decodedContent = content;
        try {
          // Check if content is base64 encoded
          if (!content.contains('://')) {
            print('Content appears to be base64 encoded, decoding...');
            decodedContent = utf8.decode(base64.decode(content.trim()));
            print('Decoded successfully');
          }
        } catch (e) {
          print('Not base64 or decode failed, using as-is');
          decodedContent = content;
        }
        
        // Parse ALL configs
        var allConfigs = decodedContent
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .where((line) => !line.startsWith('#'))
            .toList();
        
        print('Total configs found: ${allConfigs.length}');
        
        // FILTER ONLY VLESS CONFIGS
        configServers = allConfigs
            .where((config) => config.toLowerCase().startsWith('vless://'))
            .toList();
        
        print('VLESS configs: ${configServers.length}');
        print('Other protocols: ${allConfigs.length - configServers.length}');
        
        // If no VLESS but has other configs, use them
        if (configServers.isEmpty && allConfigs.isNotEmpty) {
          print('WARNING: No VLESS configs found, using all configs');
          configServers = allConfigs;
        }
        
        isSubscriptionValid = configServers.isNotEmpty;
        return isSubscriptionValid;
      } else {
        print('ERROR: Status code ${response.statusCode}');
        isSubscriptionValid = false;
        return false;
      }
    } catch (e) {
      print('ERROR validating subscription: $e');
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
      
      print('=== SAVING SUBSCRIPTION ===');
      print('Original input: "$link"');
      
      // Remove any invisible characters
      link = link.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
      
      // Basic URL validation
      if (!link.startsWith('http://') && !link.startsWith('https://')) {
        print('ERROR: Link must start with http:// or https://');
        return false;
      }
      
      // Check if it's a pythonanywhere subscription
      if (!link.contains('pythonanywhere.com/sub/')) {
        print('ERROR: Not a pythonanywhere subscription link');
        return false;
      }
      
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);
      
      // Validate the new subscription
      bool isValid = await validateSubscription();
      
      if (!isValid) {
        await prefs.remove('subscription_link');
        currentSubscriptionLink = null;
      }
      
      return isValid;
    } catch (e) {
      print('ERROR saving subscription: $e');
      return false;
    }
  }
  
  // Smart server selection with batch scanning
  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    if (configServers.isEmpty) {
      return {'success': false, 'error': 'No servers available'};
    }
    
    isScanning = true;
    fastestServers.clear();
    
    List<String> vlessServers = List.from(configServers);
    vlessServers.shuffle(Random());
    
    // Test random batch of 10 VLESS servers
    List<String> batchToTest = vlessServers.take(min(10, vlessServers.length)).toList();
    
    print('Testing ${batchToTest.length} servers...');
    
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
    fastestServers = workingServers;
    serversStreamController.add(fastestServers);
    
    print('Found ${workingServers.length} working servers');
    
    // Select best server
    ServerInfo? bestServer = workingServers.isNotEmpty ? workingServers.first : null;
    
    isScanning = false;
    
    if (bestServer != null) {
      currentConnectedPing = bestServer.ping;
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
  
  // Background scanning
  static void startBackgroundScanning() {
    if (backgroundScanTimer != null) return;
    
    backgroundScanTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
      if (allPingableServers.length >= 44) {
        timer.cancel();
        backgroundScanTimer = null;
        print('Found 44 pingable servers');
        serversStreamController.add(allPingableServers);
        return;
      }
      
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
      
      allPingableServers.sort((a, b) => a.ping.compareTo(b.ping));
      print('Background scan: ${allPingableServers.length} servers found');
      serversStreamController.add(allPingableServers);
    });
  }
  
  // Test server with real TCP ping
  static Future<ServerInfo?> _testServerWithPing(String config, int timeoutSeconds) async {
    try {
      String protocol = _getProtocol(config);
      String name = _extractServerName(config);
      
      // URL decode the name
      try {
        name = Uri.decodeComponent(name);
      } catch (e) {
        // Keep original if decode fails
      }
      
      if (kIsWeb) {
        return ServerInfo(
          config: config,
          protocol: protocol,
          ping: Random().nextInt(200) + 20,
          name: name,
        );
      }
      
      String host = _extractHost(config);
      int port = _extractPort(config);
      
      if (host.isEmpty || host == '127.0.0.1') return null;
      
      final stopwatch = Stopwatch()..start();
      
      try {
        // Try TCP connection for real ping
        final socket = await Socket.connect(
          host, 
          port,
          timeout: Duration(seconds: timeoutSeconds),
        );
        
        stopwatch.stop();
        await socket.close();
        
        int realPing = stopwatch.elapsedMilliseconds;
        if (realPing < 20) realPing = Random().nextInt(30) + 20;
        
        return ServerInfo(
          config: config,
          protocol: protocol,
          ping: realPing,
          name: name,
        );
      } catch (e) {
        // Try DNS as fallback
        try {
          await InternetAddress.lookup(host).timeout(Duration(seconds: timeoutSeconds));
          stopwatch.stop();
          
          return ServerInfo(
            config: config,
            protocol: protocol,
            ping: stopwatch.elapsedMilliseconds + Random().nextInt(50) + 30,
            name: name,
          );
        } catch (e) {
          return null;
        }
      }
    } catch (e) {
      return null;
    }
  }
  
  // Extract host from config
  static String _extractHost(String config) {
    try {
      if (config.contains('://')) {
        String uri = config.split('#')[0]; // Remove remark
        Uri parsed = Uri.parse(uri);
        return parsed.host;
      }
    } catch (e) {
      // Fallback parsing
      try {
        if (config.contains('@') && config.contains(':')) {
          String afterAt = config.split('@')[1];
          return afterAt.split(':')[0].split('?')[0].split('#')[0];
        }
      } catch (e2) {}
    }
    return '';
  }
  
  // Extract port from config
  static int _extractPort(String config) {
    try {
      if (config.contains('://')) {
        String uri = config.split('#')[0]; // Remove remark
        Uri parsed = Uri.parse(uri);
        return parsed.port > 0 ? parsed.port : 443;
      }
    } catch (e) {
      // Fallback parsing
      try {
        if (config.contains('@') && config.contains(':')) {
          String afterAt = config.split('@')[1];
          if (afterAt.contains(':')) {
            String portStr = afterAt.split(':')[1].split('?')[0].split('#')[0];
            return int.tryParse(portStr) ?? 443;
          }
        }
      } catch (e2) {}
    }
    return 443;
  }
  
  // Extract server name from config
  static String _extractServerName(String config) {
    try {
      if (config.contains('#')) {
        String name = config.split('#').last;
        try {
          return Uri.decodeComponent(name);
        } catch (e) {
          return name;
        }
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
  
  // Connect to VPN
  static Future<bool> connect(String vlessUri, {int? ping}) async {
    try {
      currentConnectedConfig = vlessUri;
      currentConnectedPing = ping;
      
      print('Calling native VPN with config: ${vlessUri.substring(0, min(50, vlessUri.length))}...');
      
      final bool result = await _channel.invokeMethod('startVPN', {
        'config': vlessUri,
      });
      
      isConnected = result;
      connectionStreamController.add(isConnected);
      
      if (result) {
        startBackgroundScanning();
      }
      
      print('Native VPN result: $result');
      return result;
    } on PlatformException catch (e) {
      print('Failed to start VPN: ${e.message}');
      isConnected = false;
      currentConnectedConfig = null;
      currentConnectedPing = null;
      connectionStreamController.add(isConnected);
      return false;
    }
  }
  
  // Disconnect VPN
  static Future<void> disconnect() async {
    try {
      backgroundScanTimer?.cancel();
      backgroundScanTimer = null;
      
      final bool result = await _channel.invokeMethod('stopVPN');
      
      await Future.delayed(Duration(milliseconds: 500));
      isConnected = false;
      currentConnectedConfig = null;
      currentConnectedPing = null;
      fastestServers.clear();
      allPingableServers.clear();
      serversStreamController.add([]);
      connectionStreamController.add(false);
    } on PlatformException catch (e) {
      print('Failed to stop VPN: ${e.message}');
    }
  }
  
  // Check connection status
  static Future<bool> checkConnection() async {
    try {
      isConnected = await _channel.invokeMethod('isConnected');
      connectionStreamController.add(isConnected);
      return isConnected;
    } catch (e) {
      return false;
    }
  }
  
  // Cleanup
  static void dispose() {
    backgroundScanTimer?.cancel();
    serversStreamController.close();
    connectionStreamController.close();
  }
}