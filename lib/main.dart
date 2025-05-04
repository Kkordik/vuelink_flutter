import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_links/app_links.dart';
import 'screens/ble_test_screen.dart';
import 'screens/ble_scanner_screen.dart';
import 'services/vuelink_forwarding_service.dart'; // Import forwarding service
import 'utils/deep_link_utils.dart'; // Import deep link utils
import 'services/vuelink_scanner_service.dart'; // For VuelinkReceivedMessage

void main() {
  WidgetsFlutterBinding.ensureInitialized(); // Ensure bindings are initialized
  runApp(const MainApp());
}

// Use a GlobalKey for navigation without BuildContext
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VueLink Flutter',
      navigatorKey: navigatorKey, // Assign the key
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      // Define routes if you want named navigation (optional but good practice)
      routes: {
        '/scanner': (context) => const BleScannerScreen(),
        '/advertiser': (context) => const BleTestScreen(),
        // Add other routes as needed
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  final VuelinkForwardingService _forwardingService =
      VuelinkForwardingService();

  @override
  void initState() {
    super.initState();
    _initAppLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initAppLinks() async {
    _appLinks = AppLinks();

    await _forwardingService.initialize();

    _linkSubscription = _appLinks.uriLinkStream.listen(
      (Uri uri) {
        developer.log('onAppLink: $uri');
        _handleDeepLink(uri);
      },
      onError: (err) {
        developer.log('Error listening to app link stream: $err');
      },
    );
  }

  void _handleDeepLink(Uri uri) {
    developer.log('Handling deep link: $uri');

    if (uri.scheme == 'vuelink' &&
        uri.host == 'app' &&
        uri.pathSegments.isNotEmpty) {
      final String encodedData = uri.pathSegments.first;
      developer.log('Extracted encoded data: $encodedData');

      final List<VuelinkReceivedMessage>? decodedMessages =
          decodeMessagesFromDeepLink(encodedData);

      if (decodedMessages != null && decodedMessages.isNotEmpty) {
        developer.log(
          'Successfully decoded ${decodedMessages.length} messages.',
        );

        _forwardingService.addMessagesFromDeepLink(decodedMessages).then((
          count,
        ) {
          developer.log(
            'Finished adding $count new messages from deep link to storage.',
          );
          navigatorKey.currentState?.pushReplacementNamed('/scanner');
        });
      } else {
        developer.log(
          'Failed to decode messages or no messages found in link.',
        );
        ScaffoldMessenger.of(navigatorKey.currentContext!).showSnackBar(
          const SnackBar(content: Text('Error processing Vuelink data.')),
        );
        navigatorKey.currentState?.pushNamed('/scanner');
      }
    } else {
      developer.log('Ignoring non-matching deep link format.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VueLink Flutter'), centerTitle: true),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'VueLink BLE Demo',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              _buildNavigationButton(
                context,
                'BLE Advertiser',
                'Create and broadcast BLE advertisements',
                Icons.bluetooth_audio,
                () => Navigator.pushNamed(context, '/advertiser'),
              ),
              const SizedBox(height: 16),
              _buildNavigationButton(
                context,
                'BLE Scanner',
                'Scan and receive BLE advertisements',
                Icons.bluetooth_searching,
                () => Navigator.pushNamed(context, '/scanner'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationButton(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onPressed,
  ) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(icon, size: 36, color: Theme.of(context).primaryColor),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Theme.of(context).primaryColor),
          ],
        ),
      ),
    );
  }
}
