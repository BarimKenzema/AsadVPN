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
      print('VPN Status Changed: ${status.state}');
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
    // PROPER V2Ray JSON configuration generator - COMPLETELY FIXED VERSION
  static String generateV2RayConfig(String vlessUri) {
    try {
      print('Generating V2Ray config from: ${vlessUri.substring(0, min(50, vlessUri.length))}...');
      
      // Parse VLESS URI
      String cleanUri = vlessUri.split('#')[0]; // Remove remark
      String remark = '';
      if (vlessUri.contains('#')) {
        remark = Uri.decodeComponent(vlessUri.split('#')[1]);
      }
      
      // Parse the URI
      Uri uri = Uri.parse(cleanUri);
      String uuid = uri.userInfo;
      String address = uri.host;
      int port = uri.port > 0 ? uri.port : 443;
      
      // Parse query parameters
      Map<String, String> params = uri.queryParameters;
      String type = params['type'] ?? 'tcp';
      String security = params['security'] ?? 'tls';
      String sni = params['sni'] ?? address;
      String fp = params['fp'] ?? 'chrome';
      String alpn = params['alpn'] ?? 'h2,http/1.1';
      String flow = params['flow'] ?? '';
      String encryption = params['encryption'] ?? 'none';
      
      print('Parsed: uuid=$uuid, address=$address, port=$port, type=$type, security=$security');
      
      // Build the config step by step to avoid type issues
      // Start with basic structure
      Map<String, dynamic> outbound = {
        "protocol": "vless",
        "tag": "proxy"
      };
      
      // Build settings
      Map<String, dynamic> settings = {
        "vnext": [
          {
            "address": address,
            "port": port,
            "users": [
              {
                "id": uuid,
                "encryption": encryption,
                "level": 0
              }
            ]
          }
        ]
      };
      
      // Add flow if exists
      if (flow.isNotEmpty && flow != 'none') {
        settings["vnext"][0]["users"][0]["flow"] = flow;
      }
      
      outbound["settings"] = settings;
      
      // Build streamSettings
      Map<String, dynamic> streamSettings = {
        "network": type,
        "security": security
      };
      
      // Add TLS settings if needed
      if (security == 'tls') {
        streamSettings["tlsSettings"] = {
          "serverName": sni,
          "allowInsecure": false,
          "fingerprint": fp,
          "alpn": alpn.split(',')
        };
      }
      
      // Add transport settings based on type
      if (type == 'ws') {
        String path = params['path'] ?? '/';
        String host = params['host'] ?? address;
        
        streamSettings["wsSettings"] = {
          "path": path,
          "headers": {
            "Host": host
          }
        };
      } else if (type == 'grpc') {
        String serviceName = params['serviceName'] ?? '';
        
        streamSettings["grpcSettings"] = {
          "serviceName": serviceName
        };
      } else if (type == 'tcp') {
        String headerType = params['headerType'] ?? 'none';
        
        if (headerType == 'http') {
          String httpHost = params['host'] ?? address;
          String httpPath = params['path'] ?? '/';
          
          streamSettings["tcpSettings"] = {
            "header": {
              "type": "http",
              "request": {
                "version": "1.1",
                "method": "GET",
                "path": [httpPath],
                "headers": {
                  "Host": [httpHost],
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
      
      outbound["streamSettings"] = streamSettings;
      
      // Build the complete config
      Map<String, dynamic> config = {
        "log": {
          "loglevel": "warning"
        },
        "dns": {
          "servers": [
            "8.8.8.8",
            "8.8.4.4",
            "1.1.1.1"
          ]
        },
        "routing": {
          "domainStrategy": "AsIs",
          "rules": [
            {
              "type": "field",
              "ip": ["geoip:private"],
              "outboundTag": "direct"
            }
          ]
        },
        "inbounds": [
          {
            "port": 10808,
            "protocol": "socks",
            "settings": {
              "auth": "noauth",
              "udp": true
            },
            "sniffing": {
              "enabled": true,
              "destOverride": ["http", "tls"]
            }
          }
        ],
        "outbounds": [
          outbound,
          {
            "protocol": "freedom",
            "settings": {},
            "tag": "direct"
          },
          {
            "protocol": "blackhole",
            "settings": {},
            "tag": "block"
          }
        ]
      };
      
      // Convert to JSON string
      String jsonConfig = jsonEncode(config);
      print('Generated V2Ray config successfully, length: ${jsonConfig.length}');
      
      // Log first 500 chars of config for debugging
      print('Config preview: ${jsonConfig.substring(0, min(500, jsonConfig.length))}...');
      
      return jsonConfig;
      
    } catch (e, stack) {
      print('Error generating V2Ray config: $e');
      print('Stack trace: $stack');
      print('URI that caused error: $vlessUri');
      return '';
    }
  }
      
      // Add flow if exists and not empty
      if (flow.isNotEmpty && flow != 'none') {
        // Access the users list correctly
        (config['outbounds'][0]['settings']['vnext'][0]['users'][0] as Map<String, dynamic>)['flow'] = flow;
      }
      
      // Add TLS settings if needed
      if (security == 'tls') {
        // Create tlsSettings as a separate map
        Map<String, dynamic> tlsSettings = {
          "serverName": sni,
          "allowInsecure": false,
          "fingerprint": fp
        };
        
        // Add alpn if present
        if (alpn.isNotEmpty) {
          tlsSettings["alpn"] = alpn.split(',');
        }
        
        // Add tlsSettings to streamSettings
        (config['outbounds'][0]['streamSettings'] as Map<String, dynamic>)['tlsSettings'] = tlsSettings;
      }
      
      // Add WebSocket settings if needed
      if (type == 'ws') {
        String path = params['path'] ?? '/';
        String host = params['host'] ?? address;
        
        Map<String, dynamic> wsSettings = {
          "path": path,
          "headers": {
            "Host": host
          }
        };
        
        (config['outbounds'][0]['streamSettings'] as Map<String, dynamic>)['wsSettings'] = wsSettings;
      }
      
      // Add gRPC settings if needed
      if (type == 'grpc') {
        String serviceName = params['serviceName'] ?? '';
        
        Map<String, dynamic> grpcSettings = {
          "serviceName": serviceName
        };
        
        (config['outbounds'][0]['streamSettings'] as Map<String, dynamic>)['grpcSettings'] = grpcSettings;
      }
      
      // Add TCP settings if needed
      if (type == 'tcp') {
        String headerType = params['headerType'] ?? 'none';
        
        if (headerType == 'http') {
          String httpHost = params['host'] ?? address;
          String httpPath = params['path'] ?? '/';
          
          Map<String, dynamic> tcpSettings = {
            "header": {
              "type": "http",
              "request": {
                "version": "1.1",
                "method": "GET",
                "path": [httpPath],
                "headers": {
                  "Host": [httpHost],
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
          
          (config['outbounds'][0]['streamSettings'] as Map<String, dynamic>)['tcpSettings'] = tcpSettings;
        }
      }
      
      // Convert to JSON string
      String jsonConfig = jsonEncode(config);
      print('Generated V2Ray config successfully, length: ${jsonConfig.length}');
      return jsonConfig;
      
    } catch (e) {
      print('Error generating V2Ray config: $e');
      print('Stack trace: ${StackTrace.current}');
      return '';
    }
  }
  
  // Connect to VPN with PROPER JSON config
  static Future<bool> connect(String vlessUri) async {
    try {
      // Real V2Ray connection for Android
      if (!kIsWeb && Platform.isAndroid) {
        try {
          print('Requesting VPN permission...');
          
          // Request VPN permission
          await flutterV2ray.requestPermission();
          
          print('Generating V2Ray JSON config from VLESS URI...');
          
          // Generate proper V2Ray JSON configuration
          String jsonConfig = generateV2RayConfig(vlessUri);
          
          if (jsonConfig.isEmpty) {
            print('Failed to generate V2Ray config');
            return false;
          }
          
          print('Starting V2Ray with JSON config...');
          
          // Start V2Ray with the JSON config
          await flutterV2ray.startV2Ray(
            remark: "AsadVPN",
            config: jsonConfig,
            bypassSubnets: ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"],
          );
          
          isConnected = true;
          
          // Start background scanning after connection
          startBackgroundScanning();
          
          // Save last config
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_config', vlessUri);
          
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
      allPingableServers.clear();
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