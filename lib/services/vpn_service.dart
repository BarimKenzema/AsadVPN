import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';

class VPNService {
  static String? androidId;
  static List<String> configServers = [];
  static bool isConnected = false;
  static String? currentSubscriptionLink;
  static bool isSubscriptionValid = false;
  
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
        
        // Check if subscription is expired (your backend returns this specific config when expired)
        if (content.contains('SUBSCRIPTION_EXPIRED')) {
          print('Subscription expired');
          isSubscriptionValid = false;
          configServers = [];
          return false;
        }
        
        // Parse the configs
        configServers = content
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .where((line) => !line.startsWith('#')) // Remove comments
            .toList();
        
        print('Loaded ${configServers.length} servers');
        isSubscriptionValid = configServers.isNotEmpty;
        return isSubscriptionValid;
      } else if (response.statusCode == 403) {
        // Invalid token or not activated
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
      
      // Basic validation - should be a konabalan.pythonanywhere.com link
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
  
  // Clear subscription
  static Future<void> clearSubscription() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('subscription_link');
    currentSubscriptionLink = null;
    isSubscriptionValid = false;
    configServers = [];
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
        if (afterProtocol.contains('@')) {
          String hostPart = afterProtocol.split('@')[1];
          host = hostPart.split(':')[0].split('?')[0].split('#')[0];
        }
      }
      
      if (host.isNotEmpty && host != '127.0.0.1') {
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
}