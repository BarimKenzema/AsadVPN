import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
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

class NativeVPNService {
  static const MethodChannel _channel = MethodChannel('com.asad.vpn/vpn');
  static bool isConnected = false;
  static StreamController<bool> connectionStateController = StreamController<bool>.broadcast();
  static StreamController<List<ServerInfo>> serversStreamController = StreamController<List<ServerInfo>>.broadcast();
  
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static bool isSubscriptionValid = false;
  static List<ServerInfo> fastestServers = [];
  static bool isScanning = false;
  static String? currentConnectedConfig;
  
  // Initialize
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      
      if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
        await validateSubscription();
      }
    } catch (e) {
      print('Init error: $e');
    }
  }
  
  // Validate subscription (copied from old VPNService)
  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      print('validateSubscription: No subscription link');
      isSubscriptionValid = false;
      return false;
    }
    
    try {
      print('=== VALIDATING SUBSCRIPTION ===');
      print('URL: $currentSubscriptionLink');
      
      final response = await http.get(
        Uri.parse(currentSubscriptionLink!),
        headers: {'User-Agent': 'AsadVPN/1.0'},
      ).timeout(Duration(seconds: 15));
      
      print('Response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        String content = response.body;
        
        if (content.contains('SUBSCRIPTION_EXPIRED') || content.contains('expired')) {
          print('Subscription expired');
          isSubscriptionValid = false;
          configServers = [];
          return false;
        }
        
        if (content.contains('<!DOCTYPE') || content.contains('<html')) {
          print('ERROR: Received HTML instead of configs');
          isSubscriptionValid = false;
          return false;
        }
        
        String decodedContent = content;
        try {
          if (!content.contains('://')) {
            print('Content appears to be base64 encoded, decoding...');
            decodedContent = utf8.decode(base64.decode(content.trim()));
            print('Decoded successfully');
          }
        } catch (e) {
          decodedContent = content;
        }
        
        var allConfigs = decodedContent
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .where((line) => !line.startsWith('#'))
            .toList();
        
        print('Total configs found: ${allConfigs.length}');
        
        configServers = allConfigs
            .where((config) => config.toLowerCase().startsWith('vless://'))
            .toList();
        
        print('VLESS configs: ${configServers.length}');
        
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
      
      link = link.trim();
      print('=== SAVING SUBSCRIPTION ===');
      print('Original input: "$link"');
      
      link = link.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
      
      if (!link.startsWith('http://') && !link.startsWith('https://')) {
        print('ERROR: Link must start with http:// or https://');
        return false;
      }
      
      if (!link.contains('pythonanywhere.com/sub/')) {
        print('ERROR: Not a pythonanywhere subscription link');
        return false;
      }
      
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);
      
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
  
  // Scan and select best server
  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    if (configServers.isEmpty) {
      return {'success': false, 'error': 'No servers available'};
    }
    
    isScanning = true;
    fastestServers.clear();
    
    List<String> vlessServers = List.from(configServers);
    vlessServers.shuffle(Random());
    
    List<String> batchToTest = vlessServers.take(min(10, vlessServers.length)).toList();
    
    print('Testing ${batchToTest.length} servers...');
    
    // For now, simulate ping test (native implementation will do real testing)
    for (String config in batchToTest) {
      fastestServers.add(ServerInfo(
        config: config,
        protocol: 'VLESS',
        ping: Random().nextInt(200) + 20,
        name: _extractServerName(config),
      ));
    }
    
    fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
    serversStreamController.add(fastestServers);
    
    isScanning = false;
    
    if (fastestServers.isNotEmpty) {
      return {
        'success': true,
        'server': fastestServers.first.config,
        'protocol': 'VLESS',
        'ping': fastestServers.first.ping,
      };
    }
    
    return {'success': false, 'error': 'No working servers found'};
  }
  
  static String _extractServerName(String config) {
    try {
      if (config.contains('#')) {
        String name = config.split('#').last;
        return Uri.decodeComponent(name);
      }
      return 'Unknown';
    } catch (e) {
      return 'Unknown';
    }
  }
  
  static Future<bool> connect(String vlessUri, {int? ping}) async {
    try {
      currentConnectedConfig = vlessUri;
      print('Calling native VPN with config: ${vlessUri.substring(0, min(50, vlessUri.length))}...');
      
      final bool result = await _channel.invokeMethod('startVPN', {
        'config': vlessUri,
      });
      
      isConnected = result;
      connectionStateController.add(isConnected);
      
      print('Native VPN result: $result');
      return result;
    } on PlatformException catch (e) {
      print('Failed to start VPN: ${e.message}');
      isConnected = false;
      connectionStateController.add(isConnected);
      return false;
    }
  }
  
  static Future<bool> disconnect() async {
    try {
      final bool result = await _channel.invokeMethod('stopVPN');
      isConnected = false;
      currentConnectedConfig = null;
      connectionStateController.add(isConnected);
      fastestServers.clear();
      serversStreamController.add([]);
      return result;
    } on PlatformException catch (e) {
      print('Failed to stop VPN: ${e.message}');
      return false;
    }
  }
  
  static Future<bool> checkConnection() async {
    try {
      isConnected = await _channel.invokeMethod('isConnected');
      connectionStateController.add(isConnected);
      return isConnected;
    } catch (e) {
      return false;
    }
  }
  
  static void dispose() {
    connectionStateController.close();
    serversStreamController.close();
  }
}