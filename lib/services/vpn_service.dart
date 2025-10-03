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
        try {
          await flutterV2ray.initializeV2Ray();
        } catch (e) {
          print('V2Ray init error (non-fatal): $e');
        }
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
        
        // Show first config for debug
        if (allConfigs.isNotEmpty) {
          String firstConfig = allConfigs.first;
          if (firstConfig.length > 50) {
            print('First config: ${firstConfig.substring(0, 50)}...');
          } else {
            print('First config: $firstConfig');
          }
        }
        
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
      } else if (response.statusCode == 403) {
        print('ERROR: 403 Forbidden - Invalid subscription token');
        isSubscriptionValid = false;
        return false;
      } else if (response.statusCode == 404) {
        print('ERROR: 404 Not Found - Invalid URL');
        isSubscriptionValid = false;
        return false;
      } else {
        print('ERROR: Unexpected status code: ${response.statusCode}');
        isSubscriptionValid = false;
        return false;
      }
    } catch (e) {
      print('ERROR validating subscription: $e');
      print('Stack trace: ${e.toString()}');
      isSubscriptionValid = false;
    }
    
    return false;
  }
  
  // Save subscription link - WITH BETTER VALIDATION
  static Future<bool> saveSubscriptionLink(String link) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Clean the link
      link = link.trim();
      
      print('=== SAVING SUBSCRIPTION ===');
      print('Original input: "$link"');
      print('Length: ${link.length}');
      
      // Remove any invisible characters
      link = link.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
      print('After cleaning: "$link"');
      
      // Basic URL validation
      if (!link.startsWith('http://') && !link.startsWith('https://')) {
        print('ERROR: Link must start with http:// or https://');
        return false;
      }
      
      // Check if it's a pythonanywhere subscription
      if (!link.contains('pythonanywhere.com/sub/')) {
        print('ERROR: Not a pythonanywhere subscription link');
        print('Expected format: https://XXX.pythonanywhere.com/sub/TOKEN');
        return false;
      }
      
      // Extract and validate token
      var parts = link.split('/sub/');
      if (parts.length != 2 || parts[1].isEmpty) {
        print('ERROR: Invalid subscription format - missing token');
        return false;
      }
      
      String token = parts[1].split('?')[0].split('#')[0]; // Remove any query params
      print('Extracted token: $token');
      
      if (token.length < 10) {
        print('ERROR: Token seems too short');
        return false;
      }
      
      print('Validation passed, saving...');
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);
      
      // Now validate with the server
      print('Fetching configs from server...');
      bool isValid = await validateSubscription();
      
      if (!isValid) {
        print('Server validation failed - removing saved link');
        await prefs.remove('subscription_link');
        currentSubscriptionLink = null;
      }
      
      return isValid;
    } catch (e) {
      print('ERROR saving subscription: $e');
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
      
      // URL decode the name
      try {
        name = Uri.decodeComponent(name);
      } catch (e) {
        // Keep original if decode fails
      }
      
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
        String name = config.split('#').last;
        // URL decode the name
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
  
  // Convert VLESS URI to V2Ray JSON config
  static String _convertVlessToJson(String vlessUri) {
    try {
      // Parse VLESS URI
      Uri uri = Uri.parse(vlessUri);
      String uuid = uri.userInfo;
      String host = uri.host;
      int port = uri.port;
      
      // Extract parameters
      String security = uri.queryParameters['security'] ?? 'none';
      String type = uri.queryParameters['type'] ?? 'tcp';
      String sni = uri.queryParameters['sni'] ?? host;
      String fp = uri.queryParameters['fp'] ?? 'chrome';
      String alpn = uri.queryParameters['alpn'] ?? '';
      
      // Create V2Ray JSON config
      Map<String, dynamic> config = {
        "policy": {
          "system": {
            "statsOutboundUplink": true,
            "statsOutboundDownlink": true
          }
        },
        "log": {
          "access": "",
          "error": "",
          "loglevel": "warning"
        },
        "inbounds": [
          {
            "tag": "socks",
            "port": 10808,
            "protocol": "socks",
            "settings": {
              "auth": "noauth",
              "udp": true,
              "userLevel": 8
            },
            "sniffing": {
              "destOverride": ["http", "tls"],
              "enabled": true
            }
          },
          {
            "tag": "http",
            "port": 10809,
            "protocol": "http",
            "settings": {
              "userLevel": 8
            }
          }
        ],
        "outbounds": [
          {
            "tag": "proxy",
            "protocol": "vless",
            "settings": {
              "vnext": [
                {
                  "address": host,
                  "port": port,
                  "users": [
                    {
                      "id": uuid,
                      "alterId": 0,
                      "email": "t@t.tt",
                      "encryption": "none"
                    }
                  ]
                }
              ]
            },
            "streamSettings": {
              "network": type,
              "security": security,
            },
            "mux": {
              "enabled": false,
              "concurrency": -1
            }
          },
          {
            "tag": "direct",
            "protocol": "freedom",
            "settings": {}
          },
          {
            "tag": "block",
            "protocol": "blackhole",
            "settings": {
              "response": {
                "type": "http"
              }
            }
          }
        ],
        "routing": {
          "domainStrategy": "AsIs",
          "rules": [
            {
              "type": "field",
              "inboundTag": ["api"],
              "outboundTag": "api"
            }
          ]
        }
      };
      
      // Add TLS settings if needed
      if (security == 'tls') {
        config['outbounds'][0]['streamSettings']['tlsSettings'] = {
          "allowInsecure": false,
          "serverName": sni,
          "fingerprint": fp,
          "alpn": alpn.split(',').where((s) => s.isNotEmpty).toList()
        };
      }
      
      return jsonEncode(config);
    } catch (e) {
      print('Error converting VLESS to JSON: $e');
      return '';
    }
  }
  
  // Connect to VPN - REAL V2RAY CONNECTION
  static Future<bool> connect(String config) async {
    try {
      // Real V2Ray connection for Android
      if (!kIsWeb && Platform.isAndroid) {
        try {
          print('Requesting VPN permission...');
          
          // Request VPN permission first
          await flutterV2ray.requestPermission();
          
          print('Starting V2Ray with config...');
          
          // Convert VLESS URI to JSON if needed
          String jsonConfig = config;
          if (config.startsWith('vless://')) {
            jsonConfig = _convertVlessToJson(config);
            if (jsonConfig.isEmpty) {
              print('Failed to convert VLESS to JSON');
              return false;
            }
          }
          
          // Start V2Ray with JSON config
          await flutterV2ray.startV2Ray(
            remark: "AsadVPN Server",
            config: jsonConfig,
            bypassSubnets: ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"],
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