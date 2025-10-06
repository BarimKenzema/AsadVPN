import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/server_cache.dart';

class ServerInfo {
  final String config;
  final String protocol;
  final int ping;
  final String name;
  final double successRate;
  final DateTime? lastConnected;

  ServerInfo({
    required this.config,
    required this.protocol,
    required this.ping,
    required this.name,
    this.successRate = 0.0,
    this.lastConnected,
  });
}

// Custom exception for network errors
class NetworkException implements Exception {
  final String message;
  NetworkException(this.message);
  
  @override
  String toString() => message;
}

class VPNService {
  static final V2ray v2ray = V2ray(onStatusChanged: _updateConnectionState);

  static bool isConnected = false;
  static bool isSubscriptionValid = false;
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = [];
  static bool isScanning = false;
  static String? currentConnectedConfig;
  static int? currentConnectedPing;
  static int scanProgress = 0;
  static int totalToScan = 0;

  // Caching
  static Map<String, ServerCache> serverCache = {};
  static String? lastGoodServer;
  static List<String> topServers = [];
  static Set<String> scannedServers = {};

  // Stats
  static int sessionDownload = 0;
  static int sessionUpload = 0;
  static List<ConnectionStats> dailyStats = [];

  // Background scanning
  static Timer? _backgroundScanTimer;
  static Timer? _healthCheckTimer;
  static bool _isBackgroundScanning = false;
  static DateTime? _lastConnectionTime;
  static bool _isManualDisconnect = false;
  static bool _cancelScan = false;

  static final StreamController<List<ServerInfo>> serversStreamController =
      StreamController<List<ServerInfo>>.broadcast();
  static final StreamController<bool> connectionStateController =
      StreamController<bool>.broadcast();
  static final StreamController<V2RayStatus> statusStreamController =
      StreamController<V2RayStatus>.broadcast();
  static final StreamController<int> scanProgressController =
      StreamController<int>.broadcast();

  static void _updateConnectionState(V2RayStatus status) {
    final newIsConnected = status.state == 'CONNECTED';
    
    // Track traffic
    if (newIsConnected) {
      sessionDownload = status.download;
      sessionUpload = status.upload;
    }
    
    statusStreamController.add(status);
    
    if (isConnected != newIsConnected) {
      isConnected = newIsConnected;
      connectionStateController.add(isConnected);
      debugPrint('🔵 V2Ray status changed to: ${status.state}');
      
      // Start background scan BEFORE connecting (11 seconds after connection)
      if (newIsConnected && _lastConnectionTime == null) {
        _lastConnectionTime = DateTime.now();
        _isManualDisconnect = false;
        
        // Background scan to find more servers (BEFORE connecting works better)
        if (fastestServers.length < 11) {
          debugPrint('🔵 Connection successful, will find more servers in background...');
          // Do a quick background scan to fill the list
          Future.delayed(const Duration(seconds: 2), () {
            if (isConnected && fastestServers.length < 11) {
              _quickBackgroundScan();
            }
          });
        }
      }
      
      // If disconnected unexpectedly (NOT manual), try to reconnect
      if (!newIsConnected && currentConnectedConfig != null && !_isManualDisconnect) {
        debugPrint('⚠️ Unexpected disconnect detected');
        _handleDisconnect();
      } else if (!newIsConnected && _isManualDisconnect) {
        debugPrint('🔵 Manual disconnect, no reconnection needed');
      }
    }
  }

  static void _handleDisconnect() {
    debugPrint('⚠️ Unexpected disconnect, attempting reconnect...');
    _lastConnectionTime = null;
    Future.delayed(const Duration(seconds: 2), () async {
      if (!isConnected && fastestServers.isNotEmpty && !_isManualDisconnect) {
        await connect(
          vlessUri: fastestServers.first.config,
          ping: fastestServers.first.ping,
        );
      }
    });
  }

  static Future<bool> hasInternetConnection() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        debugPrint('❌ No internet connection (connectivity check)');
        return false;
      }
      
      // Double-check with actual network request
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      final hasConnection = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      debugPrint(hasConnection ? '✅ Internet connection OK' : '❌ No internet connection');
      return hasConnection;
    } catch (e) {
      debugPrint('❌ Internet check failed: $e');
      return false;
    }
  }

  static void cancelScan() {
    if (isScanning) {
      _cancelScan = true;
      debugPrint('🛑 Scan cancellation requested');
    }
  }

  static Future<void> init() async {
    try {
      debugPrint('🔵 Initializing VPN Service...');

      await v2ray.initialize(
        notificationIconResourceName: "ic_launcher",
        notificationIconResourceType: "mipmap",
      );

      await _loadCache();
      await _loadStats();
      await _loadScannedServers();

      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      lastGoodServer = prefs.getString('last_good_server');
      
      final topServersList = prefs.getStringList('top_servers');
      if (topServersList != null) {
        topServers = topServersList;
        debugPrint('🔵 Loaded ${topServers.length} top servers from cache');
        
        // Load them into fastestServers for display
        fastestServers = topServersList
            .map((config) {
              final cached = serverCache[config];
              if (cached != null) {
                return ServerInfo(
                  config: config,
                  protocol: cached.protocol,
                  ping: cached.lastPing,
                  name: cached.name,
                  successRate: cached.successRate,
                  lastConnected: cached.lastConnected,
                );
              }
              return null;
            })
            .whereType<ServerInfo>()
            .toList();
        
        if (fastestServers.isNotEmpty) {
          serversStreamController.add(List.from(fastestServers));
          debugPrint('🔵 Loaded ${fastestServers.length} servers for display');
        }
      }

      debugPrint('🔵 Init complete. Subscription link exists: ${currentSubscriptionLink != null}');
      
      // Start health check
      _startHealthCheck();
    } catch (e, stack) {
      debugPrint('❌ Init error: $e\n$stack');
    }
  }

  static Future<void> _loadScannedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scannedList = prefs.getStringList('scanned_servers');
      if (scannedList != null) {
        scannedServers = scannedList.toSet();
        debugPrint('✅ Loaded ${scannedServers.length} scanned servers');
      }
    } catch (e) {
      debugPrint('❌ Scanned servers load error: $e');
    }
  }

  static Future<void> _saveScannedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('scanned_servers', scannedServers.toList());
    } catch (e) {
      debugPrint('❌ Scanned servers save error: $e');
    }
  }

  static void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (isConnected && !_isManualDisconnect) {
        try {
          final delay = await v2ray.getConnectedServerDelay();
          if (delay == -1 || delay > 5000) {
            debugPrint('⚠️ Connection unhealthy (${delay}ms), reconnecting...');
            _handleDisconnect();
          }
        } catch (e) {
          debugPrint('❌ Health check error: $e');
        }
      }
    });
  }

  static Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString('server_cache');
      if (cacheJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(cacheJson);
        serverCache = decoded.map(
          (key, value) => MapEntry(key, ServerCache.fromJson(value)),
        );
        debugPrint('✅ Loaded ${serverCache.length} cached servers');
      }
    } catch (e) {
      debugPrint('❌ Cache load error: $e');
    }
  }

  static Future<void> _saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        serverCache.map((key, value) => MapEntry(key, value.toJson())),
      );
      await prefs.setString('server_cache', encoded);
    } catch (e) {
      debugPrint('❌ Cache save error: $e');
    }
  }

  static Future<void> _loadStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final statsJson = prefs.getString('daily_stats');
      if (statsJson != null) {
        final List<dynamic> decoded = jsonDecode(statsJson);
        dailyStats = decoded.map((e) => ConnectionStats.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('❌ Stats load error: $e');
    }
  }

  static Future<void> _saveStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(dailyStats.map((e) => e.toJson()).toList());
      await prefs.setString('daily_stats', encoded);
    } catch (e) {
      debugPrint('❌ Stats save error: $e');
    }
  }

  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      isSubscriptionValid = false;
      return false;
    }

    try {
      debugPrint('🔵 Validating subscription...');
      final resp = await http
          .get(Uri.parse(currentSubscriptionLink!),
              headers: {'User-Agent': 'AsadVPN/1.0'})
          .timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200 || resp.body.contains('<!DOCTYPE')) {
        isSubscriptionValid = false;
        debugPrint('❌ Subscription validation failed: Invalid response');
        return false;
      }

      var content = resp.body;
      if (!content.contains('://')) {
        try {
          content = utf8.decode(base64.decode(content.trim()));
        } catch (_) {}
      }

      final lines = content
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();

      final vless = lines.where((l) => l.toLowerCase().startsWith('vless://')).toList();
      final vmess = lines.where((l) => l.toLowerCase().startsWith('vmess://')).toList();
      final trojan = lines.where((l) => l.toLowerCase().startsWith('trojan://')).toList();
      final ss = lines.where((l) => l.toLowerCase().startsWith('ss://')).toList();

      debugPrint('🔵 Found: ${vless.length} VLESS, ${vmess.length} VMESS, ${trojan.length} Trojan, ${ss.length} SS');

      configServers = [...vless, ...vmess, ...trojan, ...ss];

      if (configServers.isEmpty) {
        configServers = lines;
      }

      isSubscriptionValid = configServers.isNotEmpty;
      debugPrint('✅ Subscription valid: $isSubscriptionValid, servers: ${configServers.length}');
      return isSubscriptionValid;
    } on SocketException catch (e) {
      isSubscriptionValid = false;
      debugPrint('❌ Network error during validation: $e');
      throw NetworkException('No internet connection');
    } on TimeoutException catch (e) {
      isSubscriptionValid = false;
      debugPrint('❌ Timeout during validation: $e');
      throw NetworkException('Connection timeout');
    } catch (e) {
      isSubscriptionValid = false;
      debugPrint('❌ Subscription validation error: $e');
      return false;
    }
  }

  static Future<bool> saveSubscriptionLink(String link) async {
    try {
      link = link.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');

      if (!link.startsWith('http')) return false;

      final prefs = await SharedPreferences.getInstance();
      
      // If it's the same link already saved, don't re-validate
      if (currentSubscriptionLink == link && link.isNotEmpty) {
        debugPrint('✅ Subscription link unchanged, keeping existing');
        return true;
      }

      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);

      // Try to validate
      try {
        final valid = await validateSubscription();
        if (!valid) {
          // Invalid content (not network error)
          await prefs.remove('subscription_link');
          currentSubscriptionLink = null;
        }
        debugPrint('✅ Subscription link ${valid ? "saved and validated" : "invalid"}');
        return valid;
      } on NetworkException catch (e) {
        // Network error - KEEP the subscription
        debugPrint('⚠️ Cannot validate subscription (${e.message}), but keeping it saved');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Save subscription error: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>> scanAndSelectBestServer({bool connectImmediately = true}) async {
    // Check internet connection first
    if (!await hasInternetConnection()) {
      return {'success': false, 'error': 'No internet connection'};
    }

    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      return {'success': false, 'error': 'No subscription link'};
    }

    if (configServers.isEmpty) {
      try {
        final valid = await validateSubscription();
        if (!valid) {
          return {'success': false, 'error': 'Invalid subscription or no servers'};
        }
      } on NetworkException {
        return {'success': false, 'error': 'No internet connection'};
      }
    }

    isScanning = true;
    _cancelScan = false;
    scanProgress = 0;
    _lastConnectionTime = null;
    
    totalToScan = 0;
    scanProgressController.add(0);

    // Step 1: Test saved top servers first (ONE BY ONE)
    if (topServers.isNotEmpty) {
      debugPrint('🔵 Testing saved top servers (${topServers.length})...');
      
      final validTopServers = topServers.where((config) => configServers.contains(config)).toList();
      
      // Test ONE BY ONE and connect to FIRST working server
      for (int i = 0; i < validTopServers.length && !_cancelScan; i++) {
        debugPrint('🔵 Testing top server ${i + 1}/${validTopServers.length}...');
        
        final result = await _testServerWithPing(validTopServers[i]).timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            debugPrint('⏱️ Top server test timeout');
            return null;
          },
        );
        
        if (result != null) {
          debugPrint('✅ Top server working: ${result.name} (${result.ping}ms)');
          
          // CONNECT IMMEDIATELY to first working server
          if (connectImmediately) {
            isScanning = false;
            fastestServers = [result];
            serversStreamController.add(List.from(fastestServers));
            
            await connect(vlessUri: result.config, ping: result.ping);
            
            debugPrint('🔵 Connected to first working server, finding more in background...');
            
            // Continue scanning in background to fill the list
            unawaited(_continueBackgroundScan(validTopServers.skip(i + 1).toList()));
            
            return {
              'success': true,
              'server': result.config,
              'ping': result.ping
            };
          }
        }
      }
      
      if (_cancelScan) {
        isScanning = false;
        _cancelScan = false;
        return {'success': false, 'error': 'Scan cancelled'};
      }
    }

    // Step 2: Scan new servers (ONE BY ONE, starting from BOTTOM/newest)
    debugPrint('🔵 Scanning for new servers (starting from newest)...');
    
    final prioritized = _prioritizeServers();
    
    // Test ONE BY ONE and connect to FIRST working server
    int tested = 0;
    for (var config in prioritized) {
      if (tested >= 30 || _cancelScan) {
        break;
      }
      
      tested++;
      debugPrint('🔵 Testing server $tested/30...');
      
      final result = await _testServerWithPing(config).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          debugPrint('⏱️ Server test timeout');
          return null;
        },
      );

      if (result != null) {
        debugPrint('✅ Found working server: ${result.name} (${result.ping}ms)');
        
        // CONNECT IMMEDIATELY to first working server
        if (connectImmediately) {
          isScanning = false;
          fastestServers = [result];
          serversStreamController.add(List.from(fastestServers));
          await _updateTopServers([result.config]);
          
          await connect(vlessUri: result.config, ping: result.ping);
          
          debugPrint('🔵 Connected to first working server, finding more in background...');
          
          // Continue scanning in background
          unawaited(_continueBackgroundScan(prioritized.skip(prioritized.indexOf(config) + 1).toList()));
          
          return {
            'success': true,
            'server': result.config,
            'ping': result.ping
          };
        }
      }
    }

    isScanning = false;

    if (_cancelScan) {
      _cancelScan = false;
      return {'success': false, 'error': 'Scan cancelled'};
    }

    return {'success': false, 'error': 'No working servers found'};
  }

  // NEW: Continue scanning in background BEFORE connecting (so it works)
  static Future<void> _continueBackgroundScan(List<String> remainingServers) async {
    debugPrint('🔵 Background scan: Finding up to 10 more servers...');
    
    int found = 0;
    int tested = 0;
    
    for (var config in remainingServers) {
      if (found >= 10 || tested >= 50) {
        break;
      }
      
      tested++;
      
      final result = await _testServerWithPing(config).timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      
      if (result != null) {
        found++;
        fastestServers.add(result);
        debugPrint('✅ Background: Found server ${found}/10: ${result.name} (${result.ping}ms)');
        
        fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
        serversStreamController.add(List.from(fastestServers));
        
        if (found % 3 == 0) {
          await _updateTopServers(fastestServers.map((s) => s.config).toList());
        }
      }
      
      // Small delay between tests
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    if (fastestServers.isNotEmpty) {
      await _updateTopServers(fastestServers.map((s) => s.config).toList());
    }
    
    debugPrint('✅ Background scan complete: ${fastestServers.length} total servers found');
  }

  // Quick background scan (not used anymore, but keeping for reference)
  static Future<void> _quickBackgroundScan() async {
    if (_isBackgroundScanning) return;
    
    _isBackgroundScanning = true;
    debugPrint('🔵 Quick background scan started...');
    
    // This won't work through VPN, so we skip it
    debugPrint('⚠️ Skipping background scan (cannot ping through VPN tunnel)');
    
    _isBackgroundScanning = false;
  }

  static List<String> _prioritizeServers() {
    final Set<String> processed = {};
    final List<String> result = [];

    // 1. Top servers first (always re-test these)
    for (var config in topServers) {
      if (configServers.contains(config) && !processed.contains(config)) {
        result.add(config);
        processed.add(config);
      }
    }

    // 2. Cached servers with good success rate
    final goodCached = serverCache.entries
        .where((e) => 
            e.value.successRate > 0.7 && 
            configServers.contains(e.key) &&
            !topServers.contains(e.key) &&
            !scannedServers.contains(e.key))
        .map((e) => e.key)
        .where((c) => !processed.contains(c))
        .toList();
    result.addAll(goodCached);
    processed.addAll(goodCached);

    // 3. Rest of servers - START FROM BOTTOM (newest servers)
    final remaining = configServers
        .where((c) => 
            !processed.contains(c) && 
            !topServers.contains(c) &&
            !scannedServers.contains(c))
        .toList();
    
    // REVERSE to get newest servers first, then shuffle
    final reversed = remaining.reversed.toList();
    reversed.shuffle(Random());
    result.addAll(reversed);

    return result;
  }

  static Future<void> _updateTopServers(List<String> servers) async {
    topServers = servers.take(11).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('top_servers', topServers);
    debugPrint('💾 Saved ${topServers.length} top servers');
  }

  static Future<ServerInfo?> _testServerWithPing(String uri) async {
    try {
      final parser = V2ray.parseFromURL(uri);
      final config = parser.getFullConfiguration();

      // Add internal timeout to the actual delay check
      final delay = await v2ray.getServerDelay(config: config)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              return -1;
            },
          );

      if (delay != -1 && delay < 5000) {
        debugPrint('✅ ${parser.remark}: ${delay}ms');
        
        final existing = serverCache[uri];
        serverCache[uri] = ServerCache(
          config: uri,
          name: parser.remark,
          protocol: _getProtocol(uri),
          lastPing: delay,
          lastTested: DateTime.now(),
          successCount: (existing?.successCount ?? 0) + 1,
          failureCount: existing?.failureCount ?? 0,
          lastConnected: existing?.lastConnected,
        );
        unawaited(_saveCache());

        return ServerInfo(
          config: uri,
          protocol: _getProtocol(uri),
          ping: delay,
          name: parser.remark,
          successRate: serverCache[uri]!.successRate,
        );
      } else {
        final existing = serverCache[uri];
        if (existing != null) {
          serverCache[uri] = ServerCache(
            config: uri,
            name: existing.name,
            protocol: existing.protocol,
            lastPing: existing.lastPing,
            lastTested: DateTime.now(),
            successCount: existing.successCount,
            failureCount: existing.failureCount + 1,
          );
          unawaited(_saveCache());
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  static String _getProtocol(String uri) {
    if (uri.startsWith('vless://')) return 'VLESS';
    if (uri.startsWith('vmess://')) return 'VMESS';
    if (uri.startsWith('trojan://')) return 'TROJAN';
    if (uri.startsWith('ss://')) return 'SS';
    return 'UNKNOWN';
  }

  static Future<bool> connect({required String vlessUri, int? ping}) async {
    if (kIsWeb || !Platform.isAndroid) return false;

    try {
      if (isConnected) {
        _isManualDisconnect = true;
        await disconnect();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      _isManualDisconnect = false;

      final parser = V2ray.parseFromURL(vlessUri);
      final config = parser.getFullConfiguration();

      if (await v2ray.requestPermission()) {
        await v2ray.startV2Ray(
          remark: parser.remark,
          config: config,
          proxyOnly: false,
          bypassSubnets: [],
        );

        currentConnectedConfig = vlessUri;
        currentConnectedPing = ping;

        final existing = serverCache[vlessUri];
        if (existing != null) {
          serverCache[vlessUri] = ServerCache(
            config: vlessUri,
            name: existing.name,
            protocol: existing.protocol,
            lastPing: existing.lastPing,
            lastTested: existing.lastTested,
            successCount: existing.successCount + 1,
            failureCount: existing.failureCount,
            lastConnected: DateTime.now(),
          );
        } else {
          serverCache[vlessUri] = ServerCache(
            config: vlessUri,
            name: parser.remark,
            protocol: _getProtocol(vlessUri),
            lastPing: ping ?? -1,
            lastTested: DateTime.now(),
            successCount: 1,
            lastConnected: DateTime.now(),
          );
        }

        lastGoodServer = vlessUri;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_good_server', vlessUri);
        unawaited(_saveCache());

        debugPrint('✅ Connected successfully');
        return true;
      }
      return false;
    } catch (e) {
      final existing = serverCache[vlessUri];
      if (existing != null) {
        serverCache[vlessUri] = ServerCache(
          config: vlessUri,
          name: existing.name,
          protocol: existing.protocol,
          lastPing: existing.lastPing,
          lastTested: existing.lastTested,
          successCount: existing.successCount,
          failureCount: existing.failureCount + 1,
        );
        unawaited(_saveCache());
      }
      debugPrint('❌ Connection error: $e');
      return false;
    }
  }

  static Future<bool> connectToLastGoodServer() async {
    if (lastGoodServer != null && lastGoodServer!.isNotEmpty) {
      debugPrint('🔵 Connecting to last good server...');
      final cached = serverCache[lastGoodServer];
      return await connect(
        vlessUri: lastGoodServer!,
        ping: cached?.lastPing,
      );
    }
    return false;
  }

  static Future<void> disconnect() async {
    try {
      _isManualDisconnect = true;
      
      if (isConnected && (sessionDownload > 0 || sessionUpload > 0)) {
        final today = DateTime.now();
        final todayStats = dailyStats.firstWhere(
          (s) =>
              s.date.year == today.year &&
              s.date.month == today.month &&
              s.date.day == today.day,
          orElse: () => ConnectionStats(
            totalDownload: 0,
            totalUpload: 0,
            date: today,
          ),
        );

        dailyStats.removeWhere((s) =>
            s.date.year == today.year &&
            s.date.month == today.month &&
            s.date.day == today.day);

        dailyStats.add(ConnectionStats(
          totalDownload: todayStats.totalDownload + sessionDownload,
          totalUpload: todayStats.totalUpload + sessionUpload,
          date: today,
        ));

        await _saveStats();
      }

      await v2ray.stopV2Ray();
      debugPrint('✅ Disconnected');
    } catch (e) {
      debugPrint('❌ Disconnect error: $e');
    } finally {
      isConnected = false;
      currentConnectedConfig = null;
      currentConnectedPing = null;
      sessionDownload = 0;
      sessionUpload = 0;
      _lastConnectionTime = null;
      connectionStateController.add(false);
    }
  }

  static void dispose() {
    _backgroundScanTimer?.cancel();
    _healthCheckTimer?.cancel();
    serversStreamController.close();
    connectionStateController.close();
    statusStreamController.close();
    scanProgressController.close();
  }
}

void unawaited(Future<void> future) {}