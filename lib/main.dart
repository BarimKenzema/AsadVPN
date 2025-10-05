import 'qr_scanner_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/vpn_service.dart';
import 'dart:async';

void main() => runApp(AsadVPNApp());

class AsadVPNApp extends StatefulWidget {
  @override
  State<AsadVPNApp> createState() => _AsadVPNAppState();
}

class _AsadVPNAppState extends State<AsadVPNApp> {
  Locale _locale = const Locale('en');
  void _changeLanguage(Locale locale) => setState(() => _locale = locale);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AsadVPN',
      locale: _locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('fa')],
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1a1a2e),
      ),
      home: VPNHomePage(onLanguageChanged: _changeLanguage),
    );
  }
}

class VPNHomePage extends StatefulWidget {
  final void Function(Locale) onLanguageChanged;
  const VPNHomePage({required this.onLanguageChanged, Key? key}) : super(key: key);

  @override
  State<VPNHomePage> createState() => _VPNHomePageState();
}

class _VPNHomePageState extends State<VPNHomePage> with WidgetsBindingObserver {
  String status = 'Disconnected';
  bool isConnecting = false;
  List<ServerInfo> displayServers = [];
  StreamSubscription? serversSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    serversSub = VPNService.serversStreamController.stream.listen((servers) {
      if (!mounted) return;
      setState(() => displayServers = servers);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    serversSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _updateStatus();
  }

  Future<void> _initialize() async {
    await VPNService.init();
    if (!VPNService.isSubscriptionValid) {
      _showSubscriptionDialog();
    } else {
      _updateStatus();
    }
  }

  void _updateStatus() {
    final l10n = AppLocalizations.of(context);
    setState(() {
      status = VPNService.isConnected
          ? (l10n?.connected ?? 'Connected')
          : (l10n?.disconnected ?? 'Disconnected');
    });
  }

  Future<void> _toggleConnection() async {
    final l10n = AppLocalizations.of(context);
    if (VPNService.isConnected) {
      await VPNService.disconnect();
      setState(() {
        status = l10n?.disconnected ?? 'Disconnected';
        displayServers = [];
      });
    } else {
      setState(() {
        isConnecting = true;
        status = l10n?.connecting ?? 'A Moment Please...';
      });

      final result = await VPNService.scanAndSelectBestServer();
      if (result['success'] == true) {
        final ok = await VPNService.connect(result['server']);
        setState(() {
          isConnecting = false;
          status = ok
              ? (l10n?.connected ?? 'Connected')
              : 'Connection failed';
        });
      } else {
        setState(() {
          isConnecting = false;
          status = l10n?.noServers ?? 'No servers available';
        });
      }
    }
  }

  void _showSubscriptionDialog() {
    final controller = TextEditingController();
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
                hintText: 'https://konabalan.pythonanywhere.com/sub/...',
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
                final ok = await VPNService.saveSubscriptionLink(controller.text);
                if (ok) {
                  Navigator.pop(ctx);
                  _updateStatus();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(AppLocalizations.of(context)?.subscriptionActivated ?? 'Subscription activated!'),
                    backgroundColor: Colors.green,
                  ));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(AppLocalizations.of(context)?.invalidSubscription ?? 'Invalid subscription'),
                    backgroundColor: Colors.red,
                  ));
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
    final l10n = AppLocalizations.of(context);
    setState(() {
      isConnecting = true;
      status = l10n?.connecting ?? 'A Moment Please...';
    });

    final ok = await VPNService.connect(server.config);

    setState(() {
      isConnecting = false;
      status = ok ? (l10n?.connected ?? 'Connected') : 'Connection failed';
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
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
          if (VPNService.isSubscriptionValid)
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
                Text('AsadVPN', style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white)),
                const Text('UNLIMITED', style: TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 50),
                GestureDetector(
                  onTap: (!VPNService.isSubscriptionValid || isConnecting) ? null : _toggleConnection,
                  child: Container(
                    width: 150, height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: VPNService.isConnected ? [Colors.green, Colors.greenAccent] : [Colors.red, Colors.redAccent],
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (VPNService.isConnected ? Colors.green : Colors.red).withOpacity(0.5),
                          blurRadius: 20, spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(VPNService.isConnected ? Icons.lock : Icons.power_settings_new, size: 60, color: Colors.white),
                          if (VPNService.isConnected)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text('Disconnect', style: TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                Text(isConnecting ? (l10n?.connecting ?? 'A Moment Please...') : status, style: const TextStyle(fontSize: 18, color: Colors.white70)),
                if (isConnecting)
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.blue)),
                  ),
                if (!VPNService.isSubscriptionValid)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: ElevatedButton.icon(
                      onPressed: _showSubscriptionDialog,
                      icon: const Icon(Icons.add),
                      label: Text(l10n?.enterSubscription ?? 'Enter Subscription'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                    ),
                  ),
              ],
            ),
          ),
          // Server list
            Container(
            height: 250,
            decoration: const BoxDecoration(
              color: Color(0xFF16213e),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(l10n?.serverList ?? 'Server List', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                      if (VPNService.isScanning)
                        Row(children: const [
                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.blue))),
                          SizedBox(width: 8),
                          Text('Scanning...', style: TextStyle(color: Colors.blue, fontSize: 12)),
                        ]),
                    ],
                  ),
                ),
                Expanded(
                  child: displayServers.isEmpty
                      ? Center(
                          child: Text(
                            VPNService.isConnected ? (l10n?.scanningServers ?? 'Scanning servers...') : (l10n?.noServers ?? 'No servers available'),
                            style: const TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: displayServers.length,
                          itemBuilder: (context, index) {
                            final server = displayServers[index];
                            final isCurrent = VPNService.isConnected && (server.config == VPNService.configServers.firstWhere((_) => true, orElse: () => server.config));
                            return Card(
                              color: isCurrent ? Colors.green.withOpacity(0.2) : const Color(0xFF1a1a2e),
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                dense: true,
                                leading: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('VLESS', style: TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.bold)),
                                ),
                                title: Text(server.name, style: const TextStyle(color: Colors.white, fontSize: 14), overflow: TextOverflow.ellipsis),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isCurrent) const Icon(Icons.check_circle, size: 16, color: Colors.green),
                                    const SizedBox(width: 4),
                                    Icon(Icons.signal_cellular_alt, size: 16, color: server.ping < 100 ? Colors.green : server.ping < 200 ? Colors.orange : Colors.red),
                                    const SizedBox(width: 4),
                                    Text('${server.ping}ms', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                  ],
                                ),
                                onTap: isCurrent || isConnecting ? null : () async {
                                  setState(() {
                                    isConnecting = true;
                                    status = l10n?.connecting ?? 'A Moment Please...';
                                  });
                                  final ok = await VPNService.connect(server.config);
                                  setState(() {
                                    isConnecting = false;
                                    status = ok ? (l10n?.connected ?? 'Connected') : 'Connection failed';
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