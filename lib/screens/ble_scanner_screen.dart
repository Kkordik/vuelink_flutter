import 'dart:async';
import 'dart:io'; // Add dart:io for Platform check
import 'dart:typed_data'; // Import needed for Uint8List
import 'package:flutter/material.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart'; // Add import
import '../services/ble_service.dart';
import '../services/vuelink_scanner_service.dart';
import '../services/vuelink_forwarding_service.dart'; // Import forwarding service
import '../data/message_types.dart'; // Import message types for formatting

// Singleton wrapper for ScannerService to manage initialization and disposal correctly
class _ScannerServiceSingleton {
  static final _ScannerServiceSingleton _singleton =
      _ScannerServiceSingleton._internal();
  // Services
  final BleService _bleService = BleService();
  final VuelinkForwardingService _forwardingService =
      VuelinkForwardingService();
  late VuelinkScannerService _scannerService;
  bool _isInitialized = false;

  // State
  bool _forwardingEnabled = true;

  factory _ScannerServiceSingleton() {
    return _singleton;
  }

  _ScannerServiceSingleton._internal();

  Future<void> _initialize() async {
    if (!_isInitialized) {
      await _bleService.initialize();
      await _forwardingService.initialize();
      // VuelinkScannerService constructor only takes optional bleService
      _scannerService = VuelinkScannerService(bleService: _bleService);

      await _scannerService.initialize();
      _forwardingEnabled = _scannerService.forwardingEnabled;
      _isInitialized = true;
    }
  }

  Future<void> ensureInitialized() async {
    if (!_isInitialized) {
      await _initialize();
    }
  }

  // Expose services
  VuelinkScannerService get scannerService => _scannerService;
  BleService get bleService => _bleService;
  VuelinkForwardingService get forwardingService =>
      _forwardingService; // Expose ForwardingService

  // Expose relevant state and methods
  bool get isScanning => _isInitialized ? _scannerService.isScanning : false;
  bool get forwardingEnabled => _forwardingEnabled;
  set forwardingEnabled(bool value) {
    if (_isInitialized) {
      _scannerService.forwardingEnabled = value;
      _forwardingEnabled = value;
    }
  }

  int get messageCount => _isInitialized ? _scannerService.messageCount : 0;

  Future<void> startScan() async {
    await ensureInitialized();
    await _scannerService.startScanning();
  }

  Future<void> stopScan() async {
    if (_isInitialized) {
      await _scannerService.stopScanning();
    }
  }

  Future<void> clearHistory() async {
    await ensureInitialized();
    await _forwardingService.clearHistory();
  }

  // No dispose needed for true singletons usually
  void cleanup() {
    // Optional: Add cleanup logic specific to screen disposal if needed
  }
}

class BleScannerScreen extends StatefulWidget {
  const BleScannerScreen({super.key});

  @override
  State<BleScannerScreen> createState() => _BleScannerScreenState();
}

class _BleScannerScreenState extends State<BleScannerScreen> {
  // Use the singleton service
  final _scannerInstance = _ScannerServiceSingleton();

  // UI state
  bool _isForwardingEnabled = true;
  String _statusMessage = 'Initializing...';
  List<VuelinkReceivedMessage> _receivedMessages = [];
  int _messageCount = 0;
  BluetoothLowEnergyState _currentState = BluetoothLowEnergyState.unknown;
  bool _permissionsGranted = false;

  // Subscriptions
  StreamSubscription? _stateSubscription;
  StreamSubscription? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _initializeScanner();
  }

  Future<void> _initializeScanner() async {
    // --- Request Permissions First ---
    final bool permissionsWereGranted = await _requestBlePermissions();

    setState(() {
      _permissionsGranted = permissionsWereGranted;
      if (!_permissionsGranted) {
        _statusMessage =
            'Bluetooth permissions denied. Please grant permissions in settings.';
        // Early return if permissions were denied
        return;
      } else {
        _statusMessage = 'Permissions granted. Initializing...';
      }
    });

    // Proceed only if permissions are granted
    if (!_permissionsGranted) {
      return;
    }

    await _scannerInstance.ensureInitialized();

    // ---> Load saved messages <---
    _loadSavedMessages();

    // Subscribe to BLE state changes
    _stateSubscription = _scannerInstance.bleService.peripheralStateStream
        .listen(_handleStateChange);

    // Subscribe to received messages
    _messageSubscription = _scannerInstance.scannerService.messageStream.listen(
      (message) {
        if (mounted) {
          setState(() {
            _receivedMessages.insert(0, message); // Add to top of list
            _messageCount = _scannerInstance.scannerService.messageCount;
          });
        }
      },
    );
  }

  /// Load saved messages from the forwarding service
  void _loadSavedMessages() {
    final savedMessageMaps =
        _scannerInstance.forwardingService.getSavedMessages();

    final loadedMessages =
        savedMessageMaps.map((map) {
          // Reconstruct VuelinkReceivedMessage from the saved map
          final timestampStr = map['receivedTimestamp'] as String?;
          final timestamp =
              timestampStr != null
                  ? DateTime.tryParse(timestampStr) ?? DateTime.now()
                  : DateTime.now();

          // Extract shouldForward if it was saved, otherwise default
          // Assuming shouldForward wasn't explicitly saved in the map, default to false for display
          final shouldForward = map['shouldForward'] as bool? ?? false;

          return VuelinkReceivedMessage(
            // Use placeholders for data not directly saved in the map
            deviceName: map['deviceName'] as String? ?? 'Saved Message',
            rssi: map['rssi'] as int? ?? -100, // Placeholder RSSI
            timestamp: timestamp,
            manufacturerId:
                map['manufacturerId'] as int? ?? 0, // Placeholder Manuf ID
            messageData: map, // The map itself is the core data
            rawData:
                map['rawData'] is List
                    ? Uint8List.fromList((map['rawData'] as List).cast<int>())
                    : Uint8List(
                      0,
                    ), // Placeholder Raw Data or reconstruct if saved
            shouldForward: shouldForward,
          );
        }).toList();

    if (mounted) {
      setState(() {
        _receivedMessages = loadedMessages;
        _messageCount = _receivedMessages.length;
        // Potentially update status message if needed
      });
    }
    debugPrint('Loaded ${_receivedMessages.length} messages into UI state.');
  }

  Future<bool> _requestBlePermissions() async {
    print("Requesting appropriate BLE permissions for platform...");
    bool permissionsGranted = false;

    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      print("Android SDK Version: $sdkInt");

      List<Permission> permissionsToRequest = [];
      bool checkBluetoothStatusSeparately = false;

      if (sdkInt >= 31) {
        // Android 12+
        print("Requesting Android 12+ BLE permissions...");
        permissionsToRequest.addAll([
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
        ]);
      } else {
        // Android 11 and below
        print("Requesting Android <= 11 BLE permissions (Location)...");
        permissionsToRequest.add(Permission.locationWhenInUse);
        // We also need to check the status of the basic Bluetooth permission implicitly
        checkBluetoothStatusSeparately = true;
      }

      PermissionStatus bluetoothStatus =
          PermissionStatus.denied; // Default status
      if (checkBluetoothStatusSeparately) {
        print("Checking status of implicit Bluetooth permission...");
        bluetoothStatus = await Permission.bluetooth.status;
        print("Implicit Bluetooth Permission Status: ${bluetoothStatus.name}");
      }

      if (permissionsToRequest.isNotEmpty) {
        Map<Permission, PermissionStatus> statuses =
            await permissionsToRequest.request();

        // Log statuses
        print("--- Permission Request Results ---");
        statuses.forEach((permission, status) {
          print("${permission.toString().split('.').last}: ${status.name}");
        });
        print("---------------------------------");

        // Check statuses
        if (sdkInt >= 31) {
          permissionsGranted =
              statuses[Permission.bluetoothScan]!.isGranted &&
              statuses[Permission.bluetoothAdvertise]!.isGranted &&
              statuses[Permission.bluetoothConnect]!.isGranted;
        } else {
          // On older Android, require Location granted AND basic Bluetooth to be available (not denied/restricted)
          bool locationGranted =
              statuses[Permission.locationWhenInUse]?.isGranted ?? false;
          bool bluetoothAvailable =
              bluetoothStatus.isGranted ||
              bluetoothStatus.isLimited; // isLimited might indicate BT is on
          print(
            "Old Android Check: Location Granted = $locationGranted, Bluetooth Available = $bluetoothAvailable",
          );
          permissionsGranted = locationGranted && bluetoothAvailable;
        }

        if (!permissionsGranted &&
            statuses.values.any((status) => status.isPermanentlyDenied)) {
          print(
            "Some required permissions permanently denied. Opening settings...",
          );
          await openAppSettings();
        } else if (!permissionsGranted) {
          print("Required permissions were not granted.");
        }
      } else if (checkBluetoothStatusSeparately) {
        // If only checking BT status (shouldn't happen with current logic, but for safety)
        permissionsGranted =
            bluetoothStatus.isGranted || bluetoothStatus.isLimited;
      } else {
        permissionsGranted = true; // Should not happen
      }
    } else if (Platform.isIOS) {
      // iOS handles permissions differently - often implicitly granted or requested on first use by the plugin
      // However, explicitly requesting can be good practice.
      print(
        "Requesting iOS BLE permissions (handled by Info.plist descriptions)...",
      );
      Map<Permission, PermissionStatus> statuses =
          await [
            Permission.bluetooth,
            Permission.locationWhenInUse,
          ].request(); // Request basic bluetooth and location

      print("--- Permission Request Results (iOS) ---");
      statuses.forEach((permission, status) {
        print("${permission.toString().split('.').last}: ${status.name}");
      });
      print("---------------------------------------");

      // On iOS, if the keys are in Info.plist, the OS handles prompting.
      // We primarily check if the user denied them.
      // Note: Permission.bluetooth status might be 'restricted' or 'denied'.
      // Actual BLE operations might still work depending on specific iOS nuances if Info.plist entries are correct.
      // A simple check: ensure neither critical permission is permanently denied.
      permissionsGranted =
          !(statuses[Permission.bluetooth]!.isPermanentlyDenied ||
              statuses[Permission.locationWhenInUse]!.isPermanentlyDenied ||
              statuses[Permission.bluetooth]!.isDenied ||
              statuses[Permission.locationWhenInUse]!.isDenied);

      if (!permissionsGranted &&
          statuses.values.any(
            (status) => status.isPermanentlyDenied || status.isDenied,
          )) {
        print(
          "Required iOS permissions were denied/permanently denied. Check Settings.",
        );
        if (statuses.values.any((status) => status.isPermanentlyDenied)) {
          await openAppSettings();
        }
      }
    }

    if (permissionsGranted) {
      print("Required permissions appear to be granted for this platform.");
    } else {
      print("Required permissions were NOT granted for this platform.");
    }
    return permissionsGranted;
  }

  void _handleStateChange(BluetoothLowEnergyState state) {
    if (mounted) {
      // Update internal state regardless of permissions
      _currentState = state;

      setState(() {
        // Only update UI message if permissions are granted
        if (!_permissionsGranted) {
          _statusMessage = 'Bluetooth permissions denied.';
          return;
        }

        // Update status message based on BLE state
        if (state == BluetoothLowEnergyState.poweredOn) {
          _statusMessage =
              _scannerInstance.isScanning
                  ? 'Scanning for messages...'
                  : 'Bluetooth LE Ready'; // Simplified
        } else if (state == BluetoothLowEnergyState.poweredOff) {
          _statusMessage = 'Bluetooth is off. Please turn it on.';
        } else {
          _statusMessage = 'Bluetooth state: ${state.name}'; // Keep state name
        }
      });
    }
  }

  Future<void> _toggleScanning() async {
    if (!_permissionsGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth permissions are required to scan.'),
        ),
      );
      return;
    }

    final currentScanState = _scannerInstance.isScanning;

    if (currentScanState) {
      await _scannerInstance.stopScan();
      setState(() {
        _statusMessage = 'Scan Stopped'; // Simplified
      });
    } else {
      await _scannerInstance.startScan();
      setState(() {
        _statusMessage =
            _scannerInstance.isScanning
                ? 'Scanning for messages...' // Consistent message
                : 'Failed to Start Scan'; // Simplified
      });
    }
  }

  void _toggleForwarding() {
    // Keep current logic, maybe simplify message slightly
    _scannerInstance.forwardingEnabled = !_isForwardingEnabled;
    setState(() {
      _isForwardingEnabled = !_isForwardingEnabled;
      _scannerInstance.scannerService.forwardingEnabled = _isForwardingEnabled;
      _statusMessage =
          _isForwardingEnabled ? 'Forwarding Enabled' : 'Forwarding Disabled';
    });
  }

  void _clearMessages() {
    setState(() {
      _receivedMessages.clear();
      _statusMessage = 'Message list cleared';
    });
  }

  Future<void> _clearHistory() async {
    await _scannerInstance.scannerService.clearMessageHistory();
    setState(() {
      _statusMessage = 'Message history cleared';
    });
  }

  String _formatTimestamp(DateTime timestamp) {
    // Keep this format - it's common and useful
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
  }

  // Combine icon and title logic
  Map<String, dynamic> _getDisplayInfoForMessageType(dynamic messageTypeEnum) {
    // Use the enum directly for comparison
    if (messageTypeEnum == MessageType.generalBasic) {
      return {'icon': Icons.info_outline, 'title': 'Basic Info'};
    } else if (messageTypeEnum == MessageType.generalText) {
      return {'icon': Icons.text_snippet_outlined, 'title': 'Text Message'};
    } else if (messageTypeEnum == MessageType.flightUpdate) {
      return {'icon': Icons.flight, 'title': 'Flight Status'};
    } else if (messageTypeEnum == MessageType.flightUpdateGeneral) {
      return {'icon': Icons.airplane_ticket_outlined, 'title': 'Flight Info'};
    } else if (messageTypeEnum == MessageType.system) {
      return {'icon': Icons.settings_remote, 'title': 'System Message'};
    } else if (messageTypeEnum == MessageType.emergency) {
      return {
        'icon': Icons.warning,
        'title': 'Emergency Alert',
        'color': Colors.red,
      };
    } else {
      return {'icon': Icons.question_mark, 'title': 'Unknown Message'};
    }
  }

  String _truncateText(String text, int maxLength) {
    // Keep this helper
    if (text.length <= maxLength) return text;
    // Improve truncation slightly
    return '${text.substring(0, maxLength)}...';
  }

  String _formatPriority(dynamic priorityEnum) {
    if (priorityEnum == null) return 'Normal Priority';
    switch (priorityEnum) {
      case Priority.low:
        return 'Low Priority';
      case Priority.medium:
        return 'Medium Priority';
      case Priority.high:
        return 'High Priority';
      case Priority.urgent:
        return 'Urgent Priority';
      case Priority.emergency:
        return 'Emergency Priority';
      case Priority.system:
        return 'System Priority';
      case Priority.test:
        return 'Test Priority';
      default:
        return 'Unknown Priority';
    }
  }

  Widget _buildMessageCard(VuelinkReceivedMessage message) {
    // Extract info
    final messageType = message.messageData['messageType'];
    final displayInfo = _getDisplayInfoForMessageType(messageType);
    final String title = displayInfo['title'] as String;
    final IconData iconData = displayInfo['icon'] as IconData;
    final Color? iconColor = displayInfo['color'] as Color?;

    final String formattedMessage = VuelinkScannerService.formatMessage(
      message,
    );
    // Simplify preview slightly - focus on key content if possible
    String previewText = 'Tap to expand details';
    if (message.messageData.containsKey('textContent')) {
      previewText = message.messageData['textContent'] as String;
    } else if (message.messageData.containsKey('flightId')) {
      previewText = 'Flight ${message.messageData['flightId']} update';
    } else if (formattedMessage.contains('Raw Content')) {
      previewText = 'Basic message data - Tap to view';
    }
    previewText = _truncateText(previewText, 80);

    // Determine priority color - keep existing logic
    Color priorityColor = Colors.blue; // Default to low/medium visual
    final priority = message.messageData['priority'];
    if (priority != null) {
      if (priority == Priority.low)
        priorityColor = Colors.blue;
      else if (priority == Priority.medium)
        priorityColor = Colors.green;
      else if (priority == Priority.high)
        priorityColor = Colors.orange;
      else if (priority == Priority.urgent || priority == Priority.emergency)
        priorityColor = Colors.red;
      else if (priority == Priority.system)
        priorityColor = Colors.purple;
      else if (priority == Priority.test)
        priorityColor = Colors.grey;
    }

    // Forwarding badge - keep existing logic
    final forwardingIcon =
        message.shouldForward
            ? Icon(Icons.repeat, color: Colors.green[400], size: 18)
            : Icon(Icons.block, color: Colors.grey[400], size: 18);
    final forwardingText =
        message.shouldForward ? 'Will Forward' : 'Local Only';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: Icon(iconData, color: iconColor), // Use icon from helper
        title: Row(
          children: [
            Expanded(
              // Use user-friendly title
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: priorityColor.withAlpha(51),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  forwardingIcon,
                  const SizedBox(width: 4),
                  Text(
                    forwardingText,
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          message.shouldForward
                              ? Colors.green[700]
                              : Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        subtitle: Text(
          // Keep technical details here but use simplified preview
          'From: ${message.deviceName} • RSSI: ${message.rssi} dBm • ${_formatTimestamp(message.timestamp)}\n$previewText',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Show full formatted message
                Text(
                  formattedMessage,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 12),
                // Row with priority indicator and repeat flag
                Wrap(
                  // Use Wrap for better spacing on small screens
                  spacing: 8.0,
                  runSpacing: 4.0,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: priorityColor.withAlpha(51),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      // Use formatted priority
                      child: Text(
                        _formatPriority(priority),
                        style: TextStyle(color: priorityColor),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blueGrey.withAlpha(26),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            message.messageData['repeatFlag'] == true
                                ? Icons.repeat_on_outlined
                                : Icons.repeat_one_outlined,
                            size: 14,
                            color:
                                message.messageData['repeatFlag'] == true
                                    ? Colors.blueGrey
                                    : Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          // User-friendly repeat text
                          Text(
                            message.messageData['repeatFlag'] == true
                                ? 'Will Repeat'
                                : 'Single Send',
                            style: TextStyle(
                              color:
                                  message.messageData['repeatFlag'] == true
                                      ? Colors.blueGrey
                                      : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vuelink Scanner'),
        actions: [
          IconButton(
            // Renamed tooltip
            icon: const Icon(Icons.delete_outline),
            onPressed: _clearMessages, // Clears screen list
            tooltip: 'Clear Screen',
          ),
          IconButton(
            // Renamed tooltip
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearHistory, // Clears persistent storage
            tooltip: 'Clear Saved History',
          ),
        ],
      ),
      body: Column(
        children: [
          // Status card
          Card(
            margin: const EdgeInsets.all(8),
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  // Status Indicator Dot
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color:
                          _scannerInstance.isScanning
                              ? Colors.green
                              : Colors.grey,
                      shape: BoxShape.circle, // Changed to circle
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Status Text
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _scannerInstance.isScanning
                              ? 'Scanning Active'
                              : 'Scanner Idle',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _statusMessage, // Displays initializing, permission, state messages
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        // Show BLE State clearly
                        Row(
                          children: [
                            Icon(
                              _currentState == BluetoothLowEnergyState.poweredOn
                                  ? Icons.bluetooth_connected
                                  : Icons.bluetooth_disabled,
                              size: 16,
                              color:
                                  _currentState ==
                                          BluetoothLowEnergyState.poweredOn
                                      ? Colors.blue
                                      : Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'BT State: ${_currentState.name}',
                              style: TextStyle(
                                color:
                                    _currentState ==
                                            BluetoothLowEnergyState.poweredOn
                                        ? Colors.blue
                                        : Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Action Buttons
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _toggleScanning,
                        icon: Icon(
                          _scannerInstance.isScanning
                              ? Icons.stop
                              : Icons.play_arrow,
                        ),
                        label: Text(
                          _scannerInstance.isScanning ? 'Stop' : 'Start',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              _scannerInstance.isScanning
                                  ? Colors.redAccent
                                  : Colors.blueAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ), // Adjust padding
                          textStyle: const TextStyle(
                            fontSize: 14,
                          ), // Adjust text size
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _toggleForwarding,
                        icon: Icon(
                          _isForwardingEnabled
                              ? Icons.repeat_on_rounded
                              : Icons.block,
                          color:
                              _isForwardingEnabled ? Colors.green : Colors.grey,
                          size: 18,
                        ),
                        label: Text(
                          _isForwardingEnabled
                              ? 'Forwarding: ON'
                              : 'Forwarding: OFF',
                          style: TextStyle(
                            color:
                                _isForwardingEnabled
                                    ? Colors.green
                                    : Colors.grey,
                            fontSize: 12, // Make smaller
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ), // Adjust padding
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Message count
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), // Adjust padding
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end, // Align to right
              children: [
                Text(
                  '$_messageCount messages',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
          // Messages list
          Expanded(
            child:
                _receivedMessages.isEmpty
                    ? const Center(child: Text('No messages received yet'))
                    : ListView.builder(
                      itemCount: _receivedMessages.length,
                      itemBuilder: (context, index) {
                        return _buildMessageCard(_receivedMessages[index]);
                      },
                    ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Cancel our UI-specific subscriptions
    _stateSubscription?.cancel();
    _messageSubscription?.cancel();

    // Don't stop scanning or dispose the service, just cleanup our instance
    _scannerInstance.cleanup();

    super.dispose();
  }
}
