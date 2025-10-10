class NetworkProfile {
  final String networkId;
  final String networkName;
  final List<String> topServers;
  final List<String> knownGoodServers;
  final DateTime lastUsed;

  NetworkProfile({
    required this.networkId,
    required this.networkName,
    required this.topServers,
    required this.knownGoodServers,
    required this.lastUsed,
  });

  Map<String, dynamic> toJson() => {
        'networkId': networkId,
        'networkName': networkName,
        'topServers': topServers,
        'knownGoodServers': knownGoodServers,
        'lastUsed': lastUsed.toIso8601String(),
      };

  factory NetworkProfile.fromJson(Map<String, dynamic> json) => NetworkProfile(
        networkId: json['networkId'] ?? '',
        networkName: json['networkName'] ?? 'Unknown',
        topServers: List<String>.from(json['topServers'] ?? []),
        knownGoodServers: List<String>.from(json['knownGoodServers'] ?? []),
        lastUsed: json['lastUsed'] != null
            ? DateTime.parse(json['lastUsed'])
            : DateTime.now(),
      );
}
