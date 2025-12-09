import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScanpakHomeScreen extends StatefulWidget {
  const ScanpakHomeScreen({super.key});

  @override
  State<ScanpakHomeScreen> createState() => _ScanpakHomeScreenState();
}

class _ScanpakHomeScreenState extends State<ScanpakHomeScreen> {
  String? _userName;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _userName = prefs.getString('scanpak_user_name'));
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('scanpak_token');
    await prefs.remove('scanpak_user_name');
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('СканПак'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти',
            onPressed: _logout,
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_scanner, size: 96, color: Colors.blueGrey),
            const SizedBox(height: 12),
            Text(
              _userName == null ? 'Добро пожаловать в СканПак' : 'Привет, $_userName!',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24.0),
              child: Text(
                'Это стартовый экран для отдельного функционала СканПак. Здесь можно развивать собственные экраны и логику независимо от основного приложения.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
