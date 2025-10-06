import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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

  // Stats
  static int sessionDownload = 0;
  static int sessionUpload = 0;
  static List<ConnectionStats> dailyStats = [];

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

      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      lastGoodServer = prefs.getString('last_good_server');
      
      final topServersList = prefs.getStringList('top_servers');
      if (topServersList != null) {
        topServers = topServersList;
      }

      if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
        final valid = await validateSubscription();
        debugPrint('🔵 Subscription valid: $valid, servers: ${configServers.length}');
        
        if (valid) {
          // Pre-test top 3 servers on startup
          await _preTestTopServers();
        }
      }
    } catch (e, stack) {
      debugPrint('❌ Init error: $e\n$stack');
    }
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

  static Future<void> _preTestTopServers() async {
    if (topServers.isEmpty) return;
    
    debugPrint('🔵 Pre-testing top 3 servers...');
    final toTest = topServers.take(3).toList();
    
    for (var config in toTest) {
      final cached = serverCache[config];
      if (cached == null || cached.isStale) {
        await _testServerWithPing(config);
      }
    }
  }

  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      isSubscriptionValid = false;
      return false;
    }

    try {
      final resp = await http
          .get(Uri.parse(currentSubscriptionLink!),
              headers: {'User-Agent': 'AsadVPN/1.0'})
          .timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200 || resp.body.contains('<!DOCTYPE')) {
        isSubscriptionValid = false;
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

      configServers = vless.isNotEmpty
          ? vless
          : (vmess.isNotEmpty ? vmess : (trojan.isNotEmpty ? trojan : lines));

      isSubscriptionValid = configServers.isNotEmpty;
      return isSubscriptionValid;
    } catch (e) {
      isSubscriptionValid = false;
      return false;
    }
  }

  static Future<bool> saveSubscriptionLink(String link) async {
    try {
      link = link.trim().replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');

      if (!link.startsWith('http')) return false;

      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);

      final ok = await validateSubscription();
      if (!ok) {
        await prefs.remove('subscription_link');
        currentSubscriptionLink = null;
      }
      return ok;
    } catch (e) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    if (configServers.isEmpty) {
      return {'success': false, 'error': 'No servers'};
    }

    isScanning = true;
    scanProgress = 0;
    
    // Prioritize: top servers > cached servers > new servers
    final prioritized = _prioritizeServers();
    final batch = prioritized.take(min(20, prioritized.length)).toList();
    
    totalToScan = batch.length;
    scanProgressController.add(0);

    final List<ServerInfo?> results = [];
    
    for (int i = 0; i < batch.length; i++) {
      final result = await _testServerWithPing(batch[i]).timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      results.add(result);
      scanProgress = i + 1;
      scanProgressController.add(scanProgress);
      
      // Update UI incrementally
      if (result != null) {
        fastestServers.add(result);
        fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
        serversStreamController.add(fastestServers);
      }
    }

    final working = results.whereType<ServerInfo>().toList()
      ..sort((a, b) => a.ping.compareTo(b.ping));

    fastestServers = working;
    serversStreamController.add(fastestServers);
    isScanning = false;

    if (working.isNotEmpty) {
      // Update top servers list
      await _updateTopServers(working.map((s) => s.config).toList());
      
      return {
        'success': true,
        'server': working.first.config,
        'ping': working.first.ping
      };
    }

    return {'success': false, 'error': 'No working servers'};
  }

  static List<String> _prioritizeServers() {
    final Set<String> processed = {};
    final List<String> result = [];

    // 1. Top servers first
    for (var config in topServers) {
      if (configServers.contains(config) && !processed.contains(config)) {
        result.add(config);
        processed.add(config);
      }
    }

    // 2. Cached servers with good success rate
    final goodCached = serverCache.entries
        .where((e) => e.value.successRate > 0.7 && configServers.contains(e.key))
        .map((e) => e.key)
        .where((c) => !processed.contains(c))
        .toList();
    result.addAll(goodCached);
    processed.addAll(goodCached);

    // 3. Rest of servers (shuffled)
    final remaining = configServers.where((c) => !processed.contains(c)).toList()
      ..shuffle(Random());
    result.addAll(remaining);

    return result;
  }

  static Future<void> _updateTopServers(List<String> servers) async {
    topServers = servers.take(5).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('top_servers', topServers);
  }

  static Future<ServerInfo?> _testServerWithPing(String uri) async {
    try {
      final parser = V2ray.parseFromURL(uri);
      final config = parser.getFullConfiguration();

      // Check cache first
      final cached = serverCache[uri];
      if (cached != null && !cached.isStale) {
        debugPrint('✅ [CACHED] ${cached.name}: ${cached.lastPing}ms');
        return ServerInfo(
          config: uri,
          protocol: cached.protocol,
          ping: cached.lastPing,
          name: cached.name,
          successRate: cached.successRate,
          lastConnected: cached.lastConnected,
        );
      }

      final delay = await v2ray.getServerDelay(config: config);

      if (delay != -1 && delay < 5000) {
        debugPrint('✅ ${parser.remark}: ${delay}ms');

        // Update cache
        final existing = serverCache[uri];
        serverCache[uri] = ServerCache(
          config: uri,
          name: parser.remark,
          protocol: _getProtocol(uri),
          lastPing: delay,
          lastTested: DateTime.now(),
          successCount: existing?.successCount ?? 0,
          failureCount: existing?.failureCount ?? 0,
          lastConnected: existing?.lastConnected,
        );
        await _saveCache();

        return ServerInfo(
          config: uri,
          protocol: _getProtocol(uri),
          ping: delay,
          name: parser.remark,
          successRate: serverCache[uri]!.successRate,
        );
      } else {
        // Update failure count
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
          await _saveCache();
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
    return 'UNKNOWN';
  }

  static Future<bool> connect({required String vlessUri, int? ping}) async {
    if (kIsWeb || !Platform.isAndroid) return false;

    try {
      if (isConnected) {
        await disconnect();
        await Future.delayed(const Duration(milliseconds: 500));
      }

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

        // Update success count & last connected
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

        // Save as last good server
        lastGoodServer = vlessUri;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_good_server', vlessUri);
        await _saveCache();

        debugPrint('✅ Connected successfully');
        return true;
      }
      return false;
    } catch (e) {
      // Update failure count
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
        await _saveCache();
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
      // Save session stats
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
      connectionStateController.add(false);
    }
  }
}
