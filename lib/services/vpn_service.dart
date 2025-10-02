import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';

class VPNService {
  // CHANGE THIS TO YOUR PYTHONANYWHERE USERNAME
  static const String BACKEND_URL = 'https://konabalan.pythonanywhere.com';
  
  static String? androidId;
  static List<String> configServers = [];
  static bool isConnected = false;
  static String? currentSubscriptionLink;
  
  // Initialize and get Android ID
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Check if running on web or mobile
      if (!kIsWeb) {
        final deviceInfo = DeviceInfoPlugin();
        
        // Get Android ID for device tracking
        if (Platform.isAndroid) {
          final androidInfo = await deviceInfo.androidInfo;
          androidId = androidInfo.id ?? 'unknown';
        } else {
          androidId = 'web_test_id';
        }
      } else {
        // Running on web - use a test ID
        androidId = 'web_test_${DateTime.now().millisecondsSinceEpoch}';
      }
      
      // Store first install time for anti-abuse
      if (!prefs.containsKey('first_install')) {
        prefs.setString('first_install', DateTime.now().toIso8601String());
      }
      
      // Load saved subscription link if exists
      currentSubscriptionLink = prefs.getString('subscription_link');
    } catch (e) {
      print('Init error: $e');
      androidId = 'fallback_${DateTime.now().millisecondsSinceEpoch}';
    }
  }
  
  // Check subscription status with backend
  static Future<Map<String, dynamic>> checkSubscription() async {
    try {
      final response = await http.post(
        Uri.parse('$BACKEND_URL/check_trial'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'android_id': androidId}),
      ).timeout(Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('Error checking subscription: $e');
    }
    return {'status': 'error', 'message': 'Cannot connect to server'};
  }
  
  // Save subscription link
  static Future<void> saveSubscriptionLink(String link) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('subscription_link', link);
    currentSubscriptionLink = link;
  }
  
  // Fetch configs from subscription link
  static Future<bool> fetchConfigs(String url) async {
    try {
      final response = await http.get(Uri.parse(url))
          .timeout(Duration(seconds: 15));
      
      if (response.statusCode == 200) {
        // Split configs by newline and filter empty lines
        configServers = response.body
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .toList();
        
        print('Loaded ${configServers.length} servers');
        return configServers.isNotEmpty;
      }
    } catch (e) {
      print('Error fetching configs: $e');
    }
    return false;
  }
  
  // Smart server selection with chunk scanning
  static Future<Map<String, dynamic>> selectBestServer() async {
    if (configServers.isEmpty) {
      return {'success': false, 'error': 'No servers available'};
    }
    
    List<String> vlessServers = [];
    List<String> vmessServers = [];
    List<String> otherServers = [];
    
    // Categorize servers by protocol
    for (String config in configServers) {
      if (config.toLowerCase().startsWith('vless://')) {
        vlessServers.add(config);
      } else if (config.toLowerCase().startsWith('vmess://')) {
        vmessServers.add(config);
      } else {
        otherServers.add(config);
      }
    }
    
    print('Found: ${vlessServers.length} VLESS, ${vmessServers.length} VMESS, ${otherServers.length} other servers');
    
    // Phase 1: Scan first 15 VLESS servers for 3 seconds
    List<String> candidates = [];
    int chunkSize = 15;
    
    // Test first chunk of VLESS servers
    List<Future<MapEntry<String, bool>>> tests = [];
    for (int i = 0; i < vlessServers.length && i < chunkSize; i++) {
      tests.add(_testServerWithTimeout(vlessServers[i], 3));
    }
    
    // Wait for 3 seconds max
    if (tests.isNotEmpty) {
      final results = await Future.wait(tests);
      for (var result in results) {
        if (result.value) {
          candidates.add(result.key);
        }
      }
    }
    
    print('Phase 1: Found ${candidates.length} working VLESS servers');
    
    // If we have at least 2 VLESS candidates, use the first one
    if (candidates.length >= 2) {
      return {
        'success': true,
        'server': candidates.first,
        'protocol': 'VLESS',
        'candidates': candidates.length
      };
    }
    
    // Phase 2: Scan for another 3 seconds if needed
    if (candidates.length < 2) {
      print('Phase 2: Scanning more servers...');
      
      tests.clear();
      // Add remaining VLESS servers
      for (int i = chunkSize; i < vlessServers.length && i < chunkSize * 2; i++) {
        tests.add(_testServerWithTimeout(vlessServers[i], 3));
      }
      // Add some VMESS servers too
      for (int i = 0; i < vmessServers.length && i < 10; i++) {
        tests.add(_testServerWithTimeout(vmessServers[i], 3));
      }
      
      if (tests.isNotEmpty) {
        final moreResults = await Future.wait(tests);
        for (var result in moreResults) {
          if (result.value) {
            candidates.add(result.key);
          }
        }
      }
    }
    
    print('Phase 2: Total ${candidates.length} working servers');
    
    // Return best available server
    if (candidates.isNotEmpty) {
      return {
        'success': true,
        'server': candidates.first,
        'protocol': _getProtocol(candidates.first),
        'candidates': candidates.length
      };
    }
    
    // Phase 3: If still no candidates, try any server
    print('Phase 3: Using fallback server');
    String fallback = vlessServers.isNotEmpty ? vlessServers.first :
                     vmessServers.isNotEmpty ? vmessServers.first :
                     otherServers.isNotEmpty ? otherServers.first : '';
    
    if (fallback.isNotEmpty) {
      return {
        'success': true,
        'server': fallback,
        'protocol': _getProtocol(fallback),
        'fallback': true
      };
    }
    
    return {'success': false, 'error': 'No working servers found'};
  }
  
  // Get protocol type from config string
  static String _getProtocol(String config) {
    if (config.toLowerCase().startsWith('vless://')) return 'VLESS';
    if (config.toLowerCase().startsWith('vmess://')) return 'VMESS';
    if (config.toLowerCase().startsWith('trojan://')) return 'Trojan';
    if (config.toLowerCase().startsWith('ss://')) return 'Shadowsocks';
    return 'Unknown';
  }
  
  // Test server with timeout
  static Future<MapEntry<String, bool>> _testServerWithTimeout(String config, int seconds) async {
    try {
      bool result = await _testServer(config)
          .timeout(Duration(seconds: seconds), onTimeout: () => false);
      return MapEntry(config, result);
    } catch (e) {
      return MapEntry(config, false);
    }
  }
  
  // Test server connectivity
  static Future<bool> _testServer(String config) async {
    if (kIsWeb) {
      // On web, we can't do DNS lookups, so just return random for testing
      return DateTime.now().millisecondsSinceEpoch % 3 == 0;
    }
    
    try {
      // Extract host from config
      String host = '';
      
      if (config.contains('://') && config.contains('@')) {
        // Format: protocol://uuid@host:port
        String afterProtocol = config.split('://')[1];
        String hostPart = afterProtocol.split('@')[1];
        host = hostPart.split(':')[0].split('?')[0].split('#')[0];
      }
      
      if (host.isNotEmpty) {
        final result = await InternetAddress.lookup(host)
            .timeout(Duration(seconds: 2));
        return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      }
    } catch (e) {
      // Server is not reachable
    }
    return false;
  }
  
  // Connect to VPN
  static Future<bool> connect(String config) async {
    try {
      // TODO: Integrate with actual V2Ray library
      // For now, we simulate connection
      await Future.delayed(Duration(seconds: 2));
      isConnected = true;
      
      // Save last connected config
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_config', config);
      
      return true;
    } catch (e) {
      print('Connection error: $e');
      return false;
    }
  }
  
  // Disconnect VPN
  static Future<void> disconnect() async {
    try {
      // TODO: Integrate with actual V2Ray library
      await Future.delayed(Duration(milliseconds: 500));
      isConnected = false;
    } catch (e) {
      print('Disconnect error: $e');
    }
  }
  
  // Check if device was wiped (anti-abuse)
  static Future<bool> checkDeviceWipe() async {
    final prefs = await SharedPreferences.getInstance();
    String? firstInstall = prefs.getString('first_install');
    
    if (firstInstall == null) {
      return false; // First time install
    }
    
    // Check if app data was cleared but device ID is same
    // This indicates potential abuse
    final deviceCheck = prefs.getString('device_check_$androidId');
    if (deviceCheck == null && androidId != null) {
      // Device was likely wiped
      await prefs.setString('device_check_$androidId', DateTime.now().toIso8601String());
      return true;
    }
    
    return false;
  }
}