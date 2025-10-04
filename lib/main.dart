import 'qr_scanner_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/vpn_service.dart';
import 'dart:async';

void main() {
  runApp(AsadVPNApp());
}

class AsadVPNApp extends StatefulWidget {
  @override
  _AsadVPNAppState createState() => _AsadVPNAppState();
}

class _AsadVPNAppState extends State<AsadVPNApp> {
  Locale _locale = Locale('en');
  
  void _changeLanguage(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AsadVPN',
      locale: _locale,
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: [
        Locale('en'),
        Locale('fa'),
      ],
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Color(0xFF1a1a2e),
      ),
      home: VPNHomePage(onLanguageChanged: _changeLanguage),
    );
  }
}

class VPNHomePage extends StatefulWidget {
  final Function(Locale) onLanguageChanged;
  
  VPNHomePage({required this.onLanguageChanged});
  
  @override
  _VPNHomePageState createState() => _VPNHomePageState();
}

class _VPNHomePageState extends State<VPNHomePage> {
  String status = '';
  bool isConnecting = false;
  List<ServerInfo> displayServers = [];
  StreamSubscription? serversSubscription;
  bool showServerList = false;
  
  @override
  void initState() {
    super.initState();
    _initialize();
    
    // Subscribe to server updates
    serversSubscription = VPNService.serversStreamController.stream.listen((servers) {
      setState(() {
        displayServers = servers;
      });
    });
  }
  
  @override
  void dispose() {
    serversSubscription?.cancel();
    super.dispose();
  }
  
  Future<void> _initialize() async {
    await VPNService.init();
    
    if (!VPNService.isSubscriptionValid) {
      _showSubscriptionDialog();
    } else {
      setState(() {
        status = AppLocalizations.of(context)?.disconnected ?? 'Disconnected';
      });
    }
  }
  
  Future<void> _toggleConnection() async {
    if (VPNService.isConnected) {
      await VPNService.disconnect();
      setState(() {
        status = AppLocalizations.of(context)?.disconnected ?? 'Disconnected';
        displayServers = [];
      });
    } else {
      setState(() {
        isConnecting = true;
        status = AppLocalizations.of(context)?.connecting ?? 'A Moment Please...';
      });
      
      final result = await VPNService.scanAndSelectBestServer();
      
      if (result['success']) {
        bool connected = await VPNService.connect(result['server'], ping: result['ping']);
        
        setState(() {
          isConnecting = false;
          if (connected) {
            status = '${AppLocalizations.of(context)?.connected ?? 'Connected'} (${result['ping']}ms)';
          } else {
            status = 'Connection failed';
          }
        });
      } else {
        setState(() {
          isConnecting = false;
          status = AppLocalizations.of(context)?.noServers ?? 'No servers available';
        });
      }
    }
  }
  
  void _showSubscriptionDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)?.enterSubscription ?? 'Enter Subscription'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context)?.subscriptionLink ?? 'Subscription Link',
                border: OutlineInputBorder(),
                hintText: 'https://konabalan.pythonanywhere.com/sub/...',
              ),
            ),
            SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => QRScannerPage()),
                );
                if (result != null) {
                  controller.text = result;
                }
              },
              icon: Icon(Icons.qr_code_scanner),
              label: Text('Scan QR Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                minimumSize: Size(double.infinity, 45),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              launchUrl(Uri.parse('https://t.me/VPNProxyTestSupport'));
            },
            child: Text(AppLocalizations.of(context)?.getSubscription ?? 'Get Subscription'),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                bool success = await VPNService.saveSubscriptionLink(controller.text);
                if (success) {
                  Navigator.pop(context);
                  setState(() {
                    status = AppLocalizations.of(context)?.disconnected ?? 'Disconnected';
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppLocalizations.of(context)?.subscriptionActivated ?? 
                                   'Subscription activated!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppLocalizations.of(context)?.invalidSubscription ?? 
                                   'Invalid subscription'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(AppLocalizations.of(context)?.activate ?? 'Activate'),
          ),
        ],
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    return Scaffold(
      backgroundColor: Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          // Language switcher
          PopupMenuButton<Locale>(
            icon: Icon(Icons.language),
            onSelected: (Locale locale) {
              widget.onLanguageChanged(locale);
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: Locale('en'),
                child: Text('English'),
              ),
              PopupMenuItem(
                value: Locale('fa'),
                child: Text('فارسی'),
              ),
            ],
          ),
          // Subscription management
          if (VPNService.isSubscriptionValid)
            IconButton(
              icon: Icon(Icons.card_membership),
              onPressed: _showSubscriptionDialog,
              tooltip: l10n?.changeSubscription ?? 'Change Subscription',
            ),
        ],
      ),
      body: Column(
        children: [
          // Main VPN UI
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n?.appTitle ?? 'AsadVPN',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  l10n?.unlimited ?? 'UNLIMITED',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
                SizedBox(height: 50),
                GestureDetector(
                  onTap: (!VPNService.isSubscriptionValid || isConnecting) ? null : _toggleConnection,
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
                          color: VPNService.isConnected
                              ? Colors.green.withOpacity(0.5)
                              : Colors.red.withOpacity(0.5),
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
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                l10n?.disconnect ?? 'Disconnect',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 30),
                Text(
                  isConnecting ? (l10n?.connecting ?? 'A Moment Please...') : status,
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.white70,
                  ),
                ),
                if (isConnecting)
                  Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                    ),
                  ),
                if (!VPNService.isSubscriptionValid)
                  Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: ElevatedButton.icon(
                      onPressed: _showSubscriptionDialog,
                      icon: Icon(Icons.add),
                      label: Text(l10n?.enterSubscription ?? 'Enter Subscription'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          
          // Server List Section
          Container(
            height: 250,
            decoration: BoxDecoration(
              color: Color(0xFF16213e),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            child: Column(
              children: [
                // Header
                Container(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n?.serverList ?? 'Server List',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (VPNService.isScanning)
                        Row(
                          children: [
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
                              l10n?.scanningServers ?? 'Scanning...',
                              style: TextStyle(
                                color: Colors.blue,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                
                // Server List
                Expanded(
                  child: displayServers.isEmpty
                      ? Center(
                          child: Text(
                            VPNService.isConnected 
                                ? (l10n?.scanningServers ?? 'Scanning servers...')
                                : (l10n?.noServers ?? 'No servers available'),
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 14,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          itemCount: displayServers.length,
                          itemBuilder: (context, index) {
                            final server = displayServers[index];
                            final isCurrentServer = VPNService.currentConnectedConfig == server.config;
                            
                            return Card(
                              color: isCurrentServer 
                                  ? Colors.green.withOpacity(0.2)
                                  : Color(0xFF1a1a2e),
                              margin: EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                dense: true,
                                leading: Container(
                                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: server.protocol == 'VLESS' 
                                        ? Colors.green.withOpacity(0.2)
                                        : Colors.blue.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    server.protocol,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: server.protocol == 'VLESS' 
                                          ? Colors.green 
                                          : Colors.blue,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  server.name,
                                  style: TextStyle(
                                    color: isCurrentServer ? Colors.green : Colors.white,
                                    fontSize: 14,
                                    fontWeight: isCurrentServer ? FontWeight.bold : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isCurrentServer)
                                      Icon(
                                        Icons.check_circle,
                                        size: 16,
                                        color: Colors.green,
                                      ),
                                    SizedBox(width: 4),
                                    Icon(
                                      Icons.signal_cellular_alt,
                                      size: 16,
                                      color: server.ping < 100 
                                          ? Colors.green 
                                          : server.ping < 200 
                                              ? Colors.orange 
                                              : Colors.red,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      '${server.ping}ms',
                                      style: TextStyle(
                                        color: Colors.grey,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                                onTap: (VPNService.isConnected || isConnecting || isCurrentServer) ? null : () async {
                                  setState(() {
                                    isConnecting = true;
                                    status = l10n?.connecting ?? 'A Moment Please...';
                                  });
                                  
                                  bool connected = await VPNService.connect(server.config, ping: server.ping);
                                  
                                  setState(() {
                                    isConnecting = false;
                                    if (connected) {
                                      status = '${l10n?.connected ?? 'Connected'} (${server.ping}ms)';
                                    } else {
                                      status = 'Connection failed';
                                    }
                                  });
                                },
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
}