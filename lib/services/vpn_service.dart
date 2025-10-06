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

// Simple tuple for host:port
class _HostPort {
  final String host;
  final int port;
  _HostPort(this.host, this.port);
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

  // Background scanning / auto-scan, cancel & progress
  static Timer? _healthCheckTimer;
  static bool _isBackgroundScanning = false;
  static DateTime? _lastConnectionTime;
  static bool _isManualDisconnect = false;
  static bool _cancelScan = false;
  static bool _cancelAutoScan = false;
  static int _lastScannedIndex = 0;

  // Fast prefilter knobs (only when NOT connected)
  // Try many sockets in parallel to quickly drop dead configs.
  static const int _fastTcpTimeoutMs = 300; // quick socket timeout per target
  static const int _fastPrefilterConcurrency = 60; // high concurrency
  // v2ray delay test timeout
  static const Duration _delayTimeout = Duration(seconds: 4); // RELIABLE

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

      _startHealthCheck();
    } catch (e, stack) {
      debugPrint('❌ Init error: $e\n$stack');
    }
  }

  // Auto-scan with FAST PREFILTER (only when NOT connected)
  static Future<void> _autoScanServers({int resumeFromIndex = 0}) async {
    if (_isBackgroundScanning) {
      debugPrint('⚠️ Auto-scan already running, skipping');
      return;
    }

    _isBackgroundScanning = true;
    _cancelAutoScan = false;

    if (resumeFromIndex == 0) {
      await Future.delayed(const Duration(milliseconds: 600));
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

      final startMsg = resumeFromIndex > 0 ? 'resuming from index $resumeFromIndex' : 'starting fresh';
      debugPrint('🔵 Auto-scan (fast prefilter): $startMsg');

      // Build prioritized (shuffled) list
      final prioritized = _prioritizeServers();

      // FAST PREFILTER (TCP reachability, high concurrency)
      final List<String> subset = prioritized.sublist(
        min(resumeFromIndex, prioritized.length),
        prioritized.length,
      );
      final reachable = await _fastPrefilterAll(subset);

      if (_cancelAutoScan || isConnected) {
        debugPrint('🛑 Auto-scan cancelled or connected during prefilter');
        return;
      }

      debugPrint('🔵 Prefilter done: ${reachable.length} candidates (TCP reachable)');

      // Now do real v2ray delay test (sequential, 4s timeout) until we have 11
      int tested = 0;
      for (final uri in reachable) {
        if (isConnected || _cancelAutoScan) break;
        if (fastestServers.length >= 11) break;

        // Save progress
        if (tested % 5 == 0) {
          _lastScannedIndex = resumeFromIndex + tested;
          await _saveProgress();
        }

        tested++;

        final result = await _testServerWithPing(uri).timeout(
          _delayTimeout,
          onTimeout: () => null,
        );
        if (result != null) {
          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            serversStreamController.add(List.from(fastestServers));
            debugPrint('✅ Auto-scan: Added ${result.name} (${result.ping}ms) => ${fastestServers.length}/11');

            if (fastestServers.length % 3 == 0) {
              await _updateTopServers(fastestServers.map((s) => s.config).toList());
            }
          }
        }
      }

      if (!isConnected && fastestServers.isNotEmpty) {
        await _updateTopServers(fastestServers.map((s) => s.config).toList());
        if (fastestServers.length >= 11) {
          debugPrint('🎉 Auto-scan SUCCESS: 11 servers ready!');
          _lastScannedIndex = 0;
          await _saveProgress();
        } else {
          debugPrint('📊 Auto-scan paused: ${fastestServers.length}/11 servers (will resume at index $_lastScannedIndex)');
        }
      }
    } catch (e) {
      debugPrint('❌ Auto-scan error: $e');
    } finally {
      _isBackgroundScanning = false;
      _cancelAutoScan = false;
    }
  }

  // Fast prefilter phase: run many simultaneous TCP connects with tiny timeout
  static Future<List<String>> _fastPrefilterAll(List<String> uris) async {
    final reachable = <String>[];
    if (uris.isEmpty) return reachable;

    await _forEachWithConcurrency<String>(
      uris,
      _fastPrefilterConcurrency,
      (uri) async {
        if (_cancelAutoScan || isConnected) return;
        final hp = _extractHostPort(uri);
        if (hp == null) return;
        final ok = await _tcpReachable(hp.host, hp.port, Duration(milliseconds: _fastTcpTimeoutMs));
        if (ok) {
          reachable.add(uri);
        }
      },
    );
    return reachable;
  }

  static Future<bool> _tcpReachable(String host, int port, Duration timeout) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _forEachWithConcurrency<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T item) worker,
  ) async {
    int index = 0;
    Future<void> runner() async {
      while (true) {
        if (_cancelAutoScan || isConnected) return;
        final i = index;
        if (i >= items.length) break;
        index = i + 1;
        try {
          await worker(items[i]);
        } catch (_) {}
      }
    }

    final count = min(concurrency, items.length);
    await Future.wait(List.generate(count, (_) => runner()));
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

      if (currentSubscriptionLink == link && link.isNotEmpty) {
        debugPrint('✅ Subscription link unchanged, keeping existing');
        return true;
      }

      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);

      try {
        final valid = await validateSubscription();
        if (!valid) {
          await prefs.remove('subscription_link');
          currentSubscriptionLink = null;
        } else {
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
        debugPrint('⚠️ Cannot validate subscription (${e.message}), but keeping it saved');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Save subscription error: $e');
      return false;
    }
  }

  // Connect flow: 1) test displayed servers first, then 2) scan new (shuffled), all with 4s timeout.
  static Future<Map<String, dynamic>> scanAndSelectBestServer({bool connectImmediately = true}) async {
    if (_isBackgroundScanning) {
      _cancelAutoScan = true;
      debugPrint('🛑 Cancelling auto-scan (user clicked connect)');
      await Future.delayed(const Duration(milliseconds: 200));
    }

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

    // STEP 0: Test displayed servers FIRST (fastest first)
    if (fastestServers.isNotEmpty) {
      debugPrint('🔵 Testing ${fastestServers.length} displayed servers first...');
      final sortedDisplayed = List<ServerInfo>.from(fastestServers)..sort((a, b) => a.ping.compareTo(b.ping));

      for (int i = 0; i < sortedDisplayed.length && !_cancelScan; i++) {
        debugPrint('🔵 Testing displayed server ${i + 1}/${sortedDisplayed.length}: ${sortedDisplayed[i].name}...');
        final result = await _testServerWithPing(sortedDisplayed[i].config).timeout(
          _delayTimeout,
          onTimeout: () {
            debugPrint('⏱️ Displayed server timeout (${sortedDisplayed[i].name})');
            return null;
          },
        );

        if (result != null) {
          debugPrint('✅ Displayed server working: ${result.name} (${result.ping}ms)');
          if (connectImmediately) {
            isScanning = false;

            final index = fastestServers.indexWhere((s) => s.config == result.config);
            if (index != -1) {
              fastestServers[index] = result;
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              serversStreamController.add(List.from(fastestServers));
            }

            await connect(vlessUri: result.config, ping: result.ping);
            debugPrint('🔵 Connected to displayed server');
            return {'success': true, 'server': result.config, 'ping': result.ping};
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

      if (fastestServers.isEmpty) {
        debugPrint('⚠️ All displayed servers failed, scanning for new ones...');
      }
    }

    // STEP 1: Scan new servers (PRIORITIZED + SHUFFLED)
    debugPrint('🔵 Scanning for new servers (shuffled)...');
    final prioritized = _prioritizeServers();

    int tested = 0;
    for (var config in prioritized) {
      if (tested >= 30 || _cancelScan) break;
      tested++;
      debugPrint('🔵 Testing new server $tested/30...');

      final result = await _testServerWithPing(config).timeout(
        _delayTimeout,
        onTimeout: () {
          debugPrint('⏱️ New server test timeout');
          return null;
        },
      );

      if (result != null) {
        debugPrint('✅ Found working server: ${result.name} (${result.ping}ms)');
        if (connectImmediately) {
          isScanning = false;

          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            serversStreamController.add(List.from(fastestServers));
          }

          await _updateTopServers(fastestServers.map((s) => s.config).toList());
          await connect(vlessUri: result.config, ping: result.ping);

          debugPrint('🔵 Connected to new server');
          return {'success': true, 'server': result.config, 'ping': result.ping};
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

  // Prioritize & SHUFFLE
  static List<String> _prioritizeServers() {
    final Set<String> processed = {};
    final List<String> result = [];

    // 1) Top servers first
    for (var config in topServers) {
      if (configServers.contains(config) && !processed.contains(config)) {
        result.add(config);
        processed.add(config);
      }
    }

    // 2) Good cached
    final goodCached = serverCache.entries
        .where((e) =>
            e.value.successRate > 0.7 &&
            configServers.contains(e.key) &&
            !topServers.contains(e.key) &&
            !scannedServers.contains(e.key))
        .map((e) => e.key)
        .where((c) => !processed.contains(c))
        .toList();
    goodCached.shuffle(Random());
    result.addAll(goodCached);
    processed.addAll(goodCached);

    // 3) Rest (SHUFFLED)
    final remaining = configServers
        .where((c) => !processed.contains(c) && !topServers.contains(c) && !scannedServers.contains(c))
        .toList()
      ..shuffle(Random());
    result.addAll(remaining);

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

      final delay = await v2ray.getServerDelay(config: config).timeout(
        _delayTimeout,
        onTimeout: () => -1,
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

  // Extract host:port from different schemes to do a TCP prefilter
  static _HostPort? _extractHostPort(String uri) {
    try {
      if (uri.startsWith('vmess://')) {
        final b64 = uri.substring(8);
        final fixed = _fixBase64(b64);
        final jsonStr = utf8.decode(base64.decode(fixed));
        final map = jsonDecode(jsonStr);
        final host = (map['add'] ?? '').toString();
        final port = int.tryParse((map['port'] ?? '').toString()) ?? map['port'] ?? 0;
        if (host.isNotEmpty && port > 0) return _HostPort(host, port);
        return null;
      }

      if (uri.startsWith('vless://') || uri.startsWith('trojan://')) {
        final i = uri.indexOf('://');
        var rest = uri.substring(i + 3);
        final at = rest.lastIndexOf('@');
        if (at != -1) rest = rest.substring(at + 1);
        // Cut params
        rest = rest.split('?').first.split('#').first.split('/').first;
        // IPv6
        if (rest.startsWith('[')) {
          final close = rest.indexOf(']');
          if (close > 0) {
            final host = rest.substring(1, close);
            final after = rest.substring(close + 1);
            final portStr = after.startsWith(':') ? after.substring(1) : '';
            final port = int.tryParse(portStr) ?? 0;
            if (host.isNotEmpty && port > 0) return _HostPort(host, port);
          }
          return null;
        } else {
          final lastColon = rest.lastIndexOf(':');
          if (lastColon > 0) {
            final host = rest.substring(0, lastColon);
            final port = int.tryParse(rest.substring(lastColon + 1)) ?? 0;
            if (host.isNotEmpty && port > 0) return _HostPort(host, port);
          }
          return null;
        }
      }

      if (uri.startsWith('ss://')) {
        final raw = uri.substring(5);
        String work = raw.split('#').first; // drop tag
        if (work.contains('@')) {
          // ss://method:pass@host:port
          final afterAt = work.split('@').last;
          final hp = afterAt.split('?').first.split('/').first;
          final lastColon = hp.lastIndexOf(':');
          if (lastColon > 0) {
            final host = hp.substring(0, lastColon);
            final port = int.tryParse(hp.substring(lastColon + 1)) ?? 0;
            if (host.isNotEmpty && port > 0) return _HostPort(host, port);
          }
        } else {
          // ss://BASE64(method:pass@host:port)
          final fixed = _fixBase64(work);
          final decoded = utf8.decode(base64.decode(fixed));
          final afterAt = decoded.split('@').last;
          final hp = afterAt.split('?').first.split('/').first;
          final lastColon = hp.lastIndexOf(':');
          if (lastColon > 0) {
            final host = hp.substring(0, lastColon);
            final port = int.tryParse(hp.substring(lastColon + 1)) ?? 0;
            if (host.isNotEmpty && port > 0) return _HostPort(host, port);
          }
        }
        return null;
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  static String _fixBase64(String b64) {
    var s = b64.trim().replaceAll('\n', '');
    final mod = s.length % 4;
    if (mod > 0) s += '=' * (4 - mod);
    return s;
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
    _healthCheckTimer?.cancel();
    serversStreamController.close();
    connectionStateController.close();
    statusStreamController.close();
    scanProgressController.close();
  }
}

void unawaited(Future<void> future) {}
