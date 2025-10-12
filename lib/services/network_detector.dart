import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

class NetworkInfo {
  final String id;
  final String displayName;
  final String type; // 'wifi', 'mobile', 'ethernet', 'unknown'

  NetworkInfo({
    required this.id,
    required this.displayName,
    required this.type,
  });
}

class NetworkDetector {
  static const MethodChannel _channel = MethodChannel('network_detector');
  static final Connectivity _connectivity = Connectivity();
  
  static StreamController<NetworkInfo>? _controller;
  static Stream<NetworkInfo> get networkStream {
    _controller ??= StreamController<NetworkInfo>.broadcast();
    _startListening();
    return _controller!.stream;
  }

  static void _startListening() {
    _connectivity.onConnectivityChanged.listen((ConnectivityResult result) async {
      print('🔵 [NetworkDetector] Connectivity changed to: $result');
      final networkInfo = await getCurrentNetwork();
      _controller?.add(networkInfo);
    });
  }

  static Future<NetworkInfo> getCurrentNetwork() async {
    print('🔍 [NetworkDetector] Getting current network...');
    
    try {
      final connectivityResult = await _connectivity.checkConnectivity();
      print('🔍 [NetworkDetector] Connectivity result: $connectivityResult');
      
      if (connectivityResult == ConnectivityResult.wifi) {
        return await _getWiFiInfo();
      } else if (connectivityResult == ConnectivityResult.mobile) {
        return await _getMobileInfo();
      } else if (connectivityResult == ConnectivityResult.ethernet) {
        print('✅ [NetworkDetector] Ethernet detected');
        return NetworkInfo(
          id: 'ethernet_default',
          displayName: 'Ethernet',
          type: 'ethernet',
        );
      } else {
        print('⚠️ [NetworkDetector] No connection');
        return NetworkInfo(
          id: 'none',
          displayName: 'No Connection',
          type: 'none',
        );
      }
    } catch (e) {
      print('❌ [NetworkDetector] Error: $e');
      return NetworkInfo(
        id: 'unknown',
        displayName: 'Unknown Network',
        type: 'unknown',
      );
    }
  }

  static Future<NetworkInfo> _getWiFiInfo() async {
    print('🔍 [NetworkDetector] Getting WiFi info...');
    
    try {
      if (Platform.isAndroid) {
        // Try to get WiFi network identifier from native code
        try {
          print('📞 [NetworkDetector] Calling native getWiFiNetworkId...');
          final String? networkId = await _channel.invokeMethod('getWiFiNetworkId');
          
          print('📥 [NetworkDetector] Received from native: "$networkId"');
          
          if (networkId != null && networkId.isNotEmpty && networkId != 'unknown') {
            // Create a hash of the network ID (includes gateway + DNS + local IP now)
            final hash = _generateHash(networkId);
            final shortHash = hash.substring(0, 8);
            
            print('✅ [NetworkDetector] WiFi identifier SUCCESS!');
            print('   Raw value: $networkId');
            print('   Full hash: $hash');
            print('   Short hash: $shortHash');
            
            return NetworkInfo(
              id: 'wifi_$hash',
              displayName: 'WiFi ($shortHash)',
              type: 'wifi',
            );
          } else {
            print('⚠️ [NetworkDetector] WiFi networkId is null/empty/unknown: "$networkId"');
          }
        } catch (e) {
          print('❌ [NetworkDetector] Native call failed: $e');
        }
      } else {
        print('⚠️ [NetworkDetector] Not Android platform');
      }
      
      // FALLBACK: Return error (don't use generic)
      print('❌ [NetworkDetector] Failed to identify WiFi network');
      
      return NetworkInfo(
        id: 'wifi_unknown_error',
        displayName: 'WiFi (Unknown)',
        type: 'wifi',
      );
    } catch (e) {
      print('❌ [NetworkDetector] WiFi info error: $e');
      return NetworkInfo(
        id: 'wifi_error',
        displayName: 'WiFi (Error)',
        type: 'wifi',
      );
    }
  }

  static Future<NetworkInfo> _getMobileInfo() async {
    print('🔍 [NetworkDetector] Getting Mobile info...');
    
    try {
      if (Platform.isAndroid) {
        // Try to get carrier name using platform channel
        try {
          print('📞 [NetworkDetector] Calling native getCarrierName...');
          final String? carrier = await _channel.invokeMethod('getCarrierName');
          
          print('📥 [NetworkDetector] Received carrier: "$carrier"');
          
          if (carrier != null && carrier.isNotEmpty) {
            print('✅ [NetworkDetector] Carrier SUCCESS: $carrier');
            return NetworkInfo(
              id: 'mobile_$carrier',
              displayName: 'Mobile: $carrier',
              type: 'mobile',
            );
          }
        } catch (e) {
          print('❌ [NetworkDetector] Carrier call failed: $e');
        }
      }
      
      // Fallback: generic mobile
      print('⚠️ [NetworkDetector] Using generic mobile');
      return NetworkInfo(
        id: 'mobile_unknown',
        displayName: 'Mobile Data',
        type: 'mobile',
      );
    } catch (e) {
      print('❌ [NetworkDetector] Mobile error: $e');
      return NetworkInfo(
        id: 'mobile_error',
        displayName: 'Mobile Data',
        type: 'mobile',
      );
    }
  }

  static String _generateHash(String input) {
    final bytes = utf8.encode(input);
    final digest = md5.convert(bytes);
    final hash = digest.toString();
    print('🔐 [NetworkDetector] Hash generated: $input → $hash');
    return hash;
  }

  static void dispose() {
    _controller?.close();
    _controller = null;
  }
}
