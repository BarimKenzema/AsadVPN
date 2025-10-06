import 'dart.async';
import 'dart.convert';
import 'dart.io';
import 'dart.math';
import 'package.flutter/foundation.dart';
import 'package.flutter_v2ray/flutter_v2ray.dart';
import 'package.http/http.dart' as http;
import 'package.shared_preferences/shared_preferences.dart';
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

  // Caching
  static Map<String, ServerCache> serverCache = {};
  static String? lastGoodServer;
  static List<String> topServers = [];

  // Stats & Timers
  static int sessionDownload = 0;
  static int sessionUpload = 0;
  static List<ConnectionStats> dailyStats = [];
  static Timer? _healthCheckTimer;
  static bool _isBackgroundScanning = false;

  static final StreamController<List<ServerInfo>> serversStreamController =
      StreamController<List<ServerInfo>>.broadcast();
  static final StreamController<bool> connectionStateController =
      StreamController<bool>.broadcast();
  static final StreamController<V2RayStatus> statusStreamController =
      StreamController<V2RayStatus>.broadcast();
  static final StreamController<String> scanStatusController =
      StreamController<String>.broadcast();

  static void _updateConnectionState(V2RayStatus status) {
    final newIsConnected = status.state == 'CONNECTED';
    if (newIsConnected) {
      sessionDownload = status.download;
      sessionUpload = status.upload;
    }
    statusStreamController.add(status);
    if (isConnected != newIsConnected) {
      isConnected = newIsConnected;
      connectionStateController.add(isConnected);
      if (!newIsConnected && currentConnectedConfig != null) {
        _handleDisconnect();
      }
    }
  }

  static void _handleDisconnect() {
    Future.delayed(const Duration(seconds: 2), () async {
      if (!isConnected && fastestServers.isNotEmpty) {
        await connect(vlessUri: fastestServers.first.config, ping: fastestServers.first.ping);
      }
    });
  }

  static Future<void> init() async {
    try {
      await v2ray.initialize(
          notificationIconResourceName: "ic_launcher",
          notificationIconResourceType: "mipmap");
      await _loadCache();
      await _loadStats();
      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      lastGoodServer = prefs.getString('last_good_server');
      topServers = prefs.getStringList('top_servers') ?? [];
      if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
        isSubscriptionValid = true; // Assume valid, verify on connect
      }
      _updateFastestServersFromCache(); // Show cached servers immediately
    } catch (e) {
      debugPrint('❌ Init error: $e');
    }
  }

  static void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (isConnected) {
        final delay = await v2ray.getConnectedServerDelay();
        if (delay == -1) _handleDisconnect();
      }
    });
  }

  static Future<void> _loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheJson = prefs.getString('server_cache');
    if (cacheJson != null) {
      serverCache = (jsonDecode(cacheJson) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, ServerCache.fromJson(v)));
    }
  }

  static Future<void> _saveCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_cache',
        jsonEncode(serverCache.map((k, v) => MapEntry(k, v.toJson()))));
  }

  static void _updateFastestServersFromCache() {
    fastestServers = serverCache.values
        .where((c) => c.lastPing > 0)
        .map((c) => ServerInfo(
              config: c.config,
              protocol: c.protocol,
              ping: c.lastPing,
              name: c.name,
              successRate: c.successRate,
              lastConnected: c.lastConnected,
            ))
        .toList()
      ..sort((a, b) => a.ping.compareTo(b.ping));
    serversStreamController.add(List.from(fastestServers));
  }

  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) return false;
    try {
      final resp = await http.get(Uri.parse(currentSubscriptionLink!), headers: {'User-Agent': 'AsadVPN/1.0'});
      if (resp.statusCode != 200) return false;
      var content = resp.body;
      if (!content.contains('://')) content = utf8.decode(base64.decode(content.trim()));
      final lines = content.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
      configServers = lines.where((l) => l.startsWith('vless://') || l.startsWith('vmess://') || l.startsWith('trojan://') || l.startsWith('ss://')).toList();
      return configServers.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> saveSubscriptionLink(String link) async {
    link = link.trim();
    if (!link.startsWith('http')) return false;
    final prefs = await SharedPreferences.getInstance();
    currentSubscriptionLink = link;
    await prefs.setString('subscription_link', link);
    isSubscriptionValid = true;
    return true;
  }

  static Future<Map<String, dynamic>> scanAndSelectBestServer() async {
    isScanning = true;
    scanStatusController.add('Checking subscription...');
    if (!await validateSubscription()) {
      isScanning = false;
      return {'success': false, 'error': 'Subscription invalid or unreachable'};
    }
    
    fastestServers.clear(); // Clear old list for fresh pings
    
    // Test top servers first, then others
    final prioritized = _prioritizeServers();
    
    bool hasConnected = false;
    const batchSize = 3;

    scanStatusController.add('Finding fastest server...');
    for (int i = 0; i < prioritized.length && !hasConnected; i += batchSize) {
      final chunk = prioritized.sublist(i, min(i + batchSize, prioritized.length));
      final futures = chunk.map((c) => _testServerWithPing(c).timeout(const Duration(seconds: 4))).toList();
      final results = await Future.wait(futures);
      
      final working = results.whereType<ServerInfo>().toList()..sort((a,b) => a.ping.compareTo(b.ping));
      
      if (working.isNotEmpty) {
        hasConnected = true;
        final best = working.first;
        unawaited(connect(vlessUri: best.config, ping: best.ping));
        fastestServers = working; // Show the first batch of working servers
        serversStreamController.add(List.from(fastestServers));
        isScanning = false;
        return {'success': true, 'server': best.config, 'ping': best.ping};
      }
    }

    isScanning = false;
    return {'success': false, 'error': 'No working servers found'};
  }

  static Future<void> _backgroundScan() async {
    if (_isBackgroundScanning || isConnected) return; // Don't scan if already scanning or connected
    
    _isBackgroundScanning = true;
    scanStatusController.add('Updating server list...');

    final serversToScan = _prioritizeServers().where((c) => !fastestServers.any((s) => s.config == c)).toList();
    const maxServers = 11;
    
    for (final config in serversToScan) {
      if (fastestServers.length >= maxServers) break;
      final result = await _testServerWithPing(config).timeout(const Duration(seconds: 4), onTimeout: () => null);
      if (result != null && !fastestServers.any((s) => s.config == result.config)) {
        fastestServers.add(result);
        fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
        serversStreamController.add(List.from(fastestServers));
      }
    }
    
    await _updateTopServers(fastestServers.map((s) => s.config).toList());
    _isBackgroundScanning = false;
    scanStatusController.add('');
  }

  static List<String> _prioritizeServers() {
    final processed = <String>{};
    final result = <String>[];
    for (var config in topServers) {
      if (configServers.contains(config) && processed.add(config)) result.add(config);
    }
    final remaining = configServers.where((c) => !processed.contains(c)).toList()..shuffle();
    result.addAll(remaining);
    return result;
  }

  static Future<void> _updateTopServers(List<String> servers) async {
    topServers = servers.take(11).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('top_servers', topServers);
  }

  static Future<ServerInfo?> _testServerWithPing(String uri) async {
    try {
      final parser = V2ray.parseFromURL(uri);
      final delay = await v2ray.getServerDelay(config: parser.getFullConfiguration());
      if (delay != -1) {
        final existing = serverCache[uri];
        serverCache[uri] = ServerCache(config: uri, name: parser.remark, protocol: _getProtocol(uri), lastPing: delay, lastTested: DateTime.now(), successCount: (existing?.successCount ?? 0) + 1, failureCount: existing?.failureCount ?? 0, lastConnected: existing?.lastConnected);
        unawaited(_saveCache());
        return ServerInfo(config: uri, protocol: _getProtocol(uri), ping: delay, name: parser.remark, successRate: serverCache[uri]!.successRate);
      }
    } catch (e) {/* Ignore errors */}
    final existing = serverCache[uri];
    if (existing != null) {
      serverCache[uri] = ServerCache(config: uri, name: existing.name, protocol: existing.protocol, lastPing: -1, lastTested: DateTime.now(), successCount: existing.successCount, failureCount: existing.failureCount + 1);
      unawaited(_saveCache());
    }
    return null;
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
      if (isConnected) await disconnect();
      final parser = V2ray.parseFromURL(vlessUri);
      if (await v2ray.requestPermission()) {
        await v2ray.startV2Ray(remark: parser.remark, config: parser.getFullConfiguration(), proxyOnly: false, bypassSubnets: []);
        currentConnectedConfig = vlessUri;
        currentConnectedPing = ping;
        lastGoodServer = vlessUri;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_good_server', vlessUri);
        final existing = serverCache[vlessUri];
        if (existing != null) {
          serverCache[vlessUri] = ServerCache(config: vlessUri, name: existing.name, protocol: existing.protocol, lastPing: existing.lastPing, lastTested: existing.lastTested, successCount: existing.successCount, failureCount: existing.failureCount, lastConnected: DateTime.now());
          unawaited(_saveCache());
        }
        _startHealthCheck();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('❌ Connection error: $e');
      return false;
    }
  }

  static Future<void> disconnect() async {
    _healthCheckTimer?.cancel();
    try {
      await v2ray.stopV2Ray();
    } catch (e) {
      debugPrint('❌ Disconnect error: $e');
    } finally {
      isConnected = false;
      currentConnectedConfig = null;
      currentConnectedPing = null;
      connectionStateController.add(false);
      // After disconnecting, refresh the server list
      unawaited(_backgroundScan());
    }
  }
  
  // Stubs for methods you'll need later
  static Future<void> _loadStats() async {}
  static Future<void> _saveStats() async {}
  static Future<bool> connectToLastGoodServer() async { return false; }
  static void dispose() {
    _healthCheckTimer?.cancel();
    serversStreamController.close();
    connectionStateController.close();
    statusStreamController.close();
    scanStatusController.close();
  }
}

void unawaited(Future<void> future) {}