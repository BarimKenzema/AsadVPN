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

class NetworkException implements Exception {
  final String message;
  NetworkException(this.message);
  @override
  String toString() => message;
}

class VPNService {
  static final V2ray v2ray = V2ray(onStatusChanged: _updateConnectionState);

  // Timeouts and concurrency knobs
  static const Duration userTestTimeout = Duration(seconds: 4); // user taps Connect
  static const Duration bgVerifyTimeout = Duration(seconds: 2); // background verify
  static const Duration tcpFastTimeout = Duration(milliseconds: 400); // TCP prefilter
  static const int tcpFastConcurrency = 120; // high concurrency for TCP prefilter

  static bool isConnected = false;
  static bool isSubscriptionValid = false;
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = []; // display list (up to 11)
  static bool isScanning = false;
  static String? currentConnectedConfig;
  static int? currentConnectedPing;
  static int scanProgress = 0;
  static int totalToScan = 0;

  // Caching
  static Map<String, ServerCache> serverCache = {};
  static String? lastGoodServer;

  // Persistent lists
  static List<String> topServers = []; // display 11
  static List<String> knownGoodServers = []; // persistent pool (up to 50)

  static Set<String> scannedServers = {}; // optional: prevent immediate re-scan churn

  // Stats
  static int sessionDownload = 0;
  static int sessionUpload = 0;
  static List<ConnectionStats> dailyStats = [];

  // Background scanning
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

  // ========================= STATUS =========================
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

      if (newIsConnected && _isBackgroundScanning) {
        _cancelAutoScan = true;
        debugPrint('🛑 Cancelling auto-scan (connection established)');
      }

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

  // ========================= NET / CONTROL =========================
  static Future<bool> hasInternetConnection() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        debugPrint('❌ No internet connection (connectivity check)');
        return false;
      }
      final result = await InternetAddress.lookup('cloudflare.com')
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

  // RE-ADDED: used by main.dart on app resume
  static void resumeAutoScan() {
    if (!isConnected &&
        fastestServers.length < 11 &&
        currentSubscriptionLink != null &&
        !_isBackgroundScanning) {
      debugPrint('🔵 Resuming auto-scan from index $_lastScannedIndex...');
      unawaited(_autoScanServers(resumeFromIndex: _lastScannedIndex));
    }
  }

  // ========================= INIT =========================
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
      await _loadPersistentLists();

      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      lastGoodServer = prefs.getString('last_good_server');
      _lastScannedIndex = prefs.getInt('last_scanned_index') ?? 0;

      // Preload display from topServers using cache
      if (topServers.isNotEmpty) {
        fastestServers = topServers
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

      // Auto discovery when not connected and fewer than 11 in display
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

  // ========================= AUTO-SCAN =========================
  // fast TCP prefilter + quick V2Ray verify (2s) until 11 servers
  static Future<void> _autoScanServers({int resumeFromIndex = 0}) async {
    if (_isBackgroundScanning) {
      debugPrint('⚠️ Auto-scan already running, skipping');
      return;
    }

    _isBackgroundScanning = true;
    _cancelAutoScan = false;

    if (resumeFromIndex == 0) {
      await Future.delayed(const Duration(milliseconds: 400));
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

      final startMsg =
          resumeFromIndex > 0 ? 'resuming from index $resumeFromIndex' : 'starting fresh';
      debugPrint('🔵 Auto-scan: Finding 11 servers ($startMsg)...');

      final prioritized = _prioritizeServers();

      // Stage A: TCP prefilter (very fast)
      final remaining = prioritized.sublist(resumeFromIndex);
      debugPrint('⚡ TCP prefiltering ${remaining.length} servers with concurrency $tcpFastConcurrency...');
      final tcpOk = await _tcpPrefilterConfigs(
        remaining,
        timeout: tcpFastTimeout,
        concurrency: tcpFastConcurrency,
        stopOnCount: 0, // scan all quickly
      );
      debugPrint('✅ TCP prefilter survivors: ${tcpOk.length}');

      // Stage B: Verify survivors sequentially (2s) until 11 servers
      for (int i = 0; i < tcpOk.length; i++) {
        if ((resumeFromIndex + i) % 5 == 0) {
          _lastScannedIndex = resumeFromIndex + i;
          await _saveProgress();
        }

        if (fastestServers.length >= 11 || isConnected || _cancelAutoScan) {
          if (isConnected) debugPrint('🛑 Auto-scan stopped: User connected');
          if (_cancelAutoScan) debugPrint('🛑 Auto-scan cancelled');
          break;
        }

        final config = tcpOk[i];
        final result = await _testServerWithPing(config, timeout: bgVerifyTimeout);
        if (result != null && !isConnected) {
          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            _updatePersistentLists(newConfigs: [result.config]);
            serversStreamController.add(List.from(fastestServers));
          }
        }
      }

      if (!isConnected) {
        _updatePersistentLists(); // persist after pass
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

  // ========================= LOAD / SAVE =========================
  static Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString('server_cache');
      if (cacheJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(cacheJson);
        serverCache = decoded.map((key, value) => MapEntry(key, ServerCache.fromJson(value)));
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

  static Future<void> _loadPersistentLists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      topServers = prefs.getStringList('top_servers') ?? [];
      knownGoodServers = prefs.getStringList('known_good_servers') ?? [];
      debugPrint('✅ Loaded top: ${topServers.length}, knownGood: ${knownGoodServers.length}');
    } catch (e) {
      debugPrint('❌ Persistent lists load error: $e');
    }
  }

  static Future<void> _savePersistentLists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('top_servers', topServers);
      await prefs.setStringList('known_good_servers', knownGoodServers);
    } catch (e) {
      debugPrint('❌ Persistent lists save error: $e');
    }
  }

  // Merge new configs into knownGood, refresh topServers from fastestServers (up to 11)
  static void _updatePersistentLists({List<String> newConfigs = const []}) {
    // merge into knownGood (dedupe, keep up to 50)
    if (newConfigs.isNotEmpty) {
      for (final c in newConfigs) {
        knownGoodServers.remove(c);
        knownGoodServers.insert(0, c);
      }
    }
    // ensure all displayed are in knownGood
    for (final s in fastestServers) {
      knownGoodServers.remove(s.config);
      knownGoodServers.insert(0, s.config);
    }
    // cap knownGood
    if (knownGoodServers.length > 50) {
      knownGoodServers = knownGoodServers.take(50).toList();
    }

    // build topServers from current display up to 11; if less, fill from knownGood
    final current = fastestServers.map((s) => s.config).toList();
    final fill = knownGoodServers.where((c) => !current.contains(c)).take(11 - current.length);
    topServers = [...current, ...fill].take(11).toList();

    unawaited(_savePersistentLists());
  }

  // ========================= SUBSCRIPTION =========================
  static Future<bool> validateSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      isSubscriptionValid = false;
      return false;
    }

    try {
      debugPrint('🔵 Validating subscription...');
      final resp = await http
          .get(Uri.parse(currentSubscriptionLink!), headers: {'User-Agent': 'AsadVPN/1.0'})
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

      debugPrint('🔵 Found: ${vless.length} VLESS, ${vmess.length} VMESS, ${trojan.length} TROJAN, ${ss.length} SS');

      configServers = [...vless, ...vmess, ...trojan, ...ss];
      if (configServers.isEmpty) configServers = lines;

      isSubscriptionValid = configServers.isNotEmpty;
      debugPrint('✅ Subscription valid: $isSubscriptionValid, servers: ${configServers.length}');
      return isSubscriptionValid;
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

  // ========================= CONNECT FLOW =========================
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
      final valid = await validateSubscription();
      if (!valid) return {'success': false, 'error': 'Invalid subscription or no servers'};
    }

    isScanning = true;
    _cancelScan = false;
    scanProgress = 0;
    _lastConnectionTime = null;
    totalToScan = 0;
    scanProgressController.add(0);

    // Step 0: Test displayed servers first (SOFT-FAIL: do not delete on single failure)
    if (fastestServers.isNotEmpty) {
      debugPrint('🔵 Testing ${fastestServers.length} displayed servers first...');
      final sortedDisplayed = List<ServerInfo>.from(fastestServers)
        ..sort((a, b) => a.ping.compareTo(b.ping));

      for (int i = 0; i < sortedDisplayed.length && !_cancelScan; i++) {
        debugPrint('🔵 Testing displayed server ${i + 1}/${sortedDisplayed.length}: ${sortedDisplayed[i].name}...');
        final result =
            await _testServerWithPing(sortedDisplayed[i].config, timeout: userTestTimeout)
                .timeout(userTestTimeout, onTimeout: () => null);

        if (result != null) {
          debugPrint('✅ Displayed server working: ${result.name} (${result.ping}ms)');
          if (connectImmediately) {
            isScanning = false;
            final index =
                fastestServers.indexWhere((s) => s.config == result.config);
            if (index != -1) {
              fastestServers[index] = result;
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              serversStreamController.add(List.from(fastestServers));
            }
            _updatePersistentLists();
            await connect(vlessUri: result.config, ping: result.ping);
            debugPrint('🔵 Connected to displayed server');
            return {'success': true, 'server': result.config, 'ping': result.ping};
          }
        } else {
          debugPrint('⚠️ Soft-fail (demote): ${sortedDisplayed[i].name}');
          _recordFailure(sortedDisplayed[i].config);
          final idx = fastestServers.indexWhere((s) => s.config == sortedDisplayed[i].config);
          if (idx != -1) {
            final s = fastestServers.removeAt(idx);
            fastestServers.add(s); // demote to bottom
            serversStreamController.add(List.from(fastestServers));
          }
        }
      }
      if (_cancelScan) {
        isScanning = false;
        _cancelScan = false;
        return {'success': false, 'error': 'Scan cancelled'};
      }
    }

    // Step 0.5: Fallback to knownGoodServers if display is empty or all failed
    if (!isConnected && fastestServers.isEmpty && knownGoodServers.isNotEmpty) {
      final fallback = _fallbackKnownConfigs();
      if (fallback.isNotEmpty) {
        debugPrint('🔵 Fallback: testing known-good pool (${fallback.length})...');
        for (int i = 0; i < min(11, fallback.length) && !_cancelScan && !isConnected; i++) {
          final cfg = fallback[i];
          final result =
              await _testServerWithPing(cfg, timeout: userTestTimeout).timeout(userTestTimeout, onTimeout: () => null);
          if (result != null) {
            isScanning = false;
            if (!fastestServers.any((s) => s.config == result.config)) {
              fastestServers.add(result);
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              serversStreamController.add(List.from(fastestServers));
            }
            _updatePersistentLists(newConfigs: [result.config]);
            await connect(vlessUri: result.config, ping: result.ping);
            debugPrint('🔵 Connected from known-good pool');
            return {'success': true, 'server': result.config, 'ping': result.ping};
          }
        }
      }
    }

    // Step 1: Scan new servers (newest + shuffled), 4s test
    debugPrint('🔵 Scanning for new servers (starting from newest + shuffled)...');
    final prioritized = _prioritizeServers();
    int tested = 0;
    for (var config in prioritized) {
      if (tested >= 30 || _cancelScan) break;
      tested++;
      debugPrint('🔵 Testing new server $tested/30...');
      final result = await _testServerWithPing(config, timeout: userTestTimeout)
          .timeout(userTestTimeout, onTimeout: () => null);
      if (result != null) {
        debugPrint('✅ Found working server: ${result.name} (${result.ping}ms)');
        if (connectImmediately) {
          isScanning = false;
          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            serversStreamController.add(List.from(fastestServers));
          }
          _updatePersistentLists(newConfigs: [result.config]);
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

  static List<String> _fallbackKnownConfigs() {
    // knownGood minus what’s already displayed, keep newest-first order
    final displayed = fastestServers.map((s) => s.config).toSet();
    return knownGoodServers.where((c) => !displayed.contains(c)).toList();
  }

  // ========================= PRIORITY =========================
  // top servers first; then cached good; then newest (reversed) and shuffled
  static List<String> _prioritizeServers() {
    final Set<String> processed = {};
    final List<String> result = [];

    for (var config in topServers) {
      if (configServers.contains(config) && !processed.contains(config)) {
        result.add(config);
        processed.add(config);
      }
    }

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

    final remaining = configServers
        .where((c) => !processed.contains(c) && !topServers.contains(c) && !scannedServers.contains(c))
        .toList();

    // Newest first, then shuffle to avoid same-order bias
    final reversed = remaining.reversed.toList()..shuffle(Random());
    result.addAll(reversed);

    return result;
  }

  static Future<void> _updateTopServers(List<String> servers) async {
    topServers = servers.take(11).toList();
    await _savePersistentLists();
  }

  // ========================= TESTS =========================
  // Patch config for DNS-over-HTTPS and IPv4 preference (helps on ISPs with DNS/SNI issues)
  static String _ensureDnsAndIPv4(String config) {
    try {
      final Map<String, dynamic> json = jsonDecode(config);
      json['dns'] ??= {};
      json['dns']['servers'] = [
        'https://1.1.1.1/dns-query',
        'https://dns.google/dns-query',
        '1.1.1.1',
        '8.8.8.8',
      ];
      json['routing'] ??= {};
      json['routing']['domainStrategy'] = 'UseIPv4';
      return jsonEncode(json);
    } catch (_) {
      return config; // if parsing fails, use original
    }
  }

  // Single V2Ray delay test with customizable timeout
  static Future<ServerInfo?> _testServerWithPing(String uri, {Duration? timeout}) async {
    try {
      final parser = V2ray.parseFromURL(uri);
      var config = parser.getFullConfiguration();

      // Patch config for DoH + IPv4 preference to survive hostile ISPs
      config = _ensureDnsAndIPv4(config);

      final effectiveTimeout = timeout ?? userTestTimeout;
      final delay = await v2ray.getServerDelay(config: config).timeout(
        effectiveTimeout,
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
          failureCount: (existing?.failureCount ?? 0),
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
        _recordFailure(uri);
      }
      return null;
    } catch (e) {
      _recordFailure(uri);
      return null;
    }
  }

  static void _recordFailure(String uri) {
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
        lastConnected: existing.lastConnected,
      );
      unawaited(_saveCache());
    }
  }

  // QUICK TCP PREFILTER (stage A)
  static Future<List<String>> _tcpPrefilterConfigs(
    List<String> configs, {
    required Duration timeout,
    required int concurrency,
    int stopOnCount = 0, // stop early if survivors reach this
  }) async {
    final survivors = <String>[];
    int index = 0;

    Future<void> worker() async {
      while (true) {
        if (isConnected || _cancelAutoScan) break;
        final i = index++;
        if (i >= configs.length) break;

        final config = configs[i];
        final hp = _extractHostPort(config);
        if (hp == null) continue;

        final ok = await _tcpProbe(hp.$1, hp.$2, timeout);
        if (ok) {
          survivors.add(config);
          if (stopOnCount > 0 && survivors.length >= stopOnCount) break;
        }
      }
    }

    final workers = List.generate(concurrency, (_) => worker());
    await Future.wait(workers);

    return survivors;
  }

  static Future<bool> _tcpProbe(String host, int port, Duration timeout) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static (String, int)? _extractHostPort(String uri) {
    try {
      if (uri.startsWith('vless://') || uri.startsWith('trojan://') || uri.startsWith('ss://')) {
        if (uri.startsWith('ss://')) {
          final hp = _parseSSHostPort(uri);
          if (hp != null) return hp;
        } else {
          final u = Uri.parse(uri);
          final host = u.host;
          final port = u.port != 0 ? u.port : 443;
          if (host.isNotEmpty) return (host, port);
        }
      } else if (uri.startsWith('vmess://')) {
        final hp = _parseVMessHostPort(uri);
        if (hp != null) return hp;
      }
    } catch (_) {}
    return null;
  }

  static (String, int)? _parseVMessHostPort(String uri) {
    try {
      final b64 = uri.substring('vmess://'.length);
      final jsonStr = utf8.decode(base64.decode(_normalizeB64(b64)));
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final host = (map['add'] ?? '').toString();
      final port = int.tryParse((map['port'] ?? '').toString()) ?? 443;
      if (host.isNotEmpty) return (host, port);
    } catch (_) {}
    return null;
  }

  static (String, int)? _parseSSHostPort(String uri) {
    try {
      var rest = uri.substring('ss://'.length);
      if (rest.contains('@')) {
        final u = Uri.parse(uri);
        final host = u.host;
        final port = u.port != 0 ? u.port : 443;
        if (host.isNotEmpty) return (host, port);
      } else {
        final hashIndex = rest.indexOf('#');
        if (hashIndex != -1) rest = rest.substring(0, hashIndex);
        final decoded = utf8.decode(base64.decode(_normalizeB64(rest)));
        final atIndex = decoded.lastIndexOf('@');
        if (atIndex != -1) {
          final hostPort = decoded.substring(atIndex + 1);
          final parts = hostPort.split(':');
          if (parts.length == 2) {
            final host = parts[0];
            final port = int.tryParse(parts[1]) ?? 443;
            if (host.isNotEmpty) return (host, port);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static String _normalizeB64(String b64) {
    var s = b64.replaceAll('-', '+').replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    return s;
  }

  static String _getProtocol(String uri) {
    if (uri.startsWith('vless://')) return 'VLESS';
    if (uri.startsWith('vmess://')) return 'VMESS';
    if (uri.startsWith('trojan://')) return 'TROJAN';
    if (uri.startsWith('ss://')) return 'SS';
    return 'UNKNOWN';
  }

  // ========================= CONNECT / DISCONNECT =========================
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

// Helper to ignore unawaited futures
void unawaited(Future<void> future) {}
