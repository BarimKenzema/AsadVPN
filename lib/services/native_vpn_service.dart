import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class NativeVPNService {
  static const MethodChannel _channel = MethodChannel('com.asad.vpn/vpn');
  static bool isConnected = false;
  static StreamController<bool> connectionStateController = StreamController<bool>.broadcast();
  
  static Future<bool> connect(String vlessUri) async {
    try {
      print('Calling native VPN with config: ${vlessUri.substring(0, 50)}...');
      
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
      connectionStateController.add(isConnected);
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
  }
}