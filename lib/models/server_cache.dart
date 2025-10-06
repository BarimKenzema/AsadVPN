import 'dart:convert';

class ServerCache {
  final String config;
  final String name;
  final String protocol;
  final int lastPing;
  final DateTime lastTested;
  final int successCount;
  final int failureCount;
  final DateTime? lastConnected;

  ServerCache({
    required this.config,
    required this.name,
    required this.protocol,
    required this.lastPing,
    required this.lastTested,
    this.successCount = 0,
    this.failureCount = 0,
    this.lastConnected,
  });

  double get successRate {
    final total = successCount + failureCount;
    if (total == 0) return 0.0;
    return successCount / total;
  }

  bool get isStale {
    return DateTime.now().difference(lastTested).inMinutes > 16;
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
      };

  factory ServerCache.fromJson(Map<String, dynamic> json) => ServerCache(
        config: json['config'],
        name: json['name'],
        protocol: json['protocol'],
        lastPing: json['lastPing'],
        lastTested: DateTime.parse(json['lastTested']),
        successCount: json['successCount'] ?? 0,
        failureCount: json['failureCount'] ?? 0,
        lastConnected: json['lastConnected'] != null
            ? DateTime.parse(json['lastConnected'])
            : null,
      );
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
        totalDownload: json['totalDownload'],
        totalUpload: json['totalUpload'],
        date: DateTime.parse(json['date']),
      );
}
