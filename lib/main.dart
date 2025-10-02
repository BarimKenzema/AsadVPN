import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/vpn_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(AsadVPNApp());
}

class AsadVPNApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AsadVPN (UNLIMITED)',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Color(0xFF0a0e27),
      ),
      home: VPNHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class VPNHomePage extends StatefulWidget {
  @override
  _VPNHomePageState createState() => _VPNHomePageState();
}

class _VPNHomePageState extends State<VPNHomePage> with SingleTickerProviderStateMixin {
  String status = 'Initializing...';
  bool isConnecting = false;
  String subscriptionStatus = 'checking';
  String? serverInfo;
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;
  
  @override
  void initState() {
    super.initState();
    
    // Setup animation for connect button
    _animationController = AnimationController(
      duration: Duration(seconds: 2),
      vsync: this,
    );
    
    _pulseAnimation = Tween<double>(
      begin: 1.0,
      end: 1.1,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    
    _animationController.repeat(reverse: true);
    
    _initialize();
  }
  
  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
  
  Future<void> _initialize() async {
    setState(() {
      status = 'Checking subscription...';
    });
    
    // Initialize VPN service
    await VPNService.init();
    
    // Check for device wipe abuse
    bool wasWiped = await VPNService.checkDeviceWipe();
    if (wasWiped) {
      _showAbuseWarning();
      return;
    }
    
    // Check subscription status
    final subInfo = await VPNService.checkSubscription();
    
    setState(() {
      subscriptionStatus = subInfo['status'] ?? 'error';
    });
    
    if (subscriptionStatus == 'expired') {
      _showExpiredDialog();
    } else if (subscriptionStatus == 'trial') {
      // Show trial info
      String trialEnd = subInfo['trial_end'] ?? '';
      _showTrialInfo(trialEnd);
      
      // Load trial configs
      String configUrl = subInfo['config_url'] ?? '';
      bool loaded = await VPNService.fetchConfigs(configUrl);
      
      setState(() {
        status = loaded ? 'Ready to connect' : 'Failed to load servers';
      });
    } else if (subscriptionStatus == 'active') {
      // Load subscription configs
      String configUrl = subInfo['config_url'] ?? VPNService.currentSubscriptionLink ?? '';
      
      if (configUrl.isEmpty) {
        _showEnterSubscriptionDialog();
      } else {
        bool loaded = await VPNService.fetchConfigs(configUrl);
        setState(() {
          status = loaded ? 'Ready to connect' : 'Failed to load servers';
        });
      }
    } else if (subscriptionStatus == 'error') {
      setState(() {
        status = 'Connection error. Check internet.';
      });
    }
  }
  
  void _showTrialInfo(String trialEnd) {
    try {
      DateTime endDate = DateTime.parse(trialEnd);
      int daysLeft = endDate.difference(DateTime.now()).inDays;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Free trial: $daysLeft days remaining'),
          backgroundColor: Colors.blue,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      // Error parsing date
    }
  }
  
  void _showAbuseWarning() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('⚠️ Warning', style: TextStyle(color: Colors.red)),
        content: Text(
          'This device has been flagged for attempting to bypass trial limitations. '
          'Please purchase a subscription to continue using AsadVPN.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              launchUrl(Uri.parse('https://t.me/VPNProxyTestSupport'));
            },
            child: Text('Get Subscription'),
          ),
        ],
      ),
    );
  }
  
  void _showExpiredDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Color(0xFF1a1a2e),
        title: Row(
          children: [
            Icon(Icons.timer_off, color: Colors.orange),
            SizedBox(width: 8),
            Text('Trial Expired'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Your 7-day free trial has ended.',
              style: TextStyle(color: Colors.white70),
            ),
            SizedBox(height: 20),
            Text(
              'Enter your subscription link or get one from our support:',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            SizedBox(height: 16),
            TextField(
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Subscription Link',
                labelStyle: TextStyle(color: Colors.white54),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white30),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white30),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.blue),
                ),
                prefixIcon: Icon(Icons.link, color: Colors.white54),
              ),
              onSubmitted: (value) async {
                if (value.trim().isNotEmpty) {
                  await VPNService.saveSubscriptionLink(value.trim());
                  Navigator.pop(context);
                  _initialize();
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              launchUrl(Uri.parse('https://t.me/VPNProxyTestSupport'));
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.telegram, size: 18),
                SizedBox(width: 4),
                Text('Get Subscription'),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  void _showEnterSubscriptionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Color(0xFF1a1a2e),
        title: Text('Enter Subscription'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Please enter your subscription link:',
              style: TextStyle(color: Colors.white70),
            ),
            SizedBox(height: 16),
            TextField(
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Subscription Link',
                labelStyle: TextStyle(color: Colors.white54),
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link, color: Colors.white54),
              ),
              onSubmitted: (value) async {
                if (value.trim().isNotEmpty) {
                  await VPNService.saveSubscriptionLink(value.trim());
                  Navigator.pop(context);
                  _initialize();
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              launchUrl(Uri.parse('https://t.me/VPNProxyTestSupport'));
            },
            child: Text('Get Subscription'),
          ),
        ],
      ),
    );
  }
  
  Future<void> _toggleConnection() async {
    if (VPNService.isConnected) {
      // Disconnect
      setState(() {
        status = 'Disconnecting...';
      });
      
      await VPNService.disconnect();
      
      setState(() {
        status = 'Disconnected';
        serverInfo = null;
      });
    } else {
      // Connect
      setState(() {
        isConnecting = true;
        status = 'Scanning servers...';
      });
      
      // Smart server selection
      Map<String, dynamic> result = await VPNService.selectBestServer();
      
      if (result['success'] == true) {
        setState(() {
          status = 'Connecting to ${result['protocol']} server...';
          serverInfo = '${result['protocol']} • ${result['candidates'] ?? 1} servers tested';
        });
        
        bool connected = await VPNService.connect(result['server']);
        
        setState(() {
          isConnecting = false;
          if (connected) {
            status = 'Connected';
            _animationController.stop();
          } else {
            status = 'Connection failed';
            serverInfo = null;
          }
        });
      } else {
        setState(() {
          isConnecting = false;
          status = result['error'] ?? 'No servers available';
          serverInfo = null;
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0a0e27),
              Color(0xFF151933),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo and Title
                Column(
                  children: [
                    Container(
                      padding: EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Colors.blue, Colors.blueAccent],
                        ),
                      ),
                      child: Icon(
                        Icons.security,
                        size: 40,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 20),
                    Text(
                      'AsadVPN',
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      'UNLIMITED',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.blue,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
                
                SizedBox(height: 60),
                
                // Connect Button
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: GestureDetector(
                    onTap: (isConnecting || subscriptionStatus == 'expired') ? null : _toggleConnection,
                    child: Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: VPNService.isConnected
                              ? [Color(0xFF00ff88), Color(0xFF00cc66)]
                              : isConnecting
                                  ? [Colors.orange, Colors.orangeAccent]
                                  : [Color(0xFF667eea), Color(0xFF764ba2)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: VPNService.isConnected
                                ? Colors.green.withOpacity(0.4)
                                : isConnecting
                                    ? Colors.orange.withOpacity(0.4)
                                    : Colors.blue.withOpacity(0.4),
                            blurRadius: 30,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                      child: Center(
                        child: isConnecting
                            ? CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 3,
                              )
                            : Icon(
                                VPNService.isConnected 
                                    ? Icons.lock 
                                    : Icons.power_settings_new,
                                size: 80,
                                color: Colors.white,
                              ),
                      ),
                    ),
                  ),
                ),
                
                SizedBox(height: 40),
                
                // Status Text
                Column(
                  children: [
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (serverInfo != null) ...[
                      SizedBox(height: 8),
                      Text(
                        serverInfo!,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ],
                ),
                
                Spacer(),
                
                // Bottom info
                if (subscriptionStatus == 'trial')
                  Container(
                    margin: EdgeInsets.only(bottom: 20),
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '🎁 Free Trial Active',
                      style: TextStyle(
                        color: Colors.blue,
                        fontSize: 14,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}