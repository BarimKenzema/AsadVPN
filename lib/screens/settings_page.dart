import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

class SettingsPage extends StatefulWidget {
  final void Function(ThemeMode) onThemeChanged;
  final void Function(Locale) onLanguageChanged;

  const SettingsPage({
    required this.onThemeChanged,
    required this.onLanguageChanged,
    Key? key,
  }) : super(key: key);

  @override
  _SettingsPageState createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool autoConnect = false;
  bool killSwitch = false;
  String selectedProtocol = 'All';
  String dnsServer = 'Auto';
  ThemeMode currentTheme = ThemeMode.dark;
  Locale currentLocale = const Locale('en');

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      autoConnect = prefs.getBool('auto_connect') ?? false;
      killSwitch = prefs.getBool('kill_switch') ?? false;
      selectedProtocol = prefs.getString('preferred_protocol') ?? 'All';
      dnsServer = prefs.getString('dns_server') ?? 'Auto';
      
      final themeStr = prefs.getString('theme_mode') ?? 'dark';
      currentTheme = themeStr == 'light' ? ThemeMode.light : ThemeMode.dark;
      
      final localeStr = prefs.getString('locale') ?? 'en';
      currentLocale = Locale(localeStr);
    });
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1a1a2e) : Colors.grey[100],
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Connection Settings
          _buildSectionHeader('Connection', Icons.link),
          _buildCard(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Auto-connect on startup'),
                  subtitle: const Text('Connect to last server automatically'),
                  value: autoConnect,
                  onChanged: (value) {
                    setState(() => autoConnect = value);
                    _saveSetting('auto_connect', value);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Preferred Protocol'),
                  subtitle: Text(selectedProtocol),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => _showProtocolPicker(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Network Settings
          _buildSectionHeader('Network', Icons.network_check),
          _buildCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text('DNS Server'),
                  subtitle: Text(dnsServer),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => _showDNSPicker(),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Split Tunneling'),
                  subtitle: const Text('Exclude apps from VPN'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => _showSplitTunneling(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Security Settings
          _buildSectionHeader('Security', Icons.security),
          _buildCard(
            child: SwitchListTile(
              title: const Text('Kill Switch'),
              subtitle: const Text('Block internet if VPN disconnects'),
              value: killSwitch,
              onChanged: (value) {
                setState(() => killSwitch = value);
                _saveSetting('kill_switch', value);
              },
            ),
          ),

          const SizedBox(height: 24),

          // Appearance Settings
          _buildSectionHeader('Appearance', Icons.palette),
          _buildCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Theme'),
                  subtitle: Text(currentTheme == ThemeMode.dark ? 'Dark' : 'Light'),
                  trailing: Switch(
                    value: currentTheme == ThemeMode.dark,
                    onChanged: (value) {
                      final newTheme = value ? ThemeMode.dark : ThemeMode.light;
                      setState(() => currentTheme = newTheme);
                      _saveSetting('theme_mode', value ? 'dark' : 'light');
                      widget.onThemeChanged(newTheme);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Language'),
                  subtitle: Text(currentLocale.languageCode == 'en' ? 'English' : 'فارسی'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => _showLanguagePicker(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // About
          _buildSectionHeader('About', Icons.info_outline),
          _buildCard(
            child: Column(
              children: [
                const ListTile(
                  title: Text('Version'),
                  trailing: Text('1.0.0', style: TextStyle(color: Colors.grey)),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Clear Cache'),
                  trailing: const Icon(Icons.delete_outline),
                  onTap: () => _clearCache(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.blue),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16213e) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  void _showProtocolPicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Protocol'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: ['All', 'VLESS', 'VMESS', 'TROJAN'].map((protocol) {
            return RadioListTile<String>(
              title: Text(protocol),
              value: protocol,
              groupValue: selectedProtocol,
              onChanged: (value) {
                setState(() => selectedProtocol = value!);
                _saveSetting('preferred_protocol', value);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showDNSPicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select DNS Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            'Auto',
            'Cloudflare (1.1.1.1)',
            'Google (8.8.8.8)',
            'AdGuard',
          ].map((dns) {
            return RadioListTile<String>(
              title: Text(dns),
              value: dns,
              groupValue: dnsServer,
              onChanged: (value) {
                setState(() => dnsServer = value!);
                _saveSetting('dns_server', value);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showLanguagePicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Language'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('English'),
              value: 'en',
              groupValue: currentLocale.languageCode,
              onChanged: (value) {
                final newLocale = Locale(value!);
                setState(() => currentLocale = newLocale);
                _saveSetting('locale', value);
                widget.onLanguageChanged(newLocale);
                Navigator.pop(ctx);
              },
            ),
            RadioListTile<String>(
              title: const Text('فارسی'),
              value: 'fa',
              groupValue: currentLocale.languageCode,
              onChanged: (value) {
                final newLocale = Locale(value!);
                setState(() => currentLocale = newLocale);
                _saveSetting('locale', value);
                widget.onLanguageChanged(newLocale);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSplitTunneling() async {
    // Request permission to query installed apps
    final status = await Permission.ignoreBatteryOptimizations.request();
    
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permission required to access apps')),
      );
      return;
    }

    // Show coming soon dialog for now
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Split Tunneling'),
        content: const Text('This feature is coming soon!\n\nYou will be able to select which apps bypass the VPN.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _clearCache() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Cache'),
        content: const Text('This will remove all cached server data. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('server_cache');
              await prefs.remove('top_servers');
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Cache cleared successfully'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
