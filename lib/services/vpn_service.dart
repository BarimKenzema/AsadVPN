// ===================== vpn_service.dart (Part 1/2) =====================
// Paste Part 1/2 and Part 2/2 back-to-back in the same file (vpn_service.dart)

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
  static const Duration bgVerifyTimeout = Duration(seconds: 2); // verifying while app is foregrounded
  static const Duration tcpFastTimeout = Duration(milliseconds: 400); // TCP prefilter
  static const int tcpFastConcurrency = 120; // high concurrency for TCP prefilter

  // Hourly subscription refresh and priorities
  static Timer? _subscriptionRefreshTimer;
  static DateTime? _lastSubRefreshAt;
  static bool _refreshInProgress = false;
  static final Set<String> _priorityNew = {}; // newly-added configs take priority

  // Pruning of stale/failing servers
  static const int _pruneFailureThreshold = 5;
  static const Duration _pruneStaleAge = Duration(hours: 48);

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

  static Set<String> scannedServers = {}; // prevent immediate re-scan churn

  // Stats
  static int sessionDownload = 0;
  static int sessionUpload = 0;
  static List<ConnectionStats> dailyStats = [];

  // Background scanning (while app is active)
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
        debugPrint('🛑 Cancelling auto-fill (connection established)');
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
      // Use Cloudflare domain as probe to avoid Google blocks
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

  // Public: used by main.dart on app resume
  static void resumeAutoScan() {
    // Refresh subscription if due, then try a small fill for the list
    unawaited(_refreshSubscriptionIfDue(forceIfElapsed: true));
    if (!isConnected && fastestServers.length < 11 && currentSubscriptionLink != null && !_isBackgroundScanning) {
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

      // Initial refresh on startup
      unawaited(_refreshSubscriptionIfDue(forceIfElapsed: true));

      // Auto discovery when not connected and fewer than 11 in display
      if (currentSubscriptionLink != null &&
          currentSubscriptionLink!.isNotEmpty &&
          !isConnected &&
          fastestServers.length < 11) {
        debugPrint('🔵 Starting auto-scan for 11 servers (from index $_lastScannedIndex)...');
        unawaited(_autoScanServers(resumeFromIndex: _lastScannedIndex));
      }

      _startHealthCheck();
      _startSubscriptionRefreshTimer(); // hourly refresh
    } catch (e, stack) {
      debugPrint('❌ Init error: $e\n$stack');
    }
  }

  // ========================= HOURLY SUBSCRIPTION REFRESH =========================
  static void _startSubscriptionRefreshTimer() {
    _subscriptionRefreshTimer?.cancel();
    _subscriptionRefreshTimer = Timer.periodic(const Duration(hours: 1), (_) async {
      await _refreshSubscriptionIfDue(forceIfElapsed: true);
    });
  }

  // Refresh subscription if > 1 hour since last refresh (or forced), diff and prioritize new configs,
  // prune stale failures, and optionally verify a couple of new entries when not connected.
  static Future<void> _refreshSubscriptionIfDue({bool forceIfElapsed = false}) async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) return;
    if (_refreshInProgress) return;

    final now = DateTime.now();
    if (!forceIfElapsed &&
        _lastSubRefreshAt != null &&
        now.difference(_lastSubRefreshAt!) < const Duration(hours: 1)) {
      return;
    }

    _refreshInProgress = true;
    try {
      final oldSet = configServers.toSet();

      final valid = await validateSubscription(); // also sets isSubscriptionValid
      if (!valid) {
        // Hard gate: subscription ended → clear lists and disconnect
        await _onSubscriptionInvalid();
        return;
      }

      final newSet = configServers.toSet();
      final newlyAdded = newSet.difference(oldSet);
      // We don't auto-delete removed ones; they may still work. They will be pruned if stale/failing.
      if (newlyAdded.isNotEmpty) {
        _priorityNew.addAll(newlyAdded);
        debugPrint('🆕 ${newlyAdded.length} new configs prioritized for scan');
      }

      // Prune stale/failing cached entries to keep lists fresh
      _pruneStaleFailures();

      // Optionally verify a few new ones quickly when not connected
      if (!isConnected && newlyAdded.isNotEmpty) {
        final toVerify = newlyAdded.take(4).toList();
        for (final cfg in toVerify) {
          // verify with short timeout, add to display if good
          final si = await _testServerWithPing(cfg, timeout: bgVerifyTimeout);
          if (si != null) {
            if (!fastestServers.any((s) => s.config == si.config)) {
              final cached = serverCache[si.config];
              final add = ServerInfo(
                config: si.config,
                protocol: cached?.protocol ?? _getProtocol(si.config),
                ping: cached?.lastPing ?? si.ping,
                name: cached?.name ?? si.name,
                successRate: cached?.successRate ?? 0.0,
                lastConnected: cached?.lastConnected,
              );
              fastestServers.add(add);
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              serversStreamController.add(List.from(fastestServers));
              _updatePersistentLists(newConfigs: [si.config]);
            }
          }
        }
      }

      _lastSubRefreshAt = now;
    } catch (e) {
      debugPrint('❌ Subscription refresh error: $e');
    } finally {
      _refreshInProgress = false;
    }
  }

  // Clear all lists and disconnect if subscription is invalid/ended.
  static Future<void> _onSubscriptionInvalid() async {
    debugPrint('⛔ Subscription invalid/expired → disconnect and clear cached lists');
    // Disconnect if connected
    if (isConnected) {
      try {
        _isManualDisconnect = true;
        await v2ray.stopV2Ray();
      } catch (_) {}
      isConnected = false;
      currentConnectedConfig = null;
      currentConnectedPing = null;
      sessionDownload = 0;
      sessionUpload = 0;
      connectionStateController.add(false);
    }

    // Clear lists to prevent connecting to cached servers
    fastestServers.clear();
    topServers.clear();
    knownGoodServers.clear();
    configServers.clear();
    scannedServers.clear();
    _priorityNew.clear();

    // Persist cleared lists for UI
    await _savePersistentLists();
    serversStreamController.add(List.from(fastestServers));
  }

  // Prune entries that fail repeatedly and have been stale for a while.
  static void _pruneStaleFailures() {
    final now = DateTime.now();
    bool changed = false;

    bool shouldPrune(ServerCache? c) {
      if (c == null) return false;
      if (c.failureCount < _pruneFailureThreshold) return false;
      if (c.lastConnected != null) return false; // keep ones that connected recently
      if (c.lastTested == null) return false;
      return now.difference(c.lastTested!).abs() > _pruneStaleAge;
    }

    // Prune from topServers and knownGoodServers
    final toRemove = <String>{};

    for (final cfg in topServers) {
      if (shouldPrune(serverCache[cfg])) {
        toRemove.add(cfg);
      }
    }
    for (final cfg in knownGoodServers) {
      if (shouldPrune(serverCache[cfg])) {
        toRemove.add(cfg);
      }
    }

    if (toRemove.isNotEmpty) {
      debugPrint('🧹 Pruning ${toRemove.length} stale/failing servers from lists');
      topServers.removeWhere(toRemove.contains);
      knownGoodServers.removeWhere(toRemove.contains);
      fastestServers.removeWhere((s) => toRemove.contains(s.config));
      changed = true;
    }

    // Persist if changed
    if (changed) {
      unawaited(_savePersistentLists());
      serversStreamController.add(List.from(fastestServers));
    }
  }

  // ========================= AUTO-SCAN (unchanged core) =========================
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
      if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
        debugPrint('⚠️ No subscription link; skipping auto-scan');
        _isBackgroundScanning = false;
        return;
      }
      if (configServers.isEmpty) {
        final valid = await validateSubscription();
        if (!valid) {
          await _onSubscriptionInvalid();
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

      // Keep the previous set for diff in _refreshSubscriptionIfDue (we compute there)
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
        // Force refresh now that user interacted
        unawaited(_refreshSubscriptionIfDue(forceIfElapsed: true));
        return true;
      }

      currentSubscriptionLink = link;
      await prefs.setString('subscription_link', link);

      try {
        final valid = await validateSubscription();
        if (!valid) {
          await _onSubscriptionInvalid();
          await prefs.remove('subscription_link');
          currentSubscriptionLink = null;
        } else {
          _lastScannedIndex = 0;
          await _saveProgress();
          // Force refresh so priority-new diff runs immediately
          await _refreshSubscriptionIfDue(forceIfElapsed: true);
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

  // ========================= CONNECT FLOW (continues in Part 2/2) =========================
}
   // ========================= CONNECT FLOW =========================
  static Future<Map<String, dynamic>> scanAndSelectBestServer({bool connectImmediately = true}) async {
    // Stop any auto-fill that might be running
    if (_isBackgroundScanning) {
      _cancelAutoScan = true;
      debugPrint('🛑 Cancelling auto-fill (user clicked connect)');
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (!await hasInternetConnection()) {
      return {'success': false, 'error': 'No internet connection'};
    }

    // Enforce active subscription policy
    if (!isSubscriptionValid || currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      return {'success': false, 'error': 'Invalid subscription'};
    }

    if (configServers.isEmpty) {
      final valid = await validateSubscription();
      if (!valid) {
        await _onSubscriptionInvalid();
        return {'success': false, 'error': 'Invalid subscription'};
      }
    }

    isScanning = true;
    _cancelScan = false;
    scanProgress = 0;
    _lastConnectionTime = null;
    totalToScan = 0;
    scanProgressController.add(0);

    // Step 0: Test displayed servers first (soft-fail demote, don't delete)
    if (fastestServers.isNotEmpty) {
      debugPrint('🔵 Testing ${fastestServers.length} displayed servers first...');
      final sortedDisplayed = List<ServerInfo>.from(fastestServers)
        ..sort((a, b) => a.ping.compareTo(b.ping));

      for (int i = 0; i < sortedDisplayed.length && !_cancelScan; i++) {
        debugPrint('🔵 Testing displayed ${i + 1}/${sortedDisplayed.length}: ${sortedDisplayed[i].name}...');
        final result =
            await _testServerWithPing(sortedDisplayed[i].config, timeout: userTestTimeout)
                .timeout(userTestTimeout, onTimeout: () => null);

        if (result != null) {
          debugPrint('✅ Displayed server working: ${result.name} (${result.ping}ms)');
          if (connectImmediately) {
            isScanning = false;
            final idx = fastestServers.indexWhere((s) => s.config == result.config);
            if (idx != -1) {
              final s = fastestServers.removeAt(idx);
              fastestServers.insert(0, s);
              serversStreamController.add(List.from(fastestServers));
            }
            _commitSuccessToCurrentProfile(result.config);
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
            fastestServers.add(s);
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

    // Step 0.5: Fallback to knownGood first (dedup against display)
    final fallbacks = _fallbackKnownConfigs();
    if (!isConnected && fallbacks.isNotEmpty) {
      debugPrint('🔵 Fallback: testing known-good pool (${fallbacks.length})...');
      for (int i = 0; i < min(11, fallbacks.length) && !_cancelScan && !isConnected; i++) {
        final cfg = fallbacks[i];
        final result = await _testServerWithPing(cfg, timeout: userTestTimeout)
            .timeout(userTestTimeout, onTimeout: () => null);
        if (result != null) {
          isScanning = false;
          final cached = serverCache[cfg];
          final si = ServerInfo(
            config: cfg,
            protocol: cached?.protocol ?? _getProtocol(cfg),
            ping: cached?.lastPing ?? result.ping,
            name: cached?.name ?? 'Server',
            successRate: cached?.successRate ?? 0.0,
            lastConnected: cached?.lastConnected,
          );
          fastestServers.removeWhere((s) => s.config == cfg);
          fastestServers.insert(0, si);
          serversStreamController.add(List.from(fastestServers));
          _commitSuccessToCurrentProfile(cfg);
          await connect(vlessUri: cfg, ping: si.ping);
          debugPrint('🔵 Connected from known-good pool');
          return {'success': true, 'server': cfg, 'ping': si.ping};
        }
      }
    }

    // Step 1: Scan new servers (newest + shuffled, priority new first), 4s test
    debugPrint('🔵 Scanning for new servers (starting from newest + shuffled, priority new first)...');
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
          final cached = serverCache[config];
          final si = ServerInfo(
            config: config,
            protocol: cached?.protocol ?? _getProtocol(config),
            ping: cached?.lastPing ?? result.ping,
            name: cached?.name ?? result.name,
            successRate: cached?.successRate ?? 0.0,
            lastConnected: cached?.lastConnected,
          );
          fastestServers.removeWhere((s) => s.config == config);
          fastestServers.insert(0, si);
          serversStreamController.add(List.from(fastestServers));
          _commitSuccessToCurrentProfile(config);
          await connect(vlessUri: config, ping: si.ping);
          debugPrint('🔵 Connected to new server');
          return {'success': true, 'server': config, 'ping': si.ping};
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
    final displayed = fastestServers.map((s) => s.config).toSet();
    return knownGoodServers.where((c) => !displayed.contains(c)).toList();
  }

  // ========================= PRIORITY (includes newly-added) =========================
  static List<String> _prioritizeServers() {
    final Set<String> processed = {};
    final List<String> result = [];

    // 0) Newly added from last refresh get top priority (and exist in subscription)
    final pn = _priorityNew.where((c) => configServers.contains(c)).toList();
    for (final c in pn) {
      if (!processed.contains(c)) {
        result.add(c);
        processed.add(c);
      }
    }

    // 1) top servers first
    for (var config in topServers) {
      if (configServers.contains(config) && !processed.contains(config)) {
        result.add(config);
        processed.add(config);
      }
    }

    // 2) cached servers with good success rate
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

    // 3) rest of servers (newest first + shuffle)
    final remaining = configServers
        .where((c) => !processed.contains(c) && !topServers.contains(c))
        .toList();
    final reversed = remaining.reversed.toList()..shuffle(Random());
    result.addAll(reversed);

    return result;
  }

  // ========================= TESTS & HELPERS =========================
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
      return config;
    }
  }

  static Future<ServerInfo?> _testServerWithPing(String uri, {Duration? timeout}) async {
    try {
      final parser = V2ray.parseFromURL(uri);
      var config = parser.getFullConfiguration();
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
    int stopOnCount = 0,
  }) async {
    final survivors = <String>[];
    int index = 0;
    bool stop = false;

    Future<void> worker() async {
      while (true) {
        if (isConnected || _cancelAutoScan || stop) break;
        final i = index++;
        if (i >= configs.length) break;

        final config = configs[i];
        final hp = _extractHostPort(config);
        if (hp == null) continue;

        final ok = await _tcpProbe(hp.$1, hp.$2, timeout);
        if (ok) {
          survivors.add(config);
          if (stopOnCount > 0 && survivors.length >= stopOnCount) {
            stop = true;
            break;
          }
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

      // Clear display if subscription invalid to avoid showing stale list
      if (!isSubscriptionValid) {
        fastestServers.clear();
        serversStreamController.add(List.from(fastestServers));
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
    _subscriptionRefreshTimer?.cancel();
    _healthCheckTimer?.cancel();
    serversStreamController.close();
    connectionStateController.close();
    statusStreamController.close();
    scanProgressController.close();
  }
}
// ===================== end class VPNService =====================

// Helper to ignore unawaited futures
void unawaited(Future<void> future) {}
