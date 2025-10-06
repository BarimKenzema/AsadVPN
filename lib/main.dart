import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/vpn_service.dart';
import 'qr_scanner_page.dart';
import 'screens/settings_page.dart';
import 'dart:async';

void main() => runApp(AsadVPNApp());

class AsadVPNApp extends StatefulWidget {
  @override
  _AsadVPNAppState createState() => _AsadVPNAppState();
}

class _AsadVPNAppState extends State<AsadVPNApp> {
  Locale _locale = const Locale('en');
  ThemeMode _themeMode = ThemeMode.dark;

  void _changeLanguage(Locale locale) => setState(() => _locale = locale);
  void _changeTheme(ThemeMode mode) => setState(() => _themeMode = mode);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AsadVPN',
      locale: _locale,
      themeMode: _themeMode,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('fa')],
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
      ),
      home: VPNHomePage(
        onLanguageChanged: _changeLanguage,
        onThemeChanged: _changeTheme,
      ),
    );
  }
}

class VPNHomePage extends StatefulWidget {
  final void Function(Locale) onLanguageChanged;
  final void Function(ThemeMode) onThemeChanged;
  
  const VPNHomePage({
    required this.onLanguageChanged,
    required this.onThemeChanged,
    Key? key,
  }) : super(key: key);

  @override
  _VPNHomePageState createState() => _VPNHomePageState();
}

class _VPNHomePageState extends State<VPNHomePage> with WidgetsBindingObserver {
  String status = 'Disconnected';
  bool isConnecting = false;
  List<ServerInfo> displayServers = [];
  StreamSubscription? serversSub;
  StreamSubscription? connectionSub;
  StreamSubscription? statusSub;
  StreamSubscription? progressSub;
  
  int downloadSpeed = 0;
  int uploadSpeed = 0;
  int totalDownload = 0;
  int totalUpload = 0;
  String scanStatus = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();

    serversSub = VPNService.serversStreamController.stream.listen((servers) {
      if (mounted) setState(() => displayServers = servers);
    });

    connectionSub = VPNService.connectionStateController.stream.listen((connected) {
      if (mounted) _updateConnectionStatus();
    });

    statusSub = VPNService.statusStreamController.stream.listen((status) {
      if (mounted) {
        setState(() {
          downloadSpeed = status.downloadSpeed;
          uploadSpeed = status.uploadSpeed;
          totalDownload = status.download;
          totalUpload = status.upload;
        });
      }
    });

    progressSub = VPNService.scanProgressController.stream.listen((progress) {
      if (mounted) {
        setState(() {
          scanStatus = 'Testing servers... $progress/${VPNService.totalToScan}';
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    serversSub?.cancel();
    connectionSub?.cancel();
    statusSub?.cancel();
    progressSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateConnectionStatus();
    }
  }

  void _updateConnectionStatus() {
    final l10n = AppLocalizations.of(context);
    setState(() {
      if (VPNService.isConnected) {
        status = l10n?.connected ?? 'Connected';
        if (VPNService.currentConnectedPing != null) {
          status += ' (${VPNService.currentConnectedPing}ms)';
        }
      } else {
        status = l10n?.disconnected ?? 'Disconnected';
      }
    });
  }

  Future<void> _initialize() async {
    await VPNService.init();
    if (!mounted) return;
    
    // Don't check subscription validity here
    // Only show dialog if there's NO subscription link at all
    if (VPNService.currentSubscriptionLink == null || VPNService.currentSubscriptionLink!.isEmpty) {
      _showSubscriptionDialog();
    } else {
      _updateConnectionStatus();
    }
  }

  Future<void> _toggleConnection() async {
    final l10n = AppLocalizations.of(context);
    
    if (VPNService.isConnected) {
      await VPNService.disconnect();
      return;
    }
    
    // Check if subscription link exists before attempting connection
    if (VPNService.currentSubscriptionLink == null || VPNService.currentSubscriptionLink!.isEmpty) {
      _showSubscriptionDialog();
      return;
    }

    setState(() {
      isConnecting = true;
      status = l10n?.connecting ?? 'A Moment Please...';
      scanStatus = 'Checking connection...';
    });

    final result = await VPNService.scanAndSelectBestServer();
    if (!mounted) return;

    if (result['success'] != true) {
      final error = result['error'] ?? 'Unknown error';
      
      // Handle different error types
      if (error.contains('No internet connection')) {
        setState(() {
          status = 'No internet connection';
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: const [
                Icon(Icons.wifi_off, color: Colors.white),
                SizedBox(width: 8),
                Expanded(child: Text('Please check your internet connection')),
              ],
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 3),
          ),
        );
      } else if (error.contains('subscription') || error.contains('Invalid')) {
        setState(() {
          status = l10n?.invalidSubscription ?? 'Invalid subscription';
        });
        _showSubscriptionDialog();
      } else {
        setState(() {
          status = l10n?.noServers ?? 'No servers available';
        });
      }
    }
    
    setState(() => isConnecting = false);
  }

  void _showSubscriptionDialog() {
    final controller = TextEditingController(text: VPNService.currentSubscriptionLink ?? '');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(ctx)?.enterSubscription ?? 'Enter Subscription'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(ctx)?.subscriptionLink ?? 'Subscription Link',
                border: const OutlineInputBorder(),
                hintText: 'https://...',
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => QRScannerPage()),
                );
                if (result != null) controller.text = result;
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                minimumSize: const Size(double.infinity, 45),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => launchUrl(Uri.parse('https://t.me/VPNProxyTestSupport')),
            child: Text(AppLocalizations.of(ctx)?.getSubscription ?? 'Get Subscription'),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                // Show loading
                showDialog(
                  context: ctx,
                  barrierDismissible: false,
                  builder: (_) => const Center(child: CircularProgressIndicator()),
                );
                
                final ok = await VPNService.saveSubscriptionLink(controller.text);
                
                // Close loading dialog
                Navigator.pop(ctx);
                
                if (ok) {
                  // Close subscription dialog
                  Navigator.pop(ctx);
                  _updateConnectionStatus();
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(AppLocalizations.of(context)?.subscriptionActivated ?? 'Subscription activated!'),
                      backgroundColor: Colors.green,
                    ));
                  }
                } else {
                  // Check if it's a network error or invalid subscription
                  if (mounted) {
                    final hasInternet = await VPNService.hasInternetConnection();
                    if (!hasInternet) {
                      // Network error - keep subscription, show warning
                      Navigator.pop(ctx); // Close dialog
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            children: const [
                              Icon(Icons.wifi_off, color: Colors.white),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text('Cannot verify subscription. Check internet connection.'),
                              ),
                            ],
                          ),
                          backgroundColor: Colors.orange,
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    } else {
                      // Invalid subscription
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(AppLocalizations.of(context)?.invalidSubscription ?? 'Invalid subscription'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                }
              }
            },
            child: Text(AppLocalizations.of(ctx)?.activate ?? 'Activate'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectToServer(ServerInfo server) async {
    setState(() {
      isConnecting = true;
      status = AppLocalizations.of(context)?.connecting ?? 'A Moment Please...';
    });
    await VPNService.connect(vlessUri: server.config, ping: server.ping);
    if (!mounted) return;
    setState(() => isConnecting = false);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1a1a2e) : Colors.grey[100],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          PopupMenuButton<Locale>(
            icon: const Icon(Icons.language),
            onSelected: widget.onLanguageChanged,
            itemBuilder: (_) => const [
              PopupMenuItem(value: Locale('en'), child: Text('English')),
              PopupMenuItem(value: Locale('fa'), child: Text('فارسی')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsPage(
                    onThemeChanged: widget.onThemeChanged,
                    onLanguageChanged: widget.onLanguageChanged,
                  ),
                ),
              );
            },
            tooltip: 'Settings',
          ),
          if (VPNService.currentSubscriptionLink != null && VPNService.currentSubscriptionLink!.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.card_membership),
              onPressed: _showSubscriptionDialog,
              tooltip: l10n?.changeSubscription ?? 'Change Subscription',
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n?.appTitle ?? 'AsadVPN',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                Text(
                  l10n?.unlimited ?? 'UNLIMITED',
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 30),
                
                // Connection button
                GestureDetector(
                  onTap: isConnecting ? null : _toggleConnection,
                  child: Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: VPNService.isConnected
                            ? [Colors.green, Colors.greenAccent]
                            : [Colors.red, Colors.redAccent],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (VPNService.isConnected ? Colors.green : Colors.red).withOpacity(0.5),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            VPNService.isConnected ? Icons.lock : Icons.power_settings_new,
                            size: 60,
                            color: Colors.white,
                          ),
                          if (VPNService.isConnected)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                l10n?.disconnect ?? 'Disconnect',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(height: 30),
                
                // Status text
                Text(
                  isConnecting ? (VPNService.isScanning ? scanStatus : (l10n?.connecting ?? 'Connecting...')) : status,
                  style: TextStyle(
                    fontSize: 18,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                
                // Progress indicator
                if (isConnecting || VPNService.isScanning)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Column(
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                        ),
                        if (VPNService.isScanning && VPNService.totalToScan > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: SizedBox(
                              width: 200,
                              child: LinearProgressIndicator(
                                value: VPNService.scanProgress / VPNService.totalToScan,
                                backgroundColor: Colors.grey[300],
                                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                
                // Traffic stats
                if (VPNService.isConnected)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.black26 : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              Column(
                                children: [
                                  Icon(Icons.arrow_downward, color: Colors.green, size: 20),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_formatBytes(downloadSpeed)}/s',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    _formatBytes(totalDownload),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                              Column(
                                children: [
                                  Icon(Icons.arrow_upward, color: Colors.orange, size: 20),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_formatBytes(uploadSpeed)}/s',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    _formatBytes(totalUpload),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                
                if (VPNService.currentSubscriptionLink == null || VPNService.currentSubscriptionLink!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: ElevatedButton.icon(
                      onPressed: _showSubscriptionDialog,
                      icon: const Icon(Icons.add),
                      label: Text(l10n?.enterSubscription ?? 'Enter Subscription'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          
          // Server list
          Container(
            height: 250,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF16213e) : Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n?.serverList ?? 'Server List',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      if (VPNService.isScanning)
                        Row(
                          children: const [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Scanning...',
                              style: TextStyle(color: Colors.blue, fontSize: 12),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: displayServers.isEmpty
                      ? Center(
                          child: Text(
                            VPNService.isScanning
                                ? scanStatus
                                : (l10n?.noServers ?? 'Tap Connect to scan servers'),
                            style: const TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: displayServers.length,
                          itemBuilder: (context, index) {
                            final server = displayServers[index];
                            final isCurrent = VPNService.isConnected &&
                                VPNService.currentConnectedConfig == server.config;
                            
                            return Card(
                              color: isCurrent
                                  ? Colors.green.withOpacity(0.2)
                                  : (isDark ? const Color(0xFF1a1a2e) : Colors.white),
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                dense: true,
                                leading: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _getProtocolColor(server.protocol).withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    server.protocol,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: _getProtocolColor(server.protocol),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  server.name,
                                  style: TextStyle(
                                    color: isCurrent ? Colors.green : (isDark ? Colors.white : Colors.black87),
                                    fontSize: 14,
                                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: server.successRate > 0
                                    ? Text(
                                        'Success: ${(server.successRate * 100).toStringAsFixed(0)}%',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: server.successRate > 0.7 ? Colors.green : Colors.orange,
                                        ),
                                      )
                                    : null,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isCurrent)
                                      const Icon(Icons.check_circle, size: 16, color: Colors.green),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.signal_cellular_alt,
                                      size: 16,
                                      color: server.ping < 100
                                          ? Colors.green
                                          : server.ping < 200
                                              ? Colors.orange
                                              : Colors.red,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${server.ping}ms',
                                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                                    ),
                                  ],
                                ),
                                onTap: (isConnecting || isCurrent) ? null : () => _connectToServer(server),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _getProtocolColor(String protocol) {
    switch (protocol) {
      case 'VLESS':
        return Colors.green;
      case 'VMESS':
        return Colors.blue;
      case 'TROJAN':
        return Colors.purple;
      case 'SS':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }
}