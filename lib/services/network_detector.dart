import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

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
          id: 'unknown',
          displayName: 'No Connection',
          type: 'unknown',
        );
      }
    } catch (e) {
      print('❌ Network detection error: $e');
      return NetworkInfo(
        id: 'error',
        displayName: 'Unknown Network',
        type: 'unknown',
      );
    }
  }

  static Future<NetworkInfo> _getWiFiInfo() async {
    try {
      if (Platform.isAndroid) {
        // Try to get WiFi SSID using platform channel
        try {
          final String? ssid = await _channel.invokeMethod('getWiFiSSID');
          if (ssid != null && ssid.isNotEmpty && ssid != '<unknown ssid>') {
            // Clean up SSID (remove quotes if present)
            final cleanSSID = ssid.replaceAll('"', '');
            return NetworkInfo(
              id: 'wifi_$cleanSSID',
              displayName: 'WiFi: $cleanSSID',
              type: 'wifi',
            );
          }
        } catch (e) {
          print('⚠️ Could not get WiFi SSID: $e');
        }
      }
      
      // Fallback: generic WiFi
      return NetworkInfo(
        id: 'wifi_unknown_${DateTime.now().millisecondsSinceEpoch}',
        displayName: 'WiFi Network',
        type: 'wifi',
      );
    } catch (e) {
      return NetworkInfo(
        id: 'wifi_error',
        displayName: 'WiFi',
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
        displayName: 'Mobile',
        type: 'mobile',
      );
    }
  }

  static void dispose() {
    _controller?.close();
    _controller = null;
  }
}
