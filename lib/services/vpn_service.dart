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
  static bool _cancelAutoScan = false;
  static int _lastScannedIndex = 0;

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
      
      // Cancel auto-scan if connection happens
      if (newIsConnected && _isBackgroundScanning) {
        _cancelAutoScan = true;
        debugPrint('🛑 Cancelling auto-scan (connection established)');
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

  // Public method to resume auto-scan
  static void resumeAutoScan() {
    if (!isConnected && 
        fastestServers.length < 11 && 
        currentSubscriptionLink != null &&
        !_isBackgroundScanning) {
      debugPrint('🔵 Resuming auto-scan from index $_lastScannedIndex...');
      unawaited(_autoScanServers(resumeFromIndex: _lastScannedIndex));
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
      _lastScannedIndex = prefs.getInt('last_scanned_index') ?? 0;
      
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
      
      // Auto-scan for 11 servers if we have subscription and not connected
      if (currentSubscriptionLink != null && 
          currentSubscriptionLink!.isNotEmpty && 
          !isConnected && 
          fastestServers.length < 11) {
        debugPrint('🔵 Starting auto-scan for 11 servers (from index $_lastScannedIndex)...');
        unawaited(_autoScanServers(resumeFromIndex: _lastScannedIndex));
      }
      
      // Start health check
      _startHealthCheck();
    } catch (e, stack) {
      debugPrint('❌ Init error: $e\n$stack');
    }
  }

  // Auto-scan for 11 servers when app opens (not connected)
  static Future<void> _autoScanServers({int resumeFromIndex = 0}) async {
    if (_isBackgroundScanning) {
      debugPrint('⚠️ Auto-scan already running, skipping');
      return;
    }
    
    _isBackgroundScanning = true;
    _cancelAutoScan = false;
    
    // Don't delay if resuming
    if (resumeFromIndex == 0) {
      await Future.delayed(const Duration(seconds: 1));
    }
    
    if (isConnected) {
      debugPrint('⚠️ Already connected, skipping auto-scan');
      _isBackgroundScanning = false;
      return;
    }
    
    try {
      if (configServers.isEmpty) {
        final valid = await validateSubscription();
        if (!valid) {
          debugPrint('⚠️ Auto-scan: Invalid subscription');
          _isBackgroundScanning = false;
          return;
        }
      }
      
      final startMsg = resumeFromIndex > 0 
          ? 'resuming from index $resumeFromIndex' 
          : 'starting fresh';
      debugPrint('🔵 Auto-scan: Finding 11 servers ($startMsg)...');
      
      final prioritized = _prioritizeServers();
      final List<ServerInfo> foundServers = List.from(fastestServers);
      
      int tested = resumeFromIndex;
      
      for (int i = resumeFromIndex; i < prioritized.length; i++) {
        // Save progress periodically
        if (i % 5 == 0) {
          _lastScannedIndex = i;
          await _saveProgress();
        }
        
        // STOP conditions
        if (foundServers.length >= 11 || tested >= 50 || isConnected || _cancelAutoScan) {
          if (isConnected) {
            debugPrint('🛑 Auto-scan stopped: User connected');
          } else if (_cancelAutoScan) {
            debugPrint('🛑 Auto-scan cancelled');
          } else if (foundServers.length >= 11) {
            debugPrint('🎉 Auto-scan complete: Found 11 servers!');
            _lastScannedIndex = 0;
            await _saveProgress();
          }
          break;
        }
        
        tested++;
        
        if (tested % 10 == 0) {
          debugPrint('🔵 Auto-scan progress: tested $tested, found ${foundServers.length}/11');
        }
        
        // Double-check not connected before testing
        if (isConnected) {
          debugPrint('🛑 Auto-scan stopped: User connected during scan');
          break;
        }
        
        final result = await _testServerWithPing(prioritized[i]).timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
        
        if (result != null && !isConnected) {
          if (!foundServers.any((s) => s.config == result.config)) {
            foundServers.add(result);
            debugPrint('✅ Auto-scan: Found ${foundServers.length}/11: ${result.name} (${result.ping}ms)');
            
            fastestServers = foundServers;
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            serversStreamController.add(List.from(fastestServers));
            
            if (foundServers.length % 3 == 0) {
              await _updateTopServers(fastestServers.map((s) => s.config).toList());
            }
          }
        }
        
        // Small delay between tests
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      if (foundServers.isNotEmpty && !isConnected) {
        await _updateTopServers(fastestServers.map((s) => s.config).toList());
        
        if (foundServers.length >= 11) {
          debugPrint('🎉 Auto-scan SUCCESS: 11 servers ready!');
          _lastScannedIndex = 0;
          await _saveProgress();
        } else {
          debugPrint('📊 Auto-scan paused: ${foundServers.length}/11 servers (will resume at index $_lastScannedIndex)');
        }
      }
    } catch (e) {
      debugPrint('❌ Auto-scan error: $e');
    } finally {
      _isBackgroundScanning = false;
      _cancelAutoScan = false;
    }
  }

  static Future<void> _saveProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_scanned_index', _lastScannedIndex);
    } catch (e) {
      debugPrint('❌ Save progress error: $e');
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
        } else {
          // Valid subscription - start auto-scan if not connected
          _lastScannedIndex = 0;
          await _saveProgress();
          
          if (!isConnected) {
            debugPrint('🔵 New subscription validated, starting auto-scan...');
            unawaited(_autoScanServers());
          }
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
    // Cancel any running auto-scan
    if (_isBackgroundScanning) {
      _cancelAutoScan = true;
      debugPrint('🛑 Cancelling auto-scan (user clicked connect)');
      await Future.delayed(const Duration(milliseconds: 200));
    }
    
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

    // STEP 0: Test displayed servers FIRST (what user sees in the list)
    if (fastestServers.isNotEmpty) {
      debugPrint('🔵 Testing ${fastestServers.length} displayed servers first...');
      
      // Sort by ping (fastest first)
      final sortedDisplayed = List<ServerInfo>.from(fastestServers);
      sortedDisplayed.sort((a, b) => a.ping.compareTo(b.ping));
      
      for (int i = 0; i < sortedDisplayed.length && !_cancelScan; i++) {
        debugPrint('🔵 Testing displayed server ${i + 1}/${sortedDisplayed.length}: ${sortedDisplayed[i].name}...');
        
        final result = await _testServerWithPing(sortedDisplayed[i].config).timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            debugPrint('⏱️ Displayed server timeout (${sortedDisplayed[i].name})');
            return null;
          },
        );
        
        if (result != null) {
          debugPrint('✅ Displayed server working: ${result.name} (${result.ping}ms)');
          
          if (connectImmediately) {
            isScanning = false;
            
            // Update the server in the list with new ping
            final index = fastestServers.indexWhere((s) => s.config == result.config);
            if (index != -1) {
              fastestServers[index] = result;
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              serversStreamController.add(List.from(fastestServers));
            }
            
            await connect(vlessUri: result.config, ping: result.ping);
            debugPrint('🔵 Connected to displayed server');
            
            return {
              'success': true,
              'server': result.config,
              'ping': result.ping
            };
          }
        } else {
          // Remove dead server from displayed list
          debugPrint('❌ Removing dead server: ${sortedDisplayed[i].name}');
          fastestServers.removeWhere((s) => s.config == sortedDisplayed[i].config);
          topServers.removeWhere((c) => c == sortedDisplayed[i].config);
          await _updateTopServers(topServers);
          serversStreamController.add(List.from(fastestServers));
        }
      }
      
      if (_cancelScan) {
        isScanning = false;
        _cancelScan = false;
        return {'success': false, 'error': 'Scan cancelled'};
      }
      
      // If we tested all displayed servers and none worked
      if (fastestServers.isEmpty) {
        debugPrint('⚠️ All displayed servers failed, scanning for new ones...');
      }
    }

    // STEP 1: If no displayed servers or all failed, scan new servers
    debugPrint('🔵 Scanning for new servers (starting from newest)...');
    
    final prioritized = _prioritizeServers();
    
    // Test ONE BY ONE and connect to FIRST working server
    int tested = 0;
    for (var config in prioritized) {
      if (tested >= 30 || _cancelScan) {
        break;
      }
      
      tested++;
      debugPrint('🔵 Testing new server $tested/30...');
      
      final result = await _testServerWithPing(config).timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          debugPrint('⏱️ New server test timeout');
          return null;
        },
      );

      if (result != null) {
        debugPrint('✅ Found working server: ${result.name} (${result.ping}ms)');
        
        if (connectImmediately) {
          isScanning = false;
          
          // Add to fastestServers
          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            serversStreamController.add(List.from(fastestServers));
          }
          
          await _updateTopServers(fastestServers.map((s) => s.config).toList());
          
          await connect(vlessUri: result.config, ping: result.ping);
          
          debugPrint('🔵 Connected to new server');
          
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

    // 3. Rest of servers - REVERSED (newest first), NO SHUFFLE
    final remaining = configServers
        .where((c) => 
            !processed.contains(c) && 
            !topServers.contains(c) &&
            !scannedServers.contains(c))
        .toList();
    
    // REVERSE to get newest servers first (NO SHUFFLE)
    final reversed = remaining.reversed.toList();
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
            const Duration(seconds: 2),
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
      _cancelAutoScan = true;
      
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
      
      // After disconnect, if we have less than 11 servers, scan for more
      if (fastestServers.length < 11 && currentSubscriptionLink != null) {
        debugPrint('🔵 Disconnected, resuming auto-scan for more servers...');
        await Future.delayed(const Duration(milliseconds: 500));
        unawaited(_autoScanServers(resumeFromIndex: _lastScannedIndex));
      }
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