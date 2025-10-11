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
      final networkInfo = await getCurrentNetwork();
      _controller?.add(networkInfo);
    });
  }

  static Future<NetworkInfo> getCurrentNetwork() async {
    try {
      final connectivityResult = await _connectivity.checkConnectivity();
      
      if (connectivityResult == ConnectivityResult.wifi) {
        return await _getWiFiInfo();
      } else if (connectivityResult == ConnectivityResult.mobile) {
        return await _getMobileInfo();
      } else if (connectivityResult == ConnectivityResult.ethernet) {
        return NetworkInfo(
          id: 'ethernet_default',
          displayName: 'Ethernet',
          type: 'ethernet',
        );
      } else {
        return NetworkInfo(
          id: 'none',
          displayName: 'No Connection',
          type: 'none',
        );
      }
    } catch (e) {
      print('❌ Network detection error: $e');
      return NetworkInfo(
        id: 'unknown',
        displayName: 'Unknown Network',
        type: 'unknown',
      );
    }
  }

  static Future<NetworkInfo> _getWiFiInfo() async {
    try {
      if (Platform.isAndroid) {
        // Try to get WiFi network identifier from native code
        try {
          final String? networkId = await _channel.invokeMethod('getWiFiNetworkId');
          if (networkId != null && networkId.isNotEmpty && networkId != 'unknown') {
            // Create a hash of the network ID (BSSID, network ID, etc.)
            final hash = _generateHash(networkId);
            final shortHash = hash.substring(0, 6);
            
            print('✅ WiFi identifier: $networkId → hash: $shortHash');
            
            return NetworkInfo(
              id: 'wifi_$hash',
              displayName: 'WiFi ($shortHash)',
              type: 'wifi',
            );
          } else {
            print('⚠️ WiFi networkId is null or unknown');
          }
        } catch (e) {
          print('❌ Could not get WiFi network ID: $e');
        }
      }
      
      // FALLBACK: Use a stable generic identifier
      // Instead of timestamp, use a stable ID that persists
      print('⚠️ Using generic WiFi identifier (cannot distinguish between networks)');
      
      return NetworkInfo(
        id: 'wifi_generic',  // STABLE ID - same every time
        displayName: 'WiFi Network',
        type: 'wifi',
      );
    } catch (e) {
      print('❌ WiFi info error: $e');
      return NetworkInfo(
        id: 'wifi_generic',
        displayName: 'WiFi Network',
        type: 'wifi',
      );
    }
  }

  static Future<NetworkInfo> _getMobileInfo() async {
    try {
      if (Platform.isAndroid) {
        // Try to get carrier name using platform channel
        try {
          final String? carrier = await _channel.invokeMethod('getCarrierName');
          if (carrier != null && carrier.isNotEmpty) {
            return NetworkInfo(
              id: 'mobile_$carrier',
              displayName: 'Mobile: $carrier',
              type: 'mobile',
            );
          }
        } catch (e) {
          print('⚠️ Could not get carrier name: $e');
        }
      }
      
      // Fallback: generic mobile
      return NetworkInfo(
        id: 'mobile_unknown',
        displayName: 'Mobile Data',
        type: 'mobile',
      );
    } catch (e) {
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
    return digest.toString();
  }

  static void dispose() {
    _controller?.close();
    _controller = null;
  }
}
