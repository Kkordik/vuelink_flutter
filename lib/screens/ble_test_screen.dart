import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../data/message_types.dart';
import '../services/vuelink_message_service.dart';
import '../utils/constants.dart';
import '../data/payload_builder.dart';

class BleTestScreen extends StatefulWidget {
  const BleTestScreen({super.key});

  @override
  State<BleTestScreen> createState() => _BleTestScreenState();
}

class _BleTestScreenState extends State<BleTestScreen> {
  final BleService _bleService = BleService();
  bool _isSupported = false;
  bool _isAdvertising = false;
  String _statusMessage = 'Initializing...';
  BluetoothLowEnergyState _currentState = BluetoothLowEnergyState.unknown;

  // Message properties
  MessageType _messageType = MessageType.generalBasic;
  Priority _priority = Priority.medium;
  bool _repeatFlag = false;
  String _content = 'Test message';
  String _flightId = 'FL1234';
  final Duration _autoStopDuration = const Duration(milliseconds: 250);
  bool _enableAutoStop = true;

  // Controllers for text fields
  late TextEditingController _contentController;
  late TextEditingController _flightIdController;

  // Selected values for dropdowns
  String? _selectedMessageType;
  String? _selectedPriority;
  FlightUpdateType _flightUpdateType = FlightUpdateType.general;

  StreamSubscription? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _initializeBle();

    // Initialize controllers with default values
    _contentController = TextEditingController(text: _content);
    _flightIdController = TextEditingController(text: _flightId);

    // Set initial dropdown values
    _selectedMessageType = _messageType.toString().split('.').last;
    _selectedPriority = _priority.toString().split('.').last;
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _bleService.dispose();
    _contentController.dispose();
    _flightIdController.dispose();
    super.dispose();
  }

  Future<void> _initializeBle() async {
    setState(() {
      _statusMessage = 'Requesting permissions and initializing BLE...';
    });

    try {
      _stateSubscription = _bleService.peripheralStateStream.listen(
        _handleStateChange,
      );

      await _bleService.initialize();
    } catch (e) {
      setState(() {
        _statusMessage = 'Error checking BLE support: $e';
      });
    }
  }

  void _handleStateChange(BluetoothLowEnergyState state) async {
    bool isReady = state == BluetoothLowEnergyState.poweredOn;
    String message;
    switch (state) {
      case BluetoothLowEnergyState.poweredOff:
        message = 'Bluetooth is powered off. Please turn it on.';
        break;
      case BluetoothLowEnergyState.unsupported:
        message = 'BLE peripheral mode is NOT supported on this device';
        break;
      default:
        message = 'BLE state: ${state.name}';
    }
    if (mounted) {
      final advertising = await _bleService.isAdvertising();
      setState(() {
        _currentState = state;
        _isSupported = isReady;
        _statusMessage = message;
        _isAdvertising = advertising && isReady;
      });
    }
  }

  Future<void> _toggleAdvertising() async {
    if (!await _bleService.isPeripheralReady()) {
      setState(() {
        _statusMessage =
            'Cannot advertise. BLE not ready (State: ${_currentState.name}). Make sure Location Services are enabled.';
      });
      return;
    }

    try {
      if (await _bleService.isAdvertising()) {
        await VuelinkMessageService.stopVuelinkAdvertising(_bleService);
        setState(() {
          _isAdvertising = false;
          _statusMessage = 'Advertising stopped';
        });
      } else {
        // Get values from controllers
        _content = _contentController.text;
        _flightId = _flightIdController.text;

        // Create appropriate message data based on type
        MessageData messageData;

        switch (_messageType) {
          case MessageType.generalBasic:
            messageData = GeneralBasicMessageData(
              content: _content,
              repeatFlag: _repeatFlag,
              priority: _priority,
            );
            break;
          case MessageType.generalText:
            messageData = GeneralTextMessageData(
              textContent: _content,
              repeatFlag: _repeatFlag,
              priority: _priority,
            );
            break;
          case MessageType.flightUpdate:
            messageData = FlightUpdateMessageData(
              flightId: _flightId,
              updateType: _flightUpdateType,
              repeatFlag: _repeatFlag,
              priority: _priority,
            );
            break;
          case MessageType.flightUpdateGeneral:
            messageData = FlightUpdateGeneralMessageData(
              flightId: _flightId,
              textContent: _content,
              repeatFlag: _repeatFlag,
              priority: _priority,
            );
            break;
          default:
            throw UnimplementedError('Message type not supported');
        }

        // IMPORTANT: We don't validate or split the message here anymore
        // The VuelinkMessageService will handle the validation and splitting

        // Use the VuelinkMessageService to start advertising - this internally handles chunking
        final success = await VuelinkMessageService.startVuelinkAdvertising(
          bleService: _bleService,
          messageData:
              messageData, // Pass the original message data - service will split it
          autoStopDuration: _enableAutoStop ? _autoStopDuration : null,
          onAutoStopped: () {
            // Check if we're mounted before updating UI
            if (mounted) {
              setState(() {
                _isAdvertising = false;
                _statusMessage = 'Advertising completed';
              });
            }
          },
        );

        // Get message part count for status message
        final messageParts = PayloadBuilder.splitIntoChunks(messageData);
        final isMultiPart = messageParts.length > 1;

        setState(() {
          _isAdvertising = success;
          _statusMessage =
              success
                  ? 'Vuelink packet advertising started${isMultiPart ? " (${messageParts.length} parts)" : ""}${_enableAutoStop ? " (will auto-stop in ${_autoStopDuration.inSeconds}s)" : ""}'
                  : 'Failed to start Vuelink packet advertising';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error toggling advertising: $e';
      });
    }
  }

  // Helper method to create message type dropdown items
  List<DropdownMenuItem<String>> _buildMessageTypeItems() {
    return MessageType.values.map((type) {
      final name = type.toString().split('.').last;
      return DropdownMenuItem<String>(value: name, child: Text(name));
    }).toList();
  }

  // Helper method to create priority dropdown items
  List<DropdownMenuItem<String>> _buildPriorityItems() {
    return Priority.values.map((priority) {
      final name = priority.toString().split('.').last;
      return DropdownMenuItem<String>(value: name, child: Text(name));
    }).toList();
  }

  // Helper method to create flight update type dropdown items
  List<DropdownMenuItem<String>> _buildFlightUpdateTypeItems() {
    return FlightUpdateType.values.map((type) {
      final name = type.toString().split('.').last;
      return DropdownMenuItem<String>(value: name, child: Text(name));
    }).toList();
  }

  // Show appropriate fields based on message type
  Widget _buildMessageFields() {
    final List<Widget> fields = [
      // Common fields for all message types
      DropdownButtonFormField<String>(
        decoration: const InputDecoration(
          labelText: 'Message Type',
          border: OutlineInputBorder(),
        ),
        value: _selectedMessageType,
        items: _buildMessageTypeItems(),
        onChanged: (String? value) {
          if (value != null) {
            setState(() {
              _selectedMessageType = value;
              _messageType = MessageType.values.firstWhere(
                (type) => type.toString().split('.').last == value,
              );
            });
          }
        },
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        decoration: const InputDecoration(
          labelText: 'Priority',
          border: OutlineInputBorder(),
        ),
        value: _selectedPriority,
        items: _buildPriorityItems(),
        onChanged: (String? value) {
          if (value != null) {
            setState(() {
              _selectedPriority = value;
              _priority = Priority.values.firstWhere(
                (p) => p.toString().split('.').last == value,
              );
            });
          }
        },
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        title: const Text('Repeat/Forward Flag'),
        subtitle: const Text('Allow message to be repeated by other devices'),
        value: _repeatFlag,
        onChanged: (bool value) {
          setState(() {
            _repeatFlag = value;
          });
        },
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        title: const Text('Auto-Stop Advertising'),
        subtitle: Text('Stop after ${_autoStopDuration.inSeconds} seconds'),
        value: _enableAutoStop,
        onChanged: (bool value) {
          setState(() {
            _enableAutoStop = value;
          });
        },
      ),
      const SizedBox(height: 8),
    ];

    // Add message-type specific fields
    if (_messageType == MessageType.flightUpdate ||
        _messageType == MessageType.flightUpdateGeneral) {
      // Flight ID field for flight-related messages
      fields.add(
        TextField(
          controller: _flightIdController,
          decoration: const InputDecoration(
            labelText: 'Flight ID',
            helperText: 'Enter flight identifier (e.g., FL123)',
            border: OutlineInputBorder(),
          ),
        ),
      );
      fields.add(const SizedBox(height: 8));

      // Flight update type for flight update messages
      if (_messageType == MessageType.flightUpdate) {
        fields.add(
          DropdownButtonFormField<String>(
            decoration: const InputDecoration(
              labelText: 'Update Type',
              border: OutlineInputBorder(),
            ),
            value: _flightUpdateType.toString().split('.').last,
            items: _buildFlightUpdateTypeItems(),
            onChanged: (String? value) {
              if (value != null) {
                setState(() {
                  _flightUpdateType = FlightUpdateType.values.firstWhere(
                    (type) => type.toString().split('.').last == value,
                  );
                });
              }
            },
          ),
        );
        fields.add(const SizedBox(height: 8));
      }
    }

    // Content field for text-based messages
    if (_messageType != MessageType.flightUpdate) {
      fields.add(
        TextField(
          controller: _contentController,
          decoration: const InputDecoration(
            labelText: 'Message Content',
            helperText: 'Enter content to be transmitted',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
      );
      fields.add(const SizedBox(height: 8));
    }

    return Column(children: fields);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Peripheral Test')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('BLE Peripheral Support:'),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _isSupported ? Colors.green : Colors.red,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _isSupported ? 'SUPPORTED' : 'NOT SUPPORTED',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Currently Advertising:'),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _isAdvertising ? Colors.green : Colors.red,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _isAdvertising ? 'YES' : 'NO',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(_statusMessage),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      'Vuelink Packet Settings',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),

                    // Dynamic message fields based on message type
                    _buildMessageFields(),

                    // Packet info
                    Text(
                      'Total packet size: ${PacketFields.minTotalSize} bytes + content',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      'Manufacturer ID: 0x${VUELINK_MANUFACTURER_ID.toRadixString(16).toUpperCase()}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Note: Enable Location Services in Android settings for BLE operation',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Colors.blue,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isSupported ? _toggleAdvertising : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                _isAdvertising ? 'STOP ADVERTISING' : 'START ADVERTISING',
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                setState(() {
                  _statusMessage = 'Requesting permissions...';
                });
                bool granted = await _bleService.requestPermissions();
                setState(() {
                  _statusMessage =
                      granted
                          ? 'Permissions granted. State: ${_currentState.name}'
                          : 'Permissions denied. State: ${_currentState.name}';
                });
              },
              child: const Text('REQUEST PERMISSIONS'),
            ),
          ],
        ),
      ),
    );
  }
}
