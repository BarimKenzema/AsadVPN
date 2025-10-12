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
import '../services/network_detector.dart';
import '../models/network_profile.dart';

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
  static const Duration userTestTimeout = Duration(seconds: 3);
  static const Duration wifiConnectTimeout = Duration(seconds: 6);
  static const Duration bgVerifyTimeout = Duration(seconds: 2);
  static const Duration tcpFastTimeout = Duration(milliseconds: 600);
  static const int tcpFastConcurrency = 80;
  
  // SERVER LIMITS - ENFORCED!
  static const int MAX_DISPLAY_SERVERS = 11;  // Hard limit for display

  static bool isConnected = false;
  static bool isSubscriptionValid = false;
  static bool isSubscriptionExpired = false;
  static String? currentSubscriptionLink;
  static List<String> configServers = [];
  static List<ServerInfo> fastestServers = [];
  static bool isScanning = false;
  static String? currentConnectedConfig;
  static int? currentConnectedPing;
  static int scanProgress = 0;
  static int totalToScan = 0;

  // Network-specific storage
  static String? currentNetworkId;
  static String? currentNetworkName;
  static Map<String, NetworkProfile> networkProfiles = {};
  static StreamSubscription? _networkSubscription;

  // VPN state change tracking
  static bool _isVpnStateChanging = false;
  static Timer? _networkChangeDebounceTimer;

  // Testing flag to prevent false CONNECTED status during tests
  static bool _isTesting = false;

  // Caching (now network-aware)
  static Map<String, ServerCache> serverCache = {};
  static String? lastGoodServer;

  // Legacy persistent lists (kept for migration)
  static List<String> topServers = [];
  static List<String> knownGoodServers = [];

  static Set<String> scannedServers = {};

  // Priority tracking for newly-added servers
  static Set<String> _priorityNew = {};
  static Set<String> _previousConfigSet = {};

  // Stats
  static int sessionDownload = 0;
  static int sessionUpload = 0;
  static List<ConnectionStats> dailyStats = [];

  // Background scanning
  static Timer? _healthCheckTimer;
  static Timer? _subscriptionRefreshTimer;
  static DateTime? _lastSubscriptionRefresh;
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
  static final StreamController<String> subscriptionExpiredController =
      StreamController<String>.broadcast();
  static final StreamController<String> networkChangeController =
      StreamController<String>.broadcast();

  // ========================= HELPER: NETWORK TYPE DETECTION =========================
  static bool _isWiFiNetwork() {
    if (currentNetworkName == null) return false;
    final name = currentNetworkName!.toLowerCase();
    return name.contains('wifi') || name.contains('wi-fi');
  }

  // ========================= HELPER: GET UNIVERSAL SERVERS =========================
  static List<String> _getUniversalServers() {
    // Get servers that work on 3+ different networks
    final universal = serverCache.entries
        .where((e) {
          // Count networks where this server has success rate > 0.5
          final workingNetworks = e.value.networkStats.entries
              .where((net) => (net.value.successCount / max(1, net.value.successCount + net.value.failureCount)) > 0.5)
              .length;
          return workingNetworks >= 3;
        })
        .map((e) => e.key)
        .toList();
    
    if (universal.isNotEmpty) {
      debugPrint('🌍 Found ${universal.length} universal servers (work on 3+ networks)');
    }
    
    return universal;
  }

  // ========================= HELPER: ENFORCE SERVER LIMIT =========================
  static void _enforceServerLimit() {
    if (fastestServers.length > MAX_DISPLAY_SERVERS) {
      debugPrint('⚠️ Server limit exceeded: ${fastestServers.length} > $MAX_DISPLAY_SERVERS, trimming...');
      fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
      fastestServers = fastestServers.take(MAX_DISPLAY_SERVERS).toList();
      debugPrint('✅ Trimmed to $MAX_DISPLAY_SERVERS servers');
    }
  }

  // ========================= STATUS =========================
  static void _updateConnectionState(V2RayStatus status) {
    // IGNORE status updates during testing to prevent false positives
    if (_isTesting) {
      debugPrint('🔵 Ignoring status during test: ${status.state}');
      return;
    }

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

  // ========================= NETWORK DETECTION & SWITCHING =========================
  static Future<void> _initNetworkDetection() async {
    try {
      // Get initial network
      final networkInfo = await NetworkDetector.getCurrentNetwork();
      
      // Ignore "none" network type on init
      if (networkInfo.type == 'none') {
        debugPrint('⚠️ No network connection detected on init');
        currentNetworkId = 'none';
        currentNetworkName = 'No Connection';
        return;
      }
      
      currentNetworkId = networkInfo.id;
      currentNetworkName = networkInfo.displayName;
      debugPrint('🌐 Initial network: $currentNetworkName (ID: $currentNetworkId)');

      // Load profile for current network
      await _loadNetworkProfile(currentNetworkId!);

      // Listen for network changes with debouncing
      _networkSubscription = NetworkDetector.networkStream.listen((networkInfo) async {
        // IGNORE network changes during VPN state transitions
        if (_isVpnStateChanging) {
          debugPrint('🔵 Ignoring network change (VPN state changing)');
          return;
        }

        final newNetworkId = networkInfo.id;
        final newNetworkName = networkInfo.displayName;

        // IGNORE "none" network type (VPN disconnect can trigger this)
        if (networkInfo.type == 'none') {
          debugPrint('🔵 Ignoring "No Connection" network event');
          return;
        }

        // DEBOUNCE: Cancel previous timer and wait 2 seconds
        _networkChangeDebounceTimer?.cancel();
        _networkChangeDebounceTimer = Timer(const Duration(seconds: 2), () async {
          if (newNetworkId != currentNetworkId && newNetworkId != 'none') {
            await _handleNetworkChange(newNetworkId, newNetworkName);
          }
        });
      });
    } catch (e) {
      debugPrint('❌ Network detection init error: $e');
    }
  }

  static Future<void> _handleNetworkChange(String newNetworkId, String newNetworkName) async {
    debugPrint('🔄 Network changed: $currentNetworkName → $newNetworkName');
    
    // Save current network profile BEFORE switching
    if (currentNetworkId != null && currentNetworkId != 'none') {
      await _saveCurrentNetworkProfile();
    }

    // Switch to new network
    final previousNetworkId = currentNetworkId;
    currentNetworkId = newNetworkId;
    currentNetworkName = newNetworkName;
    
    // Notify UI
    networkChangeController.add(newNetworkName);

    // Load new network profile
    await _loadNetworkProfile(newNetworkId);

    // Auto-reconnect if was connected
    if (isConnected && currentConnectedConfig != null) {
      debugPrint('🔄 Auto-reconnecting on new network...');
      
      // Mark as VPN state changing to prevent network change events during reconnect
      _isVpnStateChanging = true;
      
      await disconnect();
      await Future.delayed(const Duration(milliseconds: 800));
      
      // Try to connect using new network's best server
      if (fastestServers.isNotEmpty) {
        await connect(
          vlessUri: fastestServers.first.config,
          ping: fastestServers.first.ping,
        );
      }
      
      _isVpnStateChanging = false;
    } else if (!isConnected && fastestServers.length < MAX_DISPLAY_SERVERS) {
      // Start auto-scan for new network
      debugPrint('🔍 Starting auto-scan for new network...');
      unawaited(_autoScanServers());
    }
  }

  static Future<void> _loadNetworkProfile(String networkId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final profilesJson = prefs.getString('network_profiles');
      
      if (profilesJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(profilesJson);
        networkProfiles = decoded.map(
          (key, value) => MapEntry(key, NetworkProfile.fromJson(value)),
        );
      }

      // Get profile for current network
      final profile = networkProfiles[networkId];
      
      if (profile != null) {
        debugPrint('✅ Loaded profile for $currentNetworkName: ${profile.topServers.length} servers');
        
        // Restore servers from profile - FIX: Don't lose servers!
        fastestServers = profile.topServers.map((config) {
          final cached = serverCache[config];
          if (cached != null) {
            return ServerInfo(
              config: config,
              protocol: cached.protocol,
              ping: cached.getNetworkPing(networkId) ?? cached.lastPing,
              name: cached.name,
              successRate: cached.getNetworkSuccessRate(networkId),
              lastConnected: cached.lastConnected,
            );
          } else {
            // No cache? Create placeholder (will be re-tested)
            return ServerInfo(
              config: config,
              protocol: _getProtocol(config),
              ping: 999,
              name: 'Server',
              successRate: 0,
            );
          }
        }).toList();
        
        // ENFORCE LIMIT after loading
        _enforceServerLimit();
        
        serversStreamController.add(List.from(fastestServers));
      } else {
        debugPrint('📝 New network detected: $currentNetworkName - creating profile...');
        networkProfiles[networkId] = NetworkProfile(
          networkId: networkId,
          networkName: currentNetworkName ?? 'Unknown',
          topServers: [],
          knownGoodServers: [],
          lastUsed: DateTime.now(),
        );
        
        // DON'T clear display if VPN is connected
        if (!isConnected) {
          fastestServers.clear();
          serversStreamController.add([]);
        } else {
          debugPrint('🔵 Keeping current servers (VPN connected)');
        }
      }
    } catch (e) {
      debugPrint('❌ Load network profile error: $e');
    }
  }

  static Future<void> _saveCurrentNetworkProfile() async {
    if (currentNetworkId == null || currentNetworkId == 'none') return;

    try {
      // ENFORCE LIMIT before saving
      _enforceServerLimit();
      
      // Update current profile
      final currentConfigs = fastestServers.map((s) => s.config).toList();
      
      networkProfiles[currentNetworkId!] = NetworkProfile(
        networkId: currentNetworkId!,
        networkName: currentNetworkName ?? 'Unknown',
        topServers: currentConfigs,
        knownGoodServers: _getKnownGoodForNetwork(currentNetworkId!),
        lastUsed: DateTime.now(),
      );

      // Save all profiles
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        networkProfiles.map((key, value) => MapEntry(key, value.toJson())),
      );
      await prefs.setString('network_profiles', encoded);
      
      debugPrint('💾 Saved profile for $currentNetworkName: ${currentConfigs.length} servers');
    } catch (e) {
      debugPrint('❌ Save network profile error: $e');
    }
  }

  static List<String> _getKnownGoodForNetwork(String networkId) {
    // Get servers that have good success rate on this network
    return serverCache.entries
        .where((e) => e.value.getNetworkSuccessRate(networkId) > 0.6)
        .map((e) => e.key)
        .take(30)
        .toList();
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

  static void resumeAutoScan() {
    // Check if we need to refresh subscription (> 1 hour since last refresh)
    if (_lastSubscriptionRefresh != null) {
      final elapsed = DateTime.now().difference(_lastSubscriptionRefresh!);
      if (elapsed.inMinutes >= 60 && currentSubscriptionLink != null) {
        debugPrint('🔵 App resumed, refreshing subscription (${elapsed.inMinutes} min since last refresh)...');
        unawaited(_refreshSubscription());
      }
    }

    if (!isConnected &&
        fastestServers.length < MAX_DISPLAY_SERVERS &&
        currentSubscriptionLink != null &&
        !_isBackgroundScanning &&
        !isSubscriptionExpired) {
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
      
      // Initialize network detection
      await _initNetworkDetection();

      final prefs = await SharedPreferences.getInstance();
      currentSubscriptionLink = prefs.getString('subscription_link');
      lastGoodServer = prefs.getString('last_good_server');
      _lastScannedIndex = prefs.getInt('last_scanned_index') ?? 0;

      debugPrint('🔵 Init complete. Network: $currentNetworkName');

      // Start hourly subscription refresh timer
      _startSubscriptionRefresh();

      // Auto discovery when not connected and fewer than MAX servers in display
      if (currentSubscriptionLink != null &&
          currentSubscriptionLink!.isNotEmpty &&
          !isConnected &&
          fastestServers.length < MAX_DISPLAY_SERVERS &&
          currentNetworkId != 'none') {
        debugPrint('🔵 Starting auto-scan for $MAX_DISPLAY_SERVERS servers (from index $_lastScannedIndex)...');
        unawaited(_autoScanServers(resumeFromIndex: _lastScannedIndex));
      }

      _startHealthCheck();
    } catch (e, stack) {
      debugPrint('❌ Init error: $e\n$stack');
    }
  }

  // ========================= SUBSCRIPTION REFRESH =========================
  static void _startSubscriptionRefresh() {
    _subscriptionRefreshTimer?.cancel();
    
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      debugPrint('🔵 No subscription link, skipping refresh timer');
      return;
    }

    debugPrint('🔵 Starting hourly subscription refresh timer');
    
    _subscriptionRefreshTimer = Timer.periodic(const Duration(hours: 1), (timer) async {
      if (currentSubscriptionLink != null && currentSubscriptionLink!.isNotEmpty) {
        debugPrint('⏰ Hourly subscription refresh triggered');
        await _refreshSubscription();
      }
    });
  }

  static Future<void> _refreshSubscription() async {
    if (currentSubscriptionLink == null || currentSubscriptionLink!.isEmpty) {
      debugPrint('⚠️ No subscription link to refresh');
      return;
    }

    try {
      debugPrint('🔵 Refreshing subscription...');
      
      // Store previous config set for diff
      _previousConfigSet = configServers.toSet();

      // Fetch new subscription
      final valid = await validateSubscription();
      
      if (!valid) {
        debugPrint('⚠️ Subscription refresh: validation failed');
        return;
      }

      // Check for subscription expiry (≤ 3 servers = expired)
      if (configServers.length <= 3) {
        debugPrint('🚨 SUBSCRIPTION EXPIRED! Only ${configServers.length} servers found');
        await _handleSubscriptionExpiry();
        return;
      }

      _lastSubscriptionRefresh = DateTime.now();
      debugPrint('✅ Subscription refreshed: ${configServers.length} servers');

      // Compute diff: newly added and removed
      final newConfigSet = configServers.toSet();
      final newlyAdded = newConfigSet.difference(_previousConfigSet);
      final removed = _previousConfigSet.difference(newConfigSet);

      if (newlyAdded.isNotEmpty) {
        debugPrint('🆕 Found ${newlyAdded.length} newly-added servers');
        _priorityNew.addAll(newlyAdded);

        // Quick verify pass for newly-added servers (if not connected and app active)
        if (!isConnected && !_isBackgroundScanning && fastestServers.length < MAX_DISPLAY_SERVERS) {
          debugPrint('🔍 Quick verify pass for ${newlyAdded.length} new servers...');
          unawaited(_verifyNewServers(newlyAdded.toList()));
        }
      }

      if (removed.isNotEmpty) {
        debugPrint('📤 ${removed.length} servers removed from subscription (keeping working ones)');
      }

      // Run pruning pass
      await _pruneStaleServers();

    } catch (e) {
      debugPrint('❌ Subscription refresh error: $e');
    }
  }

  static Future<void> _handleSubscriptionExpiry() async {
    isSubscriptionExpired = true;
    
    // Disconnect if connected
    if (isConnected) {
      debugPrint('🔌 Disconnecting due to subscription expiry...');
      _isVpnStateChanging = true;
      await disconnect();
      _isVpnStateChanging = false;
    }

    // Clear all server data
    configServers.clear();
    fastestServers.clear();
    serverCache.clear();
    scannedServers.clear();
    _priorityNew.clear();
    _previousConfigSet.clear();
    
    // Clear ALL network profiles
    networkProfiles.clear();

    // Save cleared state
    await _saveCache();
    await _saveCurrentNetworkProfile();
    
    // Update UI
    serversStreamController.add([]);
    
    // Notify UI to show message
    subscriptionExpiredController.add('Your subscription has expired. Please purchase a new subscription.');
    
    debugPrint('🚨 All server data cleared due to subscription expiry');
  }

  static Future<void> _verifyNewServers(List<String> newServers) async {
    if (newServers.isEmpty || currentNetworkId == null || currentNetworkId == 'none') return;

    try {
      // TCP prefilter for both WiFi and Mobile (same treatment)
      final tcpOk = await _tcpPrefilterConfigs(
        newServers,
        timeout: tcpFastTimeout,
        concurrency: tcpFastConcurrency,
        stopOnCount: 0,
      );
      debugPrint('✅ New servers TCP prefilter: ${tcpOk.length}/${newServers.length} passed');
      final toVerify = tcpOk.take(5).toList();

      // Verify survivors (limit to 5 to avoid blocking too long)
      for (final config in toVerify) {
        if (isConnected || fastestServers.length >= MAX_DISPLAY_SERVERS) break;

        final result = await _testServerWithPing(config, timeout: bgVerifyTimeout);
        if (result != null && !isConnected && fastestServers.length < MAX_DISPLAY_SERVERS) {
          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            _enforceServerLimit();
            await _saveCurrentNetworkProfile();
            serversStreamController.add(List.from(fastestServers));
            debugPrint('✅ New server verified and added: ${result.name}');
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Verify new servers error: $e');
    }
  }

  static Future<void> _pruneStaleServers() async {
    if (currentNetworkId == null || currentNetworkId == 'none') return;

    try {
      debugPrint('🧹 Running stale server pruning for network $currentNetworkName...');

      final now = DateTime.now();
      final staleThreshold = now.subtract(const Duration(hours: 48));
      final failureThreshold = 5;

      int prunedCount = 0;

      final toPrune = <String>[];

      for (final entry in serverCache.entries) {
        final config = entry.key;
        final cache = entry.value;

        // Never prune currently connected server
        if (config == currentConnectedConfig) continue;

        // Network-specific pruning
        final networkFailures = cache.getNetworkFailures(currentNetworkId!);
        final networkSuccessRate = cache.getNetworkSuccessRate(currentNetworkId!);
        
        // Prune if: high failures on THIS network AND never connected AND not tested recently
        if (networkFailures >= failureThreshold &&
            networkSuccessRate < 0.2 &&
            cache.lastTested.isBefore(staleThreshold)) {
          toPrune.add(config);
        }
      }

      for (final config in toPrune) {
        // Remove from current network's display
        fastestServers.removeWhere((s) => s.config == config);
        prunedCount++;
      }

      if (prunedCount > 0) {
        debugPrint('🧹 Pruned $prunedCount stale servers from $currentNetworkName');
        await _saveCache();
        await _saveCurrentNetworkProfile();
        serversStreamController.add(List.from(fastestServers));
      } else {
        debugPrint('✅ No stale servers to prune');
      }
    } catch (e) {
      debugPrint('❌ Prune error: $e');
    }
  }  // ========================= AUTO-SCAN =========================
  static Future<void> _autoScanServers({int resumeFromIndex = 0}) async {
    if (_isBackgroundScanning) {
      debugPrint('⚠️ Auto-scan already running, skipping');
      return;
    }

    if (currentNetworkId == null || currentNetworkId == 'none') {
      debugPrint('⚠️ No network detected, skipping auto-scan');
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
      debugPrint('🔵 Auto-scan on $currentNetworkName: Finding servers ($startMsg)...');

      final prioritized = _prioritizeServers();

      // UNIFIED APPROACH: Use TCP prefilter + getServerDelay for BOTH WiFi and Mobile
      debugPrint('⚡ TCP prefiltering ${prioritized.length - resumeFromIndex} servers with concurrency $tcpFastConcurrency...');
      
      final remaining = prioritized.sublist(resumeFromIndex);
      final toTest = await _tcpPrefilterConfigs(
        remaining,
        timeout: tcpFastTimeout,
        concurrency: tcpFastConcurrency,
        stopOnCount: 0,
      );
      debugPrint('✅ TCP prefilter survivors: ${toTest.length}');

      // Stage B: Verify survivors sequentially, continue even after MAX_DISPLAY_SERVERS
      for (int i = 0; i < toTest.length; i++) {
        if ((resumeFromIndex + i) % 5 == 0) {
          _lastScannedIndex = resumeFromIndex + i;
          await _saveProgress();
        }

        // ONLY stop if user connects or cancels (NOT when reaching MAX_DISPLAY_SERVERS)
        if (isConnected || _cancelAutoScan) {
          if (isConnected) debugPrint('🛑 Auto-scan stopped: User connected');
          if (_cancelAutoScan) debugPrint('🛑 Auto-scan cancelled');
          break;
        }

        final config = toTest[i];
        final result = await _testServerWithPing(config, timeout: bgVerifyTimeout);
        
        if (result != null && !isConnected) {
          // Always update cache (learning phase)
          
          // Only add to display if < MAX_DISPLAY_SERVERS
          if (fastestServers.length < MAX_DISPLAY_SERVERS) {
            if (!fastestServers.any((s) => s.config == result.config)) {
              fastestServers.add(result);
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              _enforceServerLimit();
              await _saveCurrentNetworkProfile();
              serversStreamController.add(List.from(fastestServers));
              debugPrint('✅ Added to display (${fastestServers.length}/$MAX_DISPLAY_SERVERS): ${result.name}');
            }
          } else {
            // Try to replace slower server if this one is faster
            if (result.ping < fastestServers.last.ping) {
              fastestServers.removeLast();
              fastestServers.add(result);
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              await _saveCurrentNetworkProfile();
              serversStreamController.add(List.from(fastestServers));
              debugPrint('✅ Replaced slower server with ${result.name} (${result.ping}ms < ${fastestServers.last.ping}ms)');
            } else {
              debugPrint('📊 Server tested but not added (slower): ${result.name} (${result.ping}ms)');
            }
          }
        }
      }

      if (!isConnected) {
        await _saveCurrentNetworkProfile();
        debugPrint('✅ Auto-scan completed for $currentNetworkName');
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

      // Reset expiry flag on new subscription
      isSubscriptionExpired = false;

      try {
        final valid = await validateSubscription();
        if (!valid) {
          await prefs.remove('subscription_link');
          currentSubscriptionLink = null;
        } else {
          // Check if subscription is expired (≤ 3 servers)
          if (configServers.length <= 3) {
            debugPrint('🚨 New subscription is expired (${configServers.length} servers)');
            await _handleSubscriptionExpiry();
            return false;
          }

          _lastScannedIndex = 0;
          await _saveProgress();
          
          // Initialize previous config set
          _previousConfigSet = configServers.toSet();
          _lastSubscriptionRefresh = DateTime.now();
          
          // Start refresh timer
          _startSubscriptionRefresh();
          
          if (!isConnected && currentNetworkId != 'none') {
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
    if (isSubscriptionExpired) {
      return {'success': false, 'error': 'Subscription expired. Please purchase a new subscription.'};
    }

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
      
      // Check for expiry after validation
      if (configServers.length <= 3) {
        await _handleSubscriptionExpiry();
        return {'success': false, 'error': 'Subscription expired. Please purchase a new subscription.'};
      }
    }

    isScanning = true;
    _cancelScan = false;
    scanProgress = 0;
    _lastConnectionTime = null;
    totalToScan = 0;
    scanProgressController.add(0);

    // UNIFIED FLOW: Same for both WiFi and Mobile
    return await _unifiedConnectFlow(connectImmediately);
  }

  // ========================= UNIFIED CONNECT FLOW =========================
  static Future<Map<String, dynamic>> _unifiedConnectFlow(bool connectImmediately) async {
    debugPrint('🔵 Using unified connect flow for $currentNetworkName');

    // Step 0: Try displayed servers first
    if (fastestServers.isNotEmpty) {
      debugPrint('🔵 Trying ${fastestServers.length} displayed servers...');
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
              _enforceServerLimit();
              serversStreamController.add(List.from(fastestServers));
            }
            await _saveCurrentNetworkProfile();
            await connect(vlessUri: result.config, ping: result.ping);
            debugPrint('🔵 Connected to displayed server');
            return {'success': true, 'server': result.config, 'ping': result.ping};
          }
        } else {
          debugPrint('⚠️ Server failed: ${sortedDisplayed[i].name}');
          _recordFailure(sortedDisplayed[i].config);
        }
      }
      if (_cancelScan) {
        isScanning = false;
        _cancelScan = false;
        return {'success': false, 'error': 'Scan cancelled'};
      }
    }

    // Step 1: Try universal servers (work on 3+ networks)
    final universal = _getUniversalServers();
    if (universal.isNotEmpty) {
      debugPrint('🌍 Trying ${universal.length} universal servers...');
      for (int i = 0; i < universal.length && !_cancelScan; i++) {
        debugPrint('🔵 Testing universal server ${i + 1}/${universal.length}...');
        
        final result = await _testServerWithPing(universal[i], timeout: userTestTimeout)
            .timeout(userTestTimeout, onTimeout: () => null);

        if (result != null) {
          isScanning = false;
          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            _enforceServerLimit();
            serversStreamController.add(List.from(fastestServers));
          }
          await _saveCurrentNetworkProfile();
          if (connectImmediately) {
            await connect(vlessUri: result.config, ping: result.ping);
          }
          debugPrint('✅ Connected to universal server');
          return {'success': true, 'server': result.config, 'ping': result.ping};
        }
      }
    }

    // Step 2: Fallback to network's known-good servers
    if (!isConnected && fastestServers.isEmpty && currentNetworkId != null && currentNetworkId != 'none') {
      final fallback = _getKnownGoodForNetwork(currentNetworkId!);
      if (fallback.isNotEmpty) {
        debugPrint('🔵 Fallback: testing known-good pool (${fallback.length})...');
        for (int i = 0; i < min(MAX_DISPLAY_SERVERS, fallback.length) && !_cancelScan && !isConnected; i++) {
          final cfg = fallback[i];
          final result =
              await _testServerWithPing(cfg, timeout: userTestTimeout).timeout(userTestTimeout, onTimeout: () => null);
          if (result != null) {
            isScanning = false;
            if (!fastestServers.any((s) => s.config == result.config)) {
              fastestServers.add(result);
              fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
              _enforceServerLimit();
              serversStreamController.add(List.from(fastestServers));
            }
            await _saveCurrentNetworkProfile();
            if (connectImmediately) {
              await connect(vlessUri: result.config, ping: result.ping);
            }
            debugPrint('🔵 Connected from known-good pool');
            return {'success': true, 'server': result.config, 'ping': result.ping};
          }
        }
      }
    }

    // Step 3: Scan new servers
    debugPrint('🔵 Scanning for new servers...');
    final prioritized = _prioritizeServers();
    
    for (var config in prioritized) {
      if (_cancelScan || isConnected) break;
      
      debugPrint('🔵 Testing server...');
      final result = await _testServerWithPing(config, timeout: userTestTimeout)
          .timeout(userTestTimeout, onTimeout: () => null);
      if (result != null) {
        debugPrint('✅ Found working server: ${result.name} (${result.ping}ms)');
        if (connectImmediately) {
          isScanning = false;
          if (!fastestServers.any((s) => s.config == result.config)) {
            fastestServers.add(result);
            fastestServers.sort((a, b) => a.ping.compareTo(b.ping));
            _enforceServerLimit();
            serversStreamController.add(List.from(fastestServers));
          }
          await _saveCurrentNetworkProfile();
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
    
    // Trigger background scan
    debugPrint('⚠️ No servers found, starting background scan...');
    unawaited(_autoScanServers());
    
    return {'success': false, 'error': 'No working servers found'};
  }

  // ========================= PRIORITY =========================
  static List<String> _prioritizeServers() {
    final Set<String> processed = {};
    final List<String> result = [];

    // Priority 1: Universal servers (work on 3+ networks)
    final universal = _getUniversalServers();
    for (var config in universal) {
      if (configServers.contains(config) && !processed.contains(config)) {
        result.add(config);
        processed.add(config);
      }
    }

    // Priority 2: Newly-added servers from subscription refresh
    for (var config in _priorityNew) {
      if (configServers.contains(config) && !processed.contains(config)) {
        result.add(config);
        processed.add(config);
      }
    }

    // Priority 3: Network-specific top servers
    if (currentNetworkId != null && currentNetworkId != 'none') {
      final profile = networkProfiles[currentNetworkId!];
      if (profile != null && profile.topServers.isNotEmpty) {
        for (var config in profile.topServers) {
          if (configServers.contains(config) && !processed.contains(config)) {
            result.add(config);
            processed.add(config);
          }
        }
      }
    }

    // Priority 4: Network-specific cached good servers
    if (currentNetworkId != null && currentNetworkId != 'none') {
      final goodCached = serverCache.entries
          .where((e) =>
              e.value.getNetworkSuccessRate(currentNetworkId!) > 0.7 &&
              configServers.contains(e.key) &&
              !scannedServers.contains(e.key))
          .map((e) => e.key)
          .where((c) => !processed.contains(c))
          .toList();
      result.addAll(goodCached);
      processed.addAll(goodCached);
    }

    // Priority 5: FALLBACK - If network-specific is empty, use global cache
    if (currentNetworkId != null && currentNetworkId != 'none') {
      final profile = networkProfiles[currentNetworkId!];
      
      if (profile == null || profile.topServers.isEmpty) {
        debugPrint('📦 Network cache empty, using global fallback');
        
        // Add servers sorted by global success rate
        final globalBest = serverCache.entries
            .where((e) => 
                e.value.successCount > 0 && 
                configServers.contains(e.key) &&
                !processed.contains(e.key))
            .map((e) => MapEntry(e.key, e.value.successRate))
            .toList();
        
        // Sort by global success rate
        globalBest.sort((a, b) => b.value.compareTo(a.value));
        
        final globalConfigs = globalBest.map((e) => e.key).toList();
        result.addAll(globalConfigs);
        processed.addAll(globalConfigs);
        
        debugPrint('📦 Added ${globalConfigs.length} servers from global cache');
      }
    }

    // Priority 6: Remaining (newest first, then shuffled)
    final remaining = configServers
        .where((c) => !processed.contains(c) && !scannedServers.contains(c))
        .toList();

    final reversed = remaining.reversed.toList()..shuffle(Random());
    result.addAll(reversed);

    return result;
  }

  // ========================= DNS & CONFIG (MINIMAL MODIFICATION) =========================
  static String _ensureDnsAndIPv4(String config, {bool useDoH = false}) {
    try {
      final Map<String, dynamic> json = jsonDecode(config);
      
      // Only modify DNS if not already set - preserve original config as much as possible
      if (json['dns'] == null) {
        json['dns'] = {};
        
        if (useDoH) {
          json['dns']['servers'] = [
            'https://1.1.1.1/dns-query',
            'https://dns.google/dns-query',
            '1.1.1.1',
            '8.8.8.8',
          ];
        } else {
          json['dns']['servers'] = [
            '1.1.1.1',
            '8.8.8.8',
            '8.8.4.4',
          ];
        }
      }
      
      if (json['routing'] == null) {
        json['routing'] = {};
        json['routing']['domainStrategy'] = 'IPIfNonMatch';
      }
      
      return jsonEncode(json);
    } catch (_) {
      // If parsing fails, return original config unchanged
      return config;
    }
  }

  // ========================= TESTS =========================
  static Future<ServerInfo?> _testServerWithPing(String uri, {Duration? timeout}) async {
    if (currentNetworkId == null || currentNetworkId == 'none') return null;

    try {
      final parser = V2ray.parseFromURL(uri);
      var config = parser.getFullConfiguration();

      config = _ensureDnsAndIPv4(config, useDoH: false);

      final effectiveTimeout = timeout ?? userTestTimeout;
      final delay = await v2ray.getServerDelay(config: config).timeout(
        effectiveTimeout,
        onTimeout: () => -1,
      );

      if (delay != -1 && delay < 8000) {
        debugPrint('✅ ${parser.remark}: ${delay}ms on $currentNetworkName');

        final existing = serverCache[uri];
        final currentSuccess = existing?.getNetworkSuccess(currentNetworkId!) ?? 0;
        final currentFailures = existing?.getNetworkFailures(currentNetworkId!) ?? 0;

        serverCache[uri] = ServerCache(
          config: uri,
          name: parser.remark,
          protocol: _getProtocol(uri),
          lastPing: delay,
          lastTested: DateTime.now(),
          successCount: (existing?.successCount ?? 0) + 1,
          failureCount: existing?.failureCount ?? 0,
          lastConnected: existing?.lastConnected,
          networkStats: {
            ...?existing?.networkStats,
            currentNetworkId!: NetworkStats(
              networkId: currentNetworkId!,
              successCount: currentSuccess + 1,
              failureCount: currentFailures,
              lastPing: delay,
              lastTested: DateTime.now(),
            ),
          },
        );
        unawaited(_saveCache());

        return ServerInfo(
          config: uri,
          protocol: _getProtocol(uri),
          ping: delay,
          name: parser.remark,
          successRate: serverCache[uri]!.getNetworkSuccessRate(currentNetworkId!),
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
    if (currentNetworkId == null || currentNetworkId == 'none') return;

    final existing = serverCache[uri];
    if (existing != null) {
      final currentSuccess = existing.getNetworkSuccess(currentNetworkId!);
      final currentFailures = existing.getNetworkFailures(currentNetworkId!);

      serverCache[uri] = ServerCache(
        config: uri,
        name: existing.name,
        protocol: existing.protocol,
        lastPing: existing.lastPing,
        lastTested: DateTime.now(),
        successCount: existing.successCount,
        failureCount: existing.failureCount + 1,
        lastConnected: existing.lastConnected,
        networkStats: {
          ...existing.networkStats,
          currentNetworkId!: NetworkStats(
            networkId: currentNetworkId!,
            successCount: currentSuccess,
            failureCount: currentFailures + 1,
            lastPing: existing.networkStats[currentNetworkId]?.lastPing ?? existing.lastPing,
            lastTested: DateTime.now(),
          ),
        },
      );
      unawaited(_saveCache());
    }
  }

  static Future<List<String>> _tcpPrefilterConfigs(
    List<String> configs, {
    required Duration timeout,
    required int concurrency,
    int stopOnCount = 0,
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
  static Future<bool> connect({
    required String vlessUri, 
    int? ping, 
    bool retryWithoutDoH = true,
    bool testOnly = false,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return false;

    if (isSubscriptionExpired) {
      debugPrint('❌ Cannot connect: Subscription expired');
      return false;
    }

    try {
      if (isConnected && !testOnly) {
        _isManualDisconnect = true;
        _isVpnStateChanging = true;
        await disconnect();
        _isVpnStateChanging = false;
        await Future.delayed(const Duration(milliseconds: 500));
      }

      _isManualDisconnect = false;
      _isVpnStateChanging = true;

      // Set testing flag if testOnly to prevent false CONNECTED status
      if (testOnly) {
        _isTesting = true;
      }

      final parser = V2ray.parseFromURL(vlessUri);
      var config = parser.getFullConfiguration();
      
      config = _ensureDnsAndIPv4(config, useDoH: false);

      if (await v2ray.requestPermission()) {
        try {
          await v2ray.startV2Ray(
            remark: parser.remark,
            config: config,
            proxyOnly: false,
            bypassSubnets: [],
          );

          await Future.delayed(const Duration(seconds: 2));
          
          final delay = await v2ray.getConnectedServerDelay()
              .timeout(const Duration(seconds: 5));
          
          if (delay == -1 || delay > 8000) {
            throw Exception('Connection timeout or unhealthy');
          }

          if (testOnly) {
            await v2ray.stopV2Ray();
            _isTesting = false;
            _isVpnStateChanging = false;
            debugPrint('✅ Test connection successful (Direct DNS)');
            return true;
          }

          currentConnectedConfig = vlessUri;
          currentConnectedPing = ping;

          final existing = serverCache[vlessUri];
          if (existing != null && currentNetworkId != null && currentNetworkId != 'none') {
            final currentSuccess = existing.getNetworkSuccess(currentNetworkId!);
            final currentFailures = existing.getNetworkFailures(currentNetworkId!);

            serverCache[vlessUri] = ServerCache(
              config: vlessUri,
              name: existing.name,
              protocol: existing.protocol,
              lastPing: existing.lastPing,
              lastTested: existing.lastTested,
              successCount: existing.successCount + 1,
              failureCount: existing.failureCount,
              lastConnected: DateTime.now(),
              networkStats: {
                ...existing.networkStats,
                currentNetworkId!: NetworkStats(
                  networkId: currentNetworkId!,
                  successCount: currentSuccess + 1,
                  failureCount: currentFailures,
                  lastPing: ping ?? existing.lastPing,
                  lastTested: DateTime.now(),
                ),
              },
            );
          } else if (currentNetworkId != null && currentNetworkId != 'none') {
            serverCache[vlessUri] = ServerCache(
              config: vlessUri,
              name: parser.remark,
              protocol: _getProtocol(vlessUri),
              lastPing: ping ?? -1,
              lastTested: DateTime.now(),
              successCount: 1,
              lastConnected: DateTime.now(),
              networkStats: {
                currentNetworkId!: NetworkStats(
                  networkId: currentNetworkId!,
                  successCount: 1,
                  failureCount: 0,
                  lastPing: ping ?? -1,
                  lastTested: DateTime.now(),
                ),
              },
            );
          }

          lastGoodServer = vlessUri;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_good_server', vlessUri);
          unawaited(_saveCache());

          _isTesting = false;
          _isVpnStateChanging = false;
          debugPrint('✅ Connected successfully (Direct DNS) on $currentNetworkName');
          return true;
          
        } catch (e) {
          debugPrint('⚠️ Direct DNS connection failed: $e');
          
          if (retryWithoutDoH && !testOnly) {
            debugPrint('🔄 Retrying with DoH...');
            await v2ray.stopV2Ray();
            await Future.delayed(const Duration(milliseconds: 500));
            
            config = parser.getFullConfiguration();
            config = _ensureDnsAndIPv4(config, useDoH: true);
            
            await v2ray.startV2Ray(
              remark: parser.remark,
              config: config,
              proxyOnly: false,
              bypassSubnets: [],
            );

            await Future.delayed(const Duration(seconds: 2));
            final delay = await v2ray.getConnectedServerDelay()
                .timeout(const Duration(seconds: 5));
            
            if (delay != -1 && delay < 8000) {
              if (testOnly) {
                await v2ray.stopV2Ray();
                _isTesting = false;
                _isVpnStateChanging = false;
                debugPrint('✅ Test connection successful (DoH)');
                return true;
              }

              currentConnectedConfig = vlessUri;
              currentConnectedPing = ping;
              
              lastGoodServer = vlessUri;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('last_good_server', vlessUri);
              
              _isTesting = false;
              _isVpnStateChanging = false;
              debugPrint('✅ Connected successfully (DoH fallback) on $currentNetworkName');
              return true;
            }
          }
          
          throw e;
        }
      }
      _isTesting = false;
      _isVpnStateChanging = false;
      return false;
    } catch (e) {
      _isTesting = false;
      _isVpnStateChanging = false;
      
      final existing = serverCache[vlessUri];
      if (existing != null && currentNetworkId != null && currentNetworkId != 'none') {
        final currentSuccess = existing.getNetworkSuccess(currentNetworkId!);
        final currentFailures = existing.getNetworkFailures(currentNetworkId!);

        serverCache[vlessUri] = ServerCache(
          config: vlessUri,
          name: existing.name,
          protocol: existing.protocol,
          lastPing: existing.lastPing,
          lastTested: existing.lastTested,
          successCount: existing.successCount,
          failureCount: existing.failureCount + 1,
          networkStats: {
            ...existing.networkStats,
            currentNetworkId!: NetworkStats(
              networkId: currentNetworkId!,
              successCount: currentSuccess,
              failureCount: currentFailures + 1,
              lastPing: existing.networkStats[currentNetworkId]?.lastPing ?? existing.lastPing,
              lastTested: DateTime.now(),
            ),
          },
        );
        unawaited(_saveCache());
      }
      debugPrint('❌ Connection error: $e');
      return false;
    }
  }

  static Future<bool> connectToLastGoodServer() async {
    if (isSubscriptionExpired) {
      debugPrint('❌ Cannot connect: Subscription expired');
      return false;
    }

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

      // Save current network profile before potential auto-scan
      await _saveCurrentNetworkProfile();

      if (fastestServers.length < MAX_DISPLAY_SERVERS && 
          currentSubscriptionLink != null && 
          !isSubscriptionExpired &&
          currentNetworkId != 'none') {
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
    _subscriptionRefreshTimer?.cancel();
    _networkSubscription?.cancel();
    _networkChangeDebounceTimer?.cancel();
    serversStreamController.close();
    connectionStateController.close();
    statusStreamController.close();
    scanProgressController.close();
    subscriptionExpiredController.close();
    networkChangeController.close();
  }
}

// Helper to ignore unawaited futures
void unawaited(Future<void> future) {}

class ConnectionStats {
  final int totalDownload;
  final int totalUpload;
  final DateTime date;

  ConnectionStats({
    required this.totalDownload,
    required this.totalUpload,
    required this.date,
  });

  Map<String, dynamic> toJson() => {
    'totalDownload': totalDownload,
    'totalUpload': totalUpload,
    'date': date.toIso8601String(),
  };

  factory ConnectionStats.fromJson(Map<String, dynamic> json) => ConnectionStats(
    totalDownload: json['totalDownload'] ?? 0,
    totalUpload: json['totalUpload'] ?? 0,
    date: DateTime.parse(json['date']),
  );
}
