import 'dart:convert';

class NetworkStats {
  final String networkId;
  final int successCount;
  final int failureCount;
  final int lastPing;
  final DateTime lastTested;

  NetworkStats({
    required this.networkId,
    required this.successCount,
    required this.failureCount,
    required this.lastPing,
    required this.lastTested,
  });

  double get successRate {
    final total = successCount + failureCount;
    if (total == 0) return 0.0;
    return successCount / total;
  }

  Map<String, dynamic> toJson() => {
        'networkId': networkId,
        'successCount': successCount,
        'failureCount': failureCount,
        'lastPing': lastPing,
        'lastTested': lastTested.toIso8601String(),
      };

  factory NetworkStats.fromJson(Map<String, dynamic> json) => NetworkStats(
        networkId: json['networkId'] ?? '',
        successCount: json['successCount'] ?? 0,
        failureCount: json['failureCount'] ?? 0,
        lastPing: json['lastPing'] ?? -1,
        lastTested: json['lastTested'] != null
            ? DateTime.parse(json['lastTested'])
            : DateTime.now(),
      );
}

class ServerCache {
  final String config;
  final String name;
  final String protocol;
  final int lastPing;
  final DateTime lastTested;
  final int successCount;
  final int failureCount;
  final DateTime? lastConnected;
  final Map<String, NetworkStats> networkStats; // NEW: per-network stats

  ServerCache({
    required this.config,
    required this.name,
    required this.protocol,
    required this.lastPing,
    required this.lastTested,
    this.successCount = 0,
    this.failureCount = 0,
    this.lastConnected,
    this.networkStats = const {},
  });

  double get successRate {
    final total = successCount + failureCount;
    if (total == 0) return 0.0;
    return successCount / total;
  }

  bool get isStale {
    return DateTime.now().difference(lastTested).inMinutes > 16;
  }

  // NEW: Get success rate for specific network
  double getNetworkSuccessRate(String networkId) {
    final stats = networkStats[networkId];
    if (stats == null) return 0.0;
    return stats.successRate;
  }

  // NEW: Get last ping for specific network
  int? getNetworkPing(String networkId) {
    return networkStats[networkId]?.lastPing;
  }

  // NEW: Get success count for specific network
  int getNetworkSuccess(String networkId) {
    return networkStats[networkId]?.successCount ?? 0;
  }

  // NEW: Get failure count for specific network
  int getNetworkFailures(String networkId) {
    return networkStats[networkId]?.failureCount ?? 0;
  }

  Map<String, dynamic> toJson() => {
        'config': config,
        'name': name,
        'protocol': protocol,
        'lastPing': lastPing,
        'lastTested': lastTested.toIso8601String(),
        'successCount': successCount,
        'failureCount': failureCount,
        'lastConnected': lastConnected?.toIso8601String(),
        'networkStats': networkStats.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

  factory ServerCache.fromJson(Map<String, dynamic> json) {
    Map<String, NetworkStats> loadedNetworkStats = {};
    
    if (json['networkStats'] != null) {
      final statsMap = json['networkStats'] as Map<String, dynamic>;
      loadedNetworkStats = statsMap.map(
        (key, value) => MapEntry(key, NetworkStats.fromJson(value)),
      );
    }

    return ServerCache(
      config: json['config'] ?? '',
      name: json['name'] ?? 'Unknown',
      protocol: json['protocol'] ?? 'UNKNOWN',
      lastPing: json['lastPing'] ?? -1,
      lastTested: json['lastTested'] != null
          ? DateTime.parse(json['lastTested'])
          : DateTime.now(),
      successCount: json['successCount'] ?? 0,
      failureCount: json['failureCount'] ?? 0,
      lastConnected: json['lastConnected'] != null
          ? DateTime.parse(json['lastConnected'])
          : null,
      networkStats: loadedNetworkStats,
    );
  }
}

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

  factory ConnectionStats.fromJson(Map<String, dynamic> json) =>
      ConnectionStats(
        totalDownload: json['totalDownload'] ?? 0,
        totalUpload: json['totalUpload'] ?? 0,
        date: json['date'] != null
            ? DateTime.parse(json['date'])
            : DateTime.now(),
      );
}
