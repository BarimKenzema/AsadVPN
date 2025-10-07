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

// Per-network profile (no location): top (11) + knownGood (50)
class Profile {
  List<String> top; // display list (up to 11)
  List<String> kg;  // known-good pool (up to 50)
  DateTime? updated;

  Profile({List<String>? top, List<String>? kg, this.updated})
      : top = top ?? [],
        kg = kg ?? [];

  Map<String, dynamic> toJson() => {
        'top': top,
        'kg': kg,
        'updated': updated?.toIso8601String(),
      };

  static Profile fromJson(Map<String, dynamic> j) => Profile(
        top: (j['top'] as List?)?.map((e) => e.toString()).toList() ?? [],
        kg: (j['kg'] as List?)?.map((e) => e.toString()).toList() ?? [],
        updated: j['updated'] != null ? DateTime.tryParse(j['updated']) : null,
      );
}

class VPNService {
  static final V2ray v2ray = V2ray(onStatusChanged: _updateConnectionState);

  // Timeouts and concurrency knobs
  static const Duration userTestTimeout = Duration(seconds: 4); // user taps Connect
  static const Duration bgVerifyTimeout = Duration(seconds: 2); // verifying while app is foregrounded
  static const Duration tcpFastTimeout = Duration(milliseconds: 400); // TCP prefilter
  static const int tcpFastConcurrency = 120; // high concurrency for TCP prefilter

  // Cache external ASN for 10 minutes to avoid API rate limits
  static const Duration _asnCacheTtl = Duration(minutes: 10);
  static String? _cachedAsnFingerprint; // e.g., asn-13335|ippfx-93.184
  static DateTime? _asnCachedAt;

  static bool isConnected = false;
  static bool isSubscriptionValid = false;
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = []; // display list for current profile
  static bool isScanning = false;
  static String? currentConnectedConfig;
  static int? currentConnectedPing;
  static int scanProgress = 0;
  static int totalToScan = 0;

  // Caching for server stats
  static Map<String, ServerCache> serverCache = {};
  static String? lastGoodServer;

  // Persistent per-network profiles without location
  static Map<String, Profile> profiles = {}; // networkKey -> Profile
  static String? currentNetworkKey; // e.g., wifi|asn-13335|ippfx-93.184
  static List<String> knownGoodGlobal = []; // cross-profile seed pool (up to 100)

  static Set<String> scannedServers = {};

  // Stats
  static int sessionDownload = 0;
  static int sessionUpload = 0;
  static List<ConnectionStats> dailyStats = [];

  // Background scanning within app runtime
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

  // Public: called by main.dart (already used)
  static void resumeAutoScan() {
    // Safely resume profile fill while app is in foreground (no OS service).
    unawaited(refreshNetworkProfile());
    unawaited(_autoFillCurrentProfile(limitVerify: 4));
  }

  // Public: recompute current networkKey and swap profile + display
  static Future<void> refreshNetworkProfile() async {
    final key = await _deriveNetworkKey();
    if (key == null) {
      debugPrint('⚠️ Could not derive network key; keeping current profile');
      return;
    }
    if (key != currentNetworkKey) {
      debugPrint('🔁 Network changed: $currentNetworkKey → $key');
      currentNetworkKey = key;
      await _switchToProfile(key);
    } else {
      // Even if same, ensure display reflects persisted profile in case we resumed
      await _switchToProfile(key);
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
      await _loadPersistent();

      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      lastGoodServer = prefs.getString('last_good_server');
      _lastScannedIndex = prefs.getInt('last_scanned_index') ?? 0;

      // Compute and switch to current profile
      await refreshNetworkProfile();

      debugPrint('🔵 Init complete. Subscription link exists: ${currentSubscriptionLink != null}');

      _startHealthCheck();
    } catch (e, stack) {
      debugPrint('❌ Init error: $e\n$stack');
    }
  }

  // ========================= PROFILE SWITCH & FILL =========================
  static Future<void> _switchToProfile(String key) async {
    profiles.putIfAbsent(key, () => Profile(updated: DateTime.now()));
    // Update UI display from profile.top (fallback to global seeds if empty)
    final p = profiles[key]!;
    List<String> toShow = List.from(p.top);
    if (toShow.isEmpty) {
      // Seed from knownGoodGlobal without modifying donor profile
      final seed = knownGoodGlobal.where((c) => !toShow.contains(c)).take(11).toList();
      toShow = seed;
    }
    // Build fastestServers from cache for UI
    fastestServers = toShow.map((cfg) {
      final cached = serverCache[cfg];
      if (cached != null) {
        return ServerInfo(
          config: cfg,
          protocol: cached.protocol,
          ping: cached.lastPing,
          name: cached.name,
          successRate: cached.successRate,
          lastConnected: cached.lastConnected,
        );
      } else {
        return ServerInfo(
          config: cfg,
          protocol: _getProtocol(cfg),
          ping: 9999,
          name: 'Server',
          successRate: 0.0,
        );
      }
    }).toList();
    serversStreamController.add(List.from(fastestServers));

    // Persist topServers (for UI preload compatibility)
    await _saveTopServersForUi(p.top);

    // If still low, fill a few silently (no OS background)
    if ((p.top.length) < 11) {
      unawaited(_autoFillCurrentProfile(limitVerify: 4));
    }
  }

  // Fill current profile by verifying a few candidates (fast TCP prefilter + 2s verify)
  static Future<void> _autoFillCurrentProfile({int limitVerify = 4}) async {
    if (_isBackgroundScanning || isConnected) return;
    if (currentNetworkKey == null) return;

    _isBackgroundScanning = true;
    _cancelAutoScan = false;

    try {
      // Ensure subscription loaded
      if (configServers.isEmpty && (currentSubscriptionLink != null)) {
        final ok = await validateSubscription();
        if (!ok) return;
      }
      final p = profiles[currentNetworkKey] ?? Profile();

      // Candidates: from knownGoodGlobal first, then from configServers prioritized (newest + shuffle)
      final Set<String> have = p.top.toSet();
      final List<String> candidates = [];

      // prefer global seeds not in top
      for (final c in knownGoodGlobal) {
        if (have.length + candidates.length >= 11) break;
        if (!have.contains(c)) candidates.add(c);
      }
      // then new prioritized configs
      if (candidates.length < 11) {
        final pri = _prioritizeServers();
        for (final c in pri) {
          if (have.length + candidates.length >= 11) break;
          if (!have.contains(c) && !candidates.contains(c)) candidates.add(c);
        }
      }

      if (candidates.isEmpty) return;

      // Stage A: TCP prefilter for candidates
      final tcpOk = await _tcpPrefilterConfigs(
        candidates,
        timeout: tcpFastTimeout,
        concurrency: tcpFastConcurrency,
        stopOnCount: limitVerify * 3, // oversample a bit
      );

      // Stage B: verify a few
      int verified = 0;
      for (final c in tcpOk) {
        if (verified >= limitVerify || isConnected || _cancelAutoScan) break;
        final si = await _testServerWithPing(c, timeout: bgVerifyTimeout);
        if (si != null) {
          verified++;
          // Update profile: add to top (front), cap 11
          _commitSuccessToCurrentProfile(si.config);
          // Update UI display
          final cached = serverCache[si.config];
          final toAdd = ServerInfo(
            config: si.config,
            protocol: cached?.protocol ?? _getProtocol(si.config),
            ping: cached?.lastPing ?? si.ping,
            name: cached?.name ?? si.name,
            successRate: cached?.successRate ?? 0.0,
            lastConnected: cached?.lastConnected,
          );
          // Avoid duplicates in fastestServers
          fastestServers.removeWhere((s) => s.config == si.config);
          fastestServers.add(toAdd);
          fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
          serversStreamController.add(List.from(fastestServers));
        }
      }
      await _savePersistent(); // persist profiles + globals
    } catch (e) {
      debugPrint('❌ Auto-fill error: $e');
    } finally {
      _isBackgroundScanning = false;
      _cancelAutoScan = false;
    }
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
      final encoded =
          jsonEncode(serverCache.map((key, value) => MapEntry(key, value.toJson())));
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

  static Future<void> _saveScannedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('scanned_servers', scannedServers.toList());
    } catch (e) {
      debugPrint('❌ Scanned servers save error: $e');
    }
  }

  static Future<void> _loadPersistent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Profiles map
      final pjson = prefs.getString('profiles_json');
      if (pjson != null) {
        final decoded = jsonDecode(pjson) as Map<String, dynamic>;
        profiles = decoded.map((k, v) => MapEntry(k, Profile.fromJson(v)));
      }
      // Global known-good
      knownGoodGlobal = prefs.getStringList('known_good_global') ?? [];
      // For UI backward compatibility
      final uiTop = prefs.getStringList('top_servers') ?? [];
      if (uiTop.isNotEmpty) {
        // Will be overridden by current profile switch anyway
      }
      debugPrint(
          '✅ Loaded profiles: ${profiles.length}, global seeds: ${knownGoodGlobal.length}');
    } catch (e) {
      debugPrint('❌ Persistent load error: $e');
    }
  }

  static Future<void> _savePersistent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          jsonEncode(profiles.map((k, v) => MapEntry(k, v.toJson())));
      await prefs.setString('profiles_json', encoded);
      await prefs.setStringList('known_good_global', knownGoodGlobal);
      // Save current profile top list for UI preload compatibility
      await _saveTopServersForUi(profiles[currentNetworkKey]?.top ?? []);
    } catch (e) {
      debugPrint('❌ Persistent save error: $e');
    }
  }

  static Future<void> _saveTopServersForUi(List<String> top) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('top_servers', top.take(11).toList());
    } catch (e) {
      // ignore
    }
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
          await prefs.setInt('last_scanned_index', _lastScannedIndex);
          // Switch profile now that subscription reloaded
          await refreshNetworkProfile();
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
      debugPrint('🛑 Cancelling auto-fill (user clicked connect)');
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

    await refreshNetworkProfile(); // ensure profile is current

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
            // Update display and profile order
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

    // Step 0.5: Fallback to this profile's knownGood, else global seeds
    final fallbacks = _fallbackKnownForCurrent();
    if (!isConnected && fallbacks.isNotEmpty) {
      debugPrint('🔵 Fallback: testing profile/global known-good (${fallbacks.length})...');
      for (int i = 0; i < min(11, fallbacks.length) && !_cancelScan && !isConnected; i++) {
        final cfg = fallbacks[i];
        final result = await _testServerWithPing(cfg, timeout: userTestTimeout)
            .timeout(userTestTimeout, onTimeout: () => null);
        if (result != null) {
          isScanning = false;
          // Update UI + profile
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

  // Fallback order: current profile knownGood -> global seeds (dedup)
  static List<String> _fallbackKnownForCurrent() {
    final p = profiles[currentNetworkKey];
    final displayed = fastestServers.map((s) => s.config).toSet();
    final out = <String>[];
    if (p != null) {
      for (final c in p.kg) {
        if (!displayed.contains(c)) out.add(c);
      }
    }
    for (final c in knownGoodGlobal) {
      if (!displayed.contains(c) && !out.contains(c)) out.add(c);
    }
    return out;
  }

  // ========================= PRIORITY =========================
  // top servers first; then cached good; then newest (reversed) and shuffled
  static List<String> _prioritizeServers() {
    final Set<String> processed = {};
    final List<String> result = [];

    // 1) current profile's top servers (keep at front)
    final p = profiles[currentNetworkKey];
    if (p != null) {
      for (final config in p.top) {
        if (configServers.contains(config) && !processed.contains(config)) {
          result.add(config);
          processed.add(config);
        }
      }
    }

    // 2) cached good with high success rate
    final goodCached = serverCache.entries
        .where((e) =>
            e.value.successRate > 0.7 &&
            configServers.contains(e.key) &&
            (p == null || !p.top.contains(e.key)) &&
            !scannedServers.contains(e.key))
        .map((e) => e.key)
        .where((c) => !processed.contains(c))
        .toList();
    result.addAll(goodCached);
    processed.addAll(goodCached);

    // 3) rest of servers: newest first + shuffle
    final remaining = configServers
        .where((c) => !processed.contains(c) && (p == null || !p.top.contains(c)))
        .toList();
    final reversed = remaining.reversed.toList()..shuffle(Random());
    result.addAll(reversed);

    return result;
  }

  // ========================= TESTS & HELPERS =========================
  // Ensure DoH + IPv4 preference (helps on hostile ISPs)
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

  // TCP PREFILTER
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

      // After disconnect, switch/refresh current profile (if network changed)
      await refreshNetworkProfile();
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

  // ========================= NETWORK KEY (NO LOCATION) =========================
  // Build a privacy-friendly network key based on connectivity type + ASN/IP prefix
  static Future<String?> _deriveNetworkKey() async {
    try {
      final conn = await Connectivity().checkConnectivity();
      final type = (conn == ConnectivityResult.mobile)
          ? 'cell'
          : (conn == ConnectivityResult.wifi || conn == ConnectivityResult.ethernet)
              ? 'wifi'
              : 'other';

      // derive asn fingerprint: asn-XXXX|ippfx-A.B
      final asnFp = await _getAsnFingerprint();
      if (asnFp == null) return '$type|unknown';
      return '$type|$asnFp';
    } catch (e) {
      return 'other|unknown';
    }
  }

  // Get asn-<num>|ippfx-<A.B>, cached for TTL
  static Future<String?> _getAsnFingerprint() async {
    final now = DateTime.now();
    if (_cachedAsnFingerprint != null &&
        _asnCachedAt != null &&
        now.difference(_asnCachedAt!) < _asnCacheTtl) {
      return _cachedAsnFingerprint;
    }

    // Try ipapi.co then ipwho.is then ipinfo.io
    String? ip;
    String? asn;
    try {
      final r = await http.get(Uri.parse('https://ipapi.co/json/')).timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        ip = (j['ip'] ?? '').toString();
        final asnStr = (j['asn'] ?? '').toString(); // e.g., "AS13335"
        if (asnStr.startsWith('AS')) asn = asnStr.substring(2);
      }
    } catch (_) {}

    if ((ip == null || asn == null) || ip!.isEmpty || asn!.isEmpty) {
      try {
        final r = await http.get(Uri.parse('https://ipwho.is/')).timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          ip = (j['ip'] ?? '').toString();
          final cj = (j['connection'] ?? {}) as Map<String, dynamic>;
          asn = (cj['asn'] ?? '').toString(); // numeric string
        }
      } catch (_) {}
    }

    if ((ip == null || asn == null) || ip!.isEmpty || asn!.isEmpty) {
      try {
        final r = await http.get(Uri.parse('https://ipinfo.io/json')).timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          ip = (j['ip'] ?? '').toString();
          // org: "AS13335 Cloudflare"
          final org = (j['org'] ?? '').toString();
          if (org.startsWith('AS')) {
            final parts = org.split(' ');
            final first = parts.isNotEmpty ? parts[0] : '';
            if (first.startsWith('AS')) asn = first.substring(2);
          }
        }
      } catch (_) {}
    }

    if (ip == null || ip.isEmpty || asn == null || asn.isEmpty) return null;
    final ippfx = _ipPrefix(ip);
    final fp = 'asn-$asn|ippfx-$ippfx';
    _cachedAsnFingerprint = fp;
    _asnCachedAt = DateTime.now();
    return fp;
  }

  static String _ipPrefix(String ip) {
    // Return first 2 octets for IPv4; for IPv6 return first hextet
    if (ip.contains('.')) {
      final parts = ip.split('.');
      if (parts.length >= 2) {
        return '${parts[0]}.${parts[1]}';
      }
      return ip;
    } else if (ip.contains(':')) {
      final parts = ip.split(':');
      return parts.first;
    }
    return ip;
  }

  // ========================= PROFILE UPDATES =========================
  // Add success to current profile + global seeds; keep caps (top<=11, kg<=50, global<=100)
  static void _commitSuccessToCurrentProfile(String cfg) {
    if (currentNetworkKey == null) return;
    final p = profiles[currentNetworkKey] ?? Profile();
    // top: move to front, cap 11
    p.top.remove(cfg);
    p.top.insert(0, cfg);
    if (p.top.length > 11) p.top = p.top.take(11).toList();
    // kg: add to front, cap 50
    p.kg.remove(cfg);
    p.kg.insert(0, cfg);
    if (p.kg.length > 50) p.kg = p.kg.take(50).toList();
    p.updated = DateTime.now();
    profiles[currentNetworkKey!] = p;

    // global seeds
    knownGoodGlobal.remove(cfg);
    knownGoodGlobal.insert(0, cfg);
    if (knownGoodGlobal.length > 100) {
      knownGoodGlobal = knownGoodGlobal.take(100).toList();
    }

    // Persist
    unawaited(_savePersistent());
  }

  // ========================= HEALTH CHECK =========================
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

  // ========================= CONNECT / DISCONNECT (unchanged logic around stats) =========================
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

      await refreshNetworkProfile();
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
