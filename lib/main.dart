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
  String? serverInfo;
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;
  bool hasValidSubscription = false;
  
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
    
    // Check if we have a saved subscription
    if (VPNService.currentSubscriptionLink != null) {
      setState(() {
        status = 'Validating subscription...';
      });
      
      bool isValid = await VPNService.validateSubscription();
      
      setState(() {
        hasValidSubscription = isValid;
        if (isValid) {
          status = 'Ready to connect';
        } else {
          status = 'Subscription expired or invalid';
          _showSubscriptionDialog(isExpired: true);
        }
      });
    } else {
      setState(() {
        hasValidSubscription = false;
        status = 'No subscription';
      });
      _showSubscriptionDialog(isExpired: false);
    }
  }
  
  void _showSubscriptionDialog({required bool isExpired}) {
    final TextEditingController linkController = TextEditingController();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Color(0xFF1a1a2e),
        title: Row(
          children: [
            Icon(
              isExpired ? Icons.timer_off : Icons.vpn_key,
              color: isExpired ? Colors.orange : Colors.blue,
            ),
            SizedBox(width: 8),
            Text(isExpired ? 'Subscription Expired' : 'Enter Subscription'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isExpired 
                ? 'Your subscription has expired. Please enter a new subscription link.'
                : 'Enter your subscription link to activate AsadVPN:',
              style: TextStyle(color: Colors.white70),
            ),
            SizedBox(height: 20),
            TextField(
              controller: linkController,
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Subscription Link',
                labelStyle: TextStyle(color: Colors.white54),
                hintText: 'https://konabalan.pythonanywhere.com/sub/...',
                hintStyle: TextStyle(color: Colors.white30, fontSize: 12),
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
            ),
            SizedBox(height: 10),
            Text(
              'Example: https://konabalan.pythonanywhere.com/sub/YOUR_TOKEN',
              style: TextStyle(fontSize: 10, color: Colors.white38),
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
          TextButton(
            onPressed: () async {
              String link = linkController.text.trim();
              if (link.isNotEmpty) {
                // Show loading
                Navigator.pop(context);
                setState(() {
                  status = 'Validating subscription...';
                });
                
                bool success = await VPNService.saveSubscriptionLink(link);
                
                if (success) {
                  setState(() {
                    hasValidSubscription = true;
                    status = 'Ready to connect';
                  });
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Subscription activated successfully!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } else {
                  setState(() {
                    hasValidSubscription = false;
                    status = 'Invalid subscription';
                  });
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Invalid subscription link. Please check and try again.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  
                  // Show dialog again
                  Future.delayed(Duration(seconds: 1), () {
                    _showSubscriptionDialog(isExpired: false);
                  });
                }
              }
            },
            child: Text('Activate'),
          ),
        ],
      ),
    );
  }
  
  Future<void> _toggleConnection() async {
    if (!hasValidSubscription) {
      _showSubscriptionDialog(isExpired: false);
      return;
    }
    
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
      
      // Check subscription validity again before connecting
      bool isValid = await VPNService.validateSubscription();
      
      if (!isValid) {
        setState(() {
          isConnecting = false;
          hasValidSubscription = false;
          status = 'Subscription expired';
        });
        _showSubscriptionDialog(isExpired: true);
        return;
      }
      
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
                    onTap: isConnecting ? null : _toggleConnection,
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
                                  : hasValidSubscription
                                      ? [Color(0xFF667eea), Color(0xFF764ba2)]
                                      : [Colors.grey, Colors.grey.shade700],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: VPNService.isConnected
                                ? Colors.green.withOpacity(0.4)
                                : isConnecting
                                    ? Colors.orange.withOpacity(0.4)
                                    : hasValidSubscription
                                        ? Colors.blue.withOpacity(0.4)
                                        : Colors.grey.withOpacity(0.2),
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
                
                // Bottom buttons
                Padding(
                  padding: EdgeInsets.only(bottom: 30),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Change Subscription button
                      if (VPNService.currentSubscriptionLink != null)
                        TextButton.icon(
                          onPressed: () {
                            _showSubscriptionDialog(isExpired: false);
                          },
                          icon: Icon(Icons.edit, size: 16),
                          label: Text('Change Subscription'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white54,
                          ),
                        ),
                    ],
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