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

class _VPNHomePageState extends State<VPNHomePage> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  String status = 'Disconnected';
  bool isConnecting = false;
  List<ServerInfo> displayServers = [];
  List<ServerInfo> allServersList = [];
  StreamSubscription? serversSub;
  StreamSubscription? allServersSub;
  StreamSubscription? connectionSub;
  StreamSubscription? statusSub;
  StreamSubscription? progressSub;
  StreamSubscription? subscriptionExpiredSub;
  StreamSubscription? networkChangeSub;
  
  int downloadSpeed = 0;
  int uploadSpeed = 0;
  int totalDownload = 0;
  int totalUpload = 0;
  String scanStatus = '';
  
  // Network info
  String currentNetworkName = 'Detecting...';
  bool showNetworkChangeNotification = false;

  // Tab controller
  late TabController _tabController;
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Initialize tab controller
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      setState(() {
        _currentTabIndex = _tabController.index;
      });
    });
    
    _initialize();

    serversSub = VPNService.serversStreamController.stream.listen((servers) {
      if (mounted) setState(() => displayServers = servers);
    });

    allServersSub = VPNService.allServersStreamController.stream.listen((servers) {
      if (mounted) setState(() => allServersList = servers);
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
          if (VPNService.isScanningAll) {
            scanStatus = 'Scanning all servers... $progress/${VPNService.totalToScan}';
          } else {
            scanStatus = 'Testing servers... $progress/${VPNService.totalToScan}';
          }
        });
      }
    });

    subscriptionExpiredSub = VPNService.subscriptionExpiredController.stream.listen((message) {
      if (mounted) {
        // Show dialog when subscription expires
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: const [
                Icon(Icons.error_outline, color: Colors.red, size: 32),
                SizedBox(width: 12),
                Text('Subscription Expired'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                const Text(
                  'All server data has been cleared. Please purchase a new subscription to continue.',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse('https://t.me/VPNProxyTestSupport')),
                icon: const Icon(Icons.shopping_cart),
                label: const Text('Buy Subscription'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.green,
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showSubscriptionDialog();
                },
                child: const Text('Enter New Subscription'),
              ),
            ],
          ),
        );
        
        // Update UI
        setState(() {
          status = 'Subscription Expired';
          displayServers.clear();
          allServersList.clear();
        });
      }
    });

    // Listen for network changes
    networkChangeSub = VPNService.networkChangeController.stream.listen((networkName) {
      if (mounted) {
        setState(() {
          currentNetworkName = networkName;
          showNetworkChangeNotification = true;
        });
        
        // Show snackbar for network change
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.network_check, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Network changed to: $networkName'),
                ),
              ],
            ),
            backgroundColor: Colors.blue,
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
        
        // Hide notification after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              showNetworkChangeNotification = false;
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    serversSub?.cancel();
    allServersSub?.cancel();
    connectionSub?.cancel();
    statusSub?.cancel();
    progressSub?.cancel();
    subscriptionExpiredSub?.cancel();
    networkChangeSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    if (state == AppLifecycleState.resumed) {
      debugPrint('📱 App resumed from background');
      _updateConnectionStatus();
      
      // Resume auto-scan when app comes back
      if (!VPNService.isConnected && 
          VPNService.fastestServers.length < VPNService.MAX_DISPLAY_SERVERS &&
          VPNService.currentSubscriptionLink != null &&
          !VPNService.isScanning) {
        debugPrint('🔵 Resuming auto-scan (${VPNService.fastestServers.length}/${VPNService.MAX_DISPLAY_SERVERS} servers)...');
        VPNService.resumeAutoScan();
      }
    } else if (state == AppLifecycleState.paused) {
      debugPrint('📱 App going to background (scan will pause and resume when you return)');
    }
  }

  void _updateConnectionStatus() {
    final l10n = AppLocalizations.of(context);
    setState(() {
      // Update network name
      currentNetworkName = VPNService.currentNetworkName ?? 'Unknown';
      
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
    
    // Update network name after init
    setState(() {
      currentNetworkName = VPNService.currentNetworkName ?? 'Detecting...';
      allServersList = List.from(VPNService.allServers);
    });
    
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
      } else if (error.contains('cancelled')) {
        setState(() {
          status = 'Scan cancelled';
        });
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
                showDialog(
                  context: ctx,
                  barrierDismissible: false,
                  builder: (_) => const Center(child: CircularProgressIndicator()),
                );
                
                final ok = await VPNService.saveSubscriptionLink(controller.text);
                
                Navigator.pop(ctx);
                
                if (ok) {
                  Navigator.pop(ctx);
                  _updateConnectionStatus();
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(AppLocalizations.of(context)?.subscriptionActivated ?? 'Subscription activated!'),
                      backgroundColor: Colors.green,
                    ));
                  }
                } else {
                  if (mounted) {
                    final hasInternet = await VPNService.hasInternetConnection();
                    if (!hasInternet) {
                      Navigator.pop(ctx);
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

  Future<void> _scanAllServers() async {
    if (VPNService.isScanningAll) {
      VPNService.cancelScanAll();
      return;
    }

    setState(() {
      scanStatus = 'Starting scan...';
    });

    final result = await VPNService.forceScanAllServers();
    
    if (!mounted) return;

    if (result['success'] == true) {
      final tested = result['tested'] ?? 0;
      final found = result['found'] ?? 0;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Scan complete: Found $found working servers (tested $tested)'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    } else if (result['error'] == 'Scan cancelled by user') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Scan cancelled'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      final tested = result['tested'] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No working servers found (tested $tested)'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }

    setState(() {
      scanStatus = '';
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  IconData _getNetworkIcon() {
    if (currentNetworkName.toLowerCase().contains('wifi') || 
        currentNetworkName.toLowerCase().contains('wi-fi')) {
      return Icons.wifi;
    } else if (currentNetworkName.toLowerCase().contains('mobile') ||
               currentNetworkName.toLowerCase().contains('cellular')) {
      return Icons.signal_cellular_alt;
    }
    return Icons.network_check;
  }

  String _truncateNetworkName(String name) {
    if (name.length > 15) {
      return '${name.substring(0, 12)}...';
    }
    return name;
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

  String _getNetworkBadges(ServerInfo server) {
    if (VPNService.serverCache[server.config] == null) {
      return '';
    }
    
    final cache = VPNService.serverCache[server.config]!;
    final networks = cache.networkStats.keys.toList();
    
    if (networks.isEmpty) return '';
    
    return networks.take(3).map((netId) {
      final profile = VPNService.networkProfiles[netId];
      if (profile != null) {
        final name = profile.networkName;
        if (name.length > 8) return name.substring(0, 8);
        return name;
      }
      return '';
    }).where((n) => n.isNotEmpty).join(', ');
  }  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1a1a2e) : Colors.grey[100],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Network indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: VPNService.isConnected ? Colors.green.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: VPNService.isConnected ? Colors.green : Colors.grey,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _getNetworkIcon(),
                    size: 14,
                    color: VPNService.isConnected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _truncateNetworkName(currentNetworkName),
                    style: TextStyle(
                      fontSize: 11,
                      color: VPNService.isConnected ? Colors.green : Colors.grey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        centerTitle: true,
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
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: Icon(Icons.vpn_key),
              text: 'Connect',
            ),
            Tab(
              icon: Icon(Icons.list_alt),
              text: 'All Servers',
            ),
          ],
          indicatorColor: Colors.blue,
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Tab 1: Connect Screen
          _buildConnectTab(l10n, isDark),
          
          // Tab 2: All Servers
          _buildAllServersTab(l10n, isDark),
        ],
      ),
    );
  }

  // ========================= CONNECT TAB =========================
  Widget _buildConnectTab(AppLocalizations? l10n, bool isDark) {
    return Column(
      children: [
        // Network change notification banner
        if (showNetworkChangeNotification)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.blue.withOpacity(0.15),
            child: Row(
              children: [
                const Icon(Icons.network_check, color: Colors.blue, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Network changed to: $currentNetworkName',
                    style: const TextStyle(color: Colors.blue, fontSize: 13),
                  ),
                ),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                ),
              ],
            ),
          ),
        
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
                isConnecting ? (VPNService.isScanning ? 'Finding servers...' : (l10n?.connecting ?? 'Connecting...')) : status,
                style: TextStyle(
                  fontSize: 18,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              
              // Progress indicator with CANCEL button
              if (isConnecting || VPNService.isScanning)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: () {
                          VPNService.cancelScan();
                          setState(() {
                            isConnecting = false;
                            status = 'Scan cancelled';
                          });
                        },
                        icon: const Icon(Icons.cancel, color: Colors.red),
                        label: const Text(
                          'Cancel',
                          style: TextStyle(color: Colors.red, fontSize: 16),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
              
              if (VPNService.currentSubscriptionLink == null || 
                  VPNService.currentSubscriptionLink!.isEmpty ||
                  VPNService.isSubscriptionExpired)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: ElevatedButton.icon(
                    onPressed: _showSubscriptionDialog,
                    icon: Icon(VPNService.isSubscriptionExpired ? Icons.error_outline : Icons.add),
                    label: Text(
                      VPNService.isSubscriptionExpired 
                          ? 'Subscription Expired - Renew Now' 
                          : (l10n?.enterSubscription ?? 'Enter Subscription')
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VPNService.isSubscriptionExpired ? Colors.red : Colors.blue,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
                  
        // Server list at bottom
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
              // Scanning progress indicator
              if (!VPNService.isConnected && 
                  VPNService.fastestServers.length < VPNService.MAX_DISPLAY_SERVERS && 
                  VPNService.currentSubscriptionLink != null &&
                  !VPNService.isSubscriptionExpired)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: Colors.blue.withOpacity(0.1),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Finding servers for $currentNetworkName... ${VPNService.fastestServers.length}/${VPNService.MAX_DISPLAY_SERVERS}',
                          style: TextStyle(color: Colors.blue, fontSize: 12),
                        ),
                      ),
                      Text(
                        'Background',
                        style: TextStyle(color: Colors.blue.withOpacity(0.7), fontSize: 10),
                      ),
                    ],
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n?.serverList ?? 'Server List',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        if (displayServers.isNotEmpty)
                          Text(
                            '$currentNetworkName • ${displayServers.length} servers',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[600],
                            ),
                          ),
                      ],
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
                          VPNService.isSubscriptionExpired
                              ? 'Subscription expired'
                              : (VPNService.isScanning
                                  ? 'Finding servers for $currentNetworkName...'
                                  : (l10n?.noServers ?? 'Tap Connect to scan servers')),
                          style: TextStyle(
                            color: VPNService.isSubscriptionExpired ? Colors.red : Colors.grey,
                            fontSize: 14,
                          ),
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
                                      'Success: ${(server.successRate * 100).toStringAsFixed(0)}% on $currentNetworkName',
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
    );
  }

  // ========================= ALL SERVERS TAB =========================
  Widget _buildAllServersTab(AppLocalizations? l10n, bool isDark) {
    return Column(
      children: [
        // Scan All button and status
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF16213e) : Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (VPNService.currentSubscriptionLink == null || 
                                  VPNService.isSubscriptionExpired)
                          ? null
                          : _scanAllServers,
                      icon: Icon(VPNService.isScanningAll ? Icons.cancel : Icons.search),
                      label: Text(VPNService.isScanningAll ? 'Cancel Scan' : 'Scan All Servers'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: VPNService.isScanningAll ? Colors.red : Colors.blue,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
              if (VPNService.isScanningAll && scanStatus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          scanStatus,
                          style: const TextStyle(color: Colors.blue, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        
        // Server count header
        if (allServersList.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: isDark ? const Color(0xFF16213e).withOpacity(0.5) : Colors.grey[200],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total: ${allServersList.length} servers',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                Text(
                  'Tested: ${allServersList.where((s) => s.ping != -1).length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        
        // All servers list
        Expanded(
          child: allServersList.isEmpty
              ? Center(
                  child: Text(
                    VPNService.isSubscriptionExpired
                        ? 'Subscription expired'
                        : 'No subscription loaded',
                    style: TextStyle(
                      color: VPNService.isSubscriptionExpired ? Colors.red : Colors.grey,
                      fontSize: 14,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: allServersList.length,
                  itemBuilder: (context, index) {
                    final server = allServersList[index];
                    final isCurrent = VPNService.isConnected &&
                        VPNService.currentConnectedConfig == server.config;
                    final isTested = server.ping != -1;
                    final networkBadges = _getNetworkBadges(server);
                    
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
                        subtitle: networkBadges.isNotEmpty
                            ? Text(
                                'Works on: $networkBadges',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.blue,
                                ),
                              )
                            : (isTested ? Text(
                                'Global: ${(server.successRate * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: server.successRate > 0.5 ? Colors.green : Colors.orange,
                                ),
                              ) : null),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isCurrent)
                              const Icon(Icons.check_circle, size: 16, color: Colors.green)
                            else if (!isTested)
                              const Icon(Icons.help_outline, size: 16, color: Colors.grey)
                            else
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
                              isTested ? '${server.ping}ms' : 'Not tested',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        onTap: (isConnecting || isCurrent || VPNService.isScanningAll) 
                            ? null 
                            : () => _connectToServer(server),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
