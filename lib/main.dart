import 'qr_scanner_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
// CHANGE THIS LINE for native approach:
import 'services/native_vpn_service.dart';  // Instead of vpn_service.dart
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
  List<Map<String, dynamic>> displayServers = [];
  StreamSubscription? connectionSubscription;
  String? currentSubscriptionLink;
  bool isSubscriptionValid = false;
  List<String> configServers = [];
  
  @override
  void initState() {
    super.initState();
    _initialize();
    
    // Subscribe to connection state changes
    connectionSubscription = NativeVPNService.connectionStateController.stream.listen((connected) {
      setState(() {
        status = connected ? 'Connected' : 'Disconnected';
      });
    });
  }
  
  @override
  void dispose() {
    connectionSubscription?.cancel();
    super.dispose();
  }
  
  Future<void> _initialize() async {
    // Load subscription and validate
    await _loadSubscription();
    
    if (!isSubscriptionValid) {
      _showSubscriptionDialog();
    } else {
      setState(() {
        status = AppLocalizations.of(context)?.disconnected ?? 'Disconnected';
      });
    }
  }
  
  Future<void> _loadSubscription() async {
    // This would load from SharedPreferences and validate
    // For now, simplified version
    setState(() {
      isSubscriptionValid = currentSubscriptionLink != null;
    });
  }
  
  Future<void> _scanAndConnect() async {
    if (configServers.isEmpty) {
      setState(() {
        status = 'No servers available';
      });
      return;
    }
    
    setState(() {
      isConnecting = true;
      status = 'A Moment Please...';
    });
    
    // Pick first VLESS server for simplicity
    String? vlessServer = configServers.firstWhere(
      (config) => config.toLowerCase().startsWith('vless://'),
      orElse: () => configServers.first,
    );
    
    bool connected = await NativeVPNService.connect(vlessServer);
    
    setState(() {
      isConnecting = false;
      status = connected ? 'Connected' : 'Connection failed';
    });
  }
  
  Future<void> _toggleConnection() async {
    if (NativeVPNService.isConnected) {
      await NativeVPNService.disconnect();
      setState(() {
        status = AppLocalizations.of(context)?.disconnected ?? 'Disconnected';
        displayServers = [];
      });
    } else {
      await _scanAndConnect();
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
                // Save and validate subscription
                currentSubscriptionLink = controller.text;
                // Here you would fetch and parse configs
                Navigator.pop(context);
                setState(() {
                  isSubscriptionValid = true;
                  status = AppLocalizations.of(context)?.disconnected ?? 'Disconnected';
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Subscription activated!'),
                    backgroundColor: Colors.green,
                  ),
                );
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
          if (isSubscriptionValid)
            IconButton(
              icon: Icon(Icons.card_membership),
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
                  onTap: (!isSubscriptionValid || isConnecting) ? null : _toggleConnection,
                  child: Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: NativeVPNService.isConnected
                            ? [Colors.green, Colors.greenAccent]
                            : [Colors.red, Colors.redAccent],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: NativeVPNService.isConnected
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
                            NativeVPNService.isConnected ? Icons.lock : Icons.power_settings_new,
                            size: 60,
                            color: Colors.white,
                          ),
                          if (NativeVPNService.isConnected)
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
                if (!isSubscriptionValid)
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
          
          // Server List Section (simplified for native approach)
          Container(
            height: 250,
            decoration: BoxDecoration(
              color: Color(0xFF16213e),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            child: Center(
              child: Text(
                'Server management coming soon',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }
}