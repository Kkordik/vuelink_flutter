import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../utils/constants.dart';
import '../data/message_types.dart';
import 'ble_service.dart';
import 'vuelink_message_service.dart';
import 'vuelink_forwarding_service.dart';

/// Service for scanning and handling Vuelink BLE messages
class VuelinkScannerService {
  final _log = Logger('VuelinkScannerService');
  final BleService _bleService;
  late VuelinkForwardingService _forwardingService;

  /// Controller for received Vuelink messages
  final StreamController<VuelinkReceivedMessage> _messageController =
      StreamController<VuelinkReceivedMessage>.broadcast();

  /// Stream of received messages
  Stream<VuelinkReceivedMessage> get messageStream => _messageController.stream;

  /// Number of messages received
  int _messageCount = 0;
  int get messageCount => _messageCount;

  /// Flag if scanning is active
  bool get isScanning => _bleService.isScanning();

  /// Flag if forwarding is enabled
  bool _forwardingEnabled = true;
  bool get forwardingEnabled => _forwardingEnabled;
  set forwardingEnabled(bool value) => _forwardingEnabled = value;

  /// Subscription for advertisements
  StreamSubscription? _advertisementSubscription;

  /// Cache for storing parts of multi-part messages
  final Map<String, Map<int, VuelinkReceivedMessage>> _messagePartsCache = {};

  /// Timer for cleaning up stale message parts
  Timer? _cleanupTimer;

  /// Timeout for message parts (if all parts aren't received in this time, the partial message is discarded)
  static const Duration _messagePartTimeout = Duration(minutes: 1);

  /// Creates a scanner service with the given [bleService] or creates a new one if not provided
  VuelinkScannerService({BleService? bleService})
    : _bleService = bleService ?? BleService() {
    // Create the forwarding service
    _forwardingService = VuelinkForwardingService();

    // Start a periodic timer to clean up stale message parts
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _cleanupStaleMessageParts(),
    );
  }

  /// Initialize the service
  Future<bool> initialize() async {
    // Initialize the forwarding service
    await _forwardingService.initialize();

    // Initialize the BLE service
    return await _bleService.initialize();
  }

  /// Start scanning for Vuelink messages
  Future<bool> startScanning() async {
    if (_advertisementSubscription != null) {
      await stopScanning();
    }

    // We'll listen manually for advertisements
    bool started = await _bleService.startScanning();
    if (started) {
      _listenForAdvertisements();
      return true;
    }
    return false;
  }

  /// Stop scanning for Vuelink messages
  Future<bool> stopScanning() async {
    _advertisementSubscription?.cancel();
    _advertisementSubscription = null;
    return await _bleService.stopScanning();
  }

  /// Manually handle BLE advertisements to filter for Vuelink messages
  void _listenForAdvertisements() {
    _advertisementSubscription = _bleService.advertisementStream.listen(
      (advertisement) {
        _processAdvertisement(advertisement);
      },
      onError: (error) {
        _log.severe('Error receiving advertisement: $error');
      },
    );
  }

  /// Process received advertisement data for Vuelink messages
  void _processAdvertisement(Advertisement advertisement) {
    // Check manufacturer specific data for Vuelink manufacturer ID
    for (var manufData in advertisement.manufacturerSpecificData) {
      if (manufData.id == VUELINK_MANUFACTURER_ID) {
        final messageData = VuelinkMessageService.parseVuelinkPayload(
          manufData.data,
          manufData.id,
        );

        if (messageData != null) {
          _messageCount++;

          // Check if the message should be processed (saved/forwarded) based on duplication/repeat rules
          final bool shouldProcess = _forwardingService.shouldProcessMessage(
            messageData,
          );

          if (shouldProcess) {
            // Create a received message object
            final message = VuelinkReceivedMessage(
              deviceName: advertisement.name ?? 'Unknown Device',
              rssi: -70, // Default RSSI
              timestamp: DateTime.now(),
              manufacturerId: manufData.id,
              messageData: messageData,
              rawData: manufData.data,
              // Determine forwarding based on message properties *after* process check passes
              shouldForward: _shouldThisMessageBeForwarded(messageData),
            );

            // Check if this is part of a multi-part message
            final totalParts = messageData['totalParts'] as int;
            if (totalParts > 1) {
              // Store the initial forwarding decision for the first part
              if (messageData['partNumber'] == 1) {
                message.shouldForward = _shouldThisMessageBeForwarded(
                  messageData,
                );
              }
              _handleMultiPartMessage(message);
            } else {
              // For single-part messages, record in history and send to listeners
              _forwardingService.recordMessage(messageData);
              _messageController.add(message);

              // If this message should be forwarded, do so
              if (message.shouldForward) {
                // Check the property set on the object
                _forwardMessage(message);
              }
            }
          } else {
            // Message was filtered out by shouldProcessMessage (duplicate, etc.)
            // Optionally log this
            _log.fine(
              'Filtered out received message due to duplication rules.',
            );
          }
        }
      }
    }
  }

  /// Determines if a specific message (that has already passed shouldProcessMessage check)
  /// should be actively forwarded.
  bool _shouldThisMessageBeForwarded(Map<String, dynamic> messageData) {
    if (!_forwardingEnabled) return false;

    // Check priority and repeat flag for forwarding
    final priority = messageData['priority'] as Priority?;
    final repeatFlag = messageData['repeatFlag'] == true;

    return repeatFlag || // Forward if repeat flag is set
        priority == Priority.emergency || // Forward if emergency
        priority == Priority.urgent; // Forward if urgent
  }

  /// Forward a message by broadcasting it
  void _forwardMessage(VuelinkReceivedMessage message) {
    // Clone the message data
    final messageData = Map<String, dynamic>.from(message.messageData);

    // Ensure the repeat flag is set
    messageData['repeatFlag'] = true;

    // Forward the message by broadcasting it
    VuelinkMessageService.startVuelinkAdvertising(
      bleService: _bleService,
      messageData: MessageData.fromMap(messageData),
      autoStopDuration: const Duration(seconds: 3),
    );

    _log.fine('Forwarded message: ${messageData['messageType']}');
  }

  /// Handle a part of a multi-part message
  void _handleMultiPartMessage(VuelinkReceivedMessage messagePart) {
    // Extract info about the message part
    final messageType = messagePart.messageData['messageType'];
    final partNumber = messagePart.messageData['partNumber'] as int;
    final totalParts = messagePart.messageData['totalParts'] as int;

    // Create a unique key for this message series
    // We'll use device name + message type + timestamp to group related parts
    final messageKey =
        '${messagePart.deviceName}_${messageType.toString()}_${messagePart.timestamp.millisecondsSinceEpoch ~/ 5000}';

    // Add to cache
    _messagePartsCache.putIfAbsent(messageKey, () => {});
    _messagePartsCache[messageKey]![partNumber] = messagePart;

    _log.info('Received part $partNumber/$totalParts for message $messageKey');

    // Retrieve the forwarding decision from the first part if it exists
    // Note: The shouldForward on the incoming messagePart for part > 1 isn't reliable here
    // as the initial check happened before we knew it was multi-part.
    // We rely on the stored first part's decision.
    bool firstPartShouldForward = _forwardingEnabled; // Default assumption
    if (_messagePartsCache[messageKey]!.containsKey(1)) {
      // Use the shouldForward value we stored on the first part object itself
      firstPartShouldForward =
          _messagePartsCache[messageKey]![1]!.shouldForward;
    } else if (partNumber == 1) {
      // This *is* the first part, its shouldForward value was set correctly earlier
      firstPartShouldForward = messagePart.shouldForward;
    }
    // Ensure all parts in the cache reflect the first part's forwarding decision
    messagePart.shouldForward = firstPartShouldForward;

    // Check if we have all parts
    if (_messagePartsCache[messageKey]!.length == totalParts) {
      // We have all parts - combine and process
      final combinedMessage = _combineMessageParts(messageKey);
      if (combinedMessage != null) {
        // Note: The shouldProcessMessage check was already done on the *first* part.
        // We assume if the first part passed, the whole message should be processed.
        // If finer control is needed, the check could be repeated here on combinedData.

        // Set the final forwarding decision based on the combined data and first part's flag
        combinedMessage.shouldForward =
            firstPartShouldForward; // Use the stored decision

        // Record combined message in message history
        _forwardingService.recordMessage(combinedMessage.messageData);

        // Send combined message to listeners
        _messageController.add(combinedMessage);

        // Forward if enabled and the combined message should be forwarded
        if (combinedMessage.shouldForward) {
          // Check the final property
          _forwardMessage(combinedMessage);
        }
      }
      // Always remove from cache after attempting to process
      _messagePartsCache.remove(messageKey);
    }
  }

  /// Combine parts of a multi-part message
  VuelinkReceivedMessage? _combineMessageParts(String messageKey) {
    if (!_messagePartsCache.containsKey(messageKey)) {
      return null;
    }

    final parts = _messagePartsCache[messageKey]!;
    if (parts.isEmpty) {
      return null;
    }

    // Sort the parts by part number
    final sortedPartNumbers = parts.keys.toList()..sort();
    final firstPart = parts[sortedPartNumbers.first]!;

    // Verify we have all parts from 1 to total
    final totalParts = firstPart.messageData['totalParts'] as int;
    for (int i = 1; i <= totalParts; i++) {
      if (!parts.containsKey(i)) {
        _log.warning('Missing part $i of $totalParts for message $messageKey');
        return null;
      }
    }

    // Get message type to determine how to combine
    final messageType = firstPart.messageData['messageType'];
    final deviceName = firstPart.deviceName;
    final timestamp = firstPart.timestamp;
    final manufacturerId = firstPart.manufacturerId;

    // Clone the message data from the first part as a base
    final combinedData = Map<String, dynamic>.from(firstPart.messageData);

    // Combine the content based on message type
    switch (messageType) {
      case MessageType.generalText:
        final StringBuilder contentBuilder = StringBuilder();

        // Concatenate text content from all parts in order
        for (int i = 1; i <= totalParts; i++) {
          final part = parts[i]!;
          final textContent = part.messageData['textContent'] as String;
          contentBuilder.append(textContent);
        }

        combinedData['textContent'] = contentBuilder.toString();
        combinedData['isReassembled'] = true;
        break;

      case MessageType.flightUpdateGeneral:
        // For flight updates, we take the flight ID from the first part
        // and concatenate the text content
        final flightId = firstPart.messageData['flightId'] as String;
        final StringBuilder contentBuilder = StringBuilder();

        // Concatenate text content from all parts in order
        for (int i = 1; i <= totalParts; i++) {
          final part = parts[i]!;
          final textContent = part.messageData['textContent'] as String;
          contentBuilder.append(textContent);
        }

        combinedData['flightId'] = flightId;
        combinedData['textContent'] = contentBuilder.toString();
        combinedData['isReassembled'] = true;
        break;

      default:
        // For other types, just return the first part
        return firstPart;
    }

    // Combine the raw data for completeness
    final List<int> rawDataList = [];
    for (int i = 1; i <= totalParts; i++) {
      rawDataList.addAll(parts[i]!.rawData);
    }
    final combinedRawData = Uint8List.fromList(rawDataList);

    // Create the combined message
    return VuelinkReceivedMessage(
      deviceName: deviceName,
      rssi: -70, // Default
      timestamp: timestamp,
      manufacturerId: manufacturerId,
      messageData: combinedData,
      rawData: combinedRawData,
      shouldForward: firstPart.shouldForward,
    );
  }

  /// Clean up stale message parts that haven't been completed
  void _cleanupStaleMessageParts() {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _messagePartsCache.forEach((key, parts) {
      // Get the oldest part's timestamp
      DateTime? oldestTimestamp;

      for (var part in parts.values) {
        if (oldestTimestamp == null ||
            part.timestamp.isBefore(oldestTimestamp)) {
          oldestTimestamp = part.timestamp;
        }
      }

      // If the oldest part is older than the timeout, remove the whole message
      if (oldestTimestamp != null &&
          now.difference(oldestTimestamp) > _messagePartTimeout) {
        keysToRemove.add(key);
      }
    });

    // Remove stale messages
    for (final key in keysToRemove) {
      _log.info('Removing stale message parts for $key');
      _messagePartsCache.remove(key);
    }
  }

  /// Format a received message as a human-readable string
  static String formatMessage(VuelinkReceivedMessage message) {
    final messageInfo = message.messageData;
    final isReassembled = messageInfo['isReassembled'] == true;

    String formattedMessage = VuelinkMessageService.formatPayloadInfo(
      messageInfo,
    );

    if (isReassembled) {
      formattedMessage = '(REASSEMBLED MULTI-PART MESSAGE)\n$formattedMessage';
    }

    return formattedMessage;
  }

  /// Clear message history
  Future<void> clearMessageHistory() async {
    await _forwardingService.clearHistory();
  }

  /// Dispose resources
  void dispose() {
    _advertisementSubscription?.cancel();
    _messageController.close();
    _cleanupTimer?.cancel();
    // Don't dispose the BLE service if it was provided externally
  }
}

/// Class representing a received Vuelink message
class VuelinkReceivedMessage {
  final String deviceName;
  final int rssi;
  final DateTime timestamp;
  final int manufacturerId;
  final Map<String, dynamic> messageData;
  final Uint8List rawData;
  bool shouldForward;

  VuelinkReceivedMessage({
    required this.deviceName,
    required this.rssi,
    required this.timestamp,
    required this.manufacturerId,
    required this.messageData,
    required this.rawData,
    this.shouldForward = true,
  });

  /// Convert VuelinkReceivedMessage to a JSON-serializable map
  Map<String, dynamic> toJson() {
    // Create a deep copy of messageData to modify enum values
    final Map<String, dynamic> serializableMessageData = {};
    messageData.forEach((key, value) {
      if (value is MessageType) {
        serializableMessageData[key] = value.value; // Store enum value
      } else if (value is Priority) {
        serializableMessageData[key] = value.value; // Store enum value
      } else if (value is FlightUpdateType) {
        serializableMessageData[key] = value.value; // Store enum value
      } else if (value is Uint8List) {
        // If raw bytes are somehow directly in messageData, encode them
        serializableMessageData[key] = base64Encode(value);
      } else {
        // Assume other types are directly serializable (String, int, bool, etc.)
        serializableMessageData[key] = value;
      }
    });

    return {
      'deviceName': deviceName,
      'rssi': rssi,
      'timestamp': timestamp.toIso8601String(), // Convert DateTime to string
      'manufacturerId': manufacturerId,
      'messageData': serializableMessageData, // Use the processed map
      'rawData': base64Encode(rawData), // Convert Uint8List to base64 string
      'shouldForward': shouldForward,
    };
  }

  /// Create VuelinkReceivedMessage from a JSON map
  factory VuelinkReceivedMessage.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> rawMessageData =
        json['messageData'] as Map<String, dynamic>;

    // Convert enum values back from integers
    final Map<String, dynamic> deserializedMessageData = {};
    rawMessageData.forEach((key, value) {
      if (key == 'messageType' && value is int) {
        deserializedMessageData[key] = MessageType.fromValue(value);
      } else if (key == 'priority' && value is int) {
        deserializedMessageData[key] = Priority.fromValue(value);
      } else if (key == 'updateType' && value is int) {
        deserializedMessageData[key] = FlightUpdateType.values.firstWhere(
          (type) => type.value == value,
          orElse: () => FlightUpdateType.general, // Default if needed
        );
      } else if (key == 'content' &&
          value is String &&
          rawMessageData['messageType'] == MessageType.generalBasic.value) {
        // Handle potential base64 encoded raw bytes if stored directly (less common)
        try {
          deserializedMessageData[key] = base64Decode(value);
        } catch (e) {
          // Assume it wasn't base64, keep as string? Or handle error.
          // For basic messages, content is often treated as raw bytes,
          // but parseVuelinkPayload stores it directly as Uint8List.
          // This case might be less relevant unless toJson manually encoded it.
          deserializedMessageData[key] = value;
        }
      } else {
        // Assume other types are correct as they are
        deserializedMessageData[key] = value;
      }
    });

    return VuelinkReceivedMessage(
      deviceName: json['deviceName'] as String,
      rssi: json['rssi'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String), // Parse DateTime
      manufacturerId: json['manufacturerId'] as int,
      messageData: deserializedMessageData, // Use the reconstructed map
      rawData: base64Decode(json['rawData'] as String), // Decode base64 string
      shouldForward: json['shouldForward'] as bool,
    );
  }

  /// Convert VuelinkReceivedMessage to a simplified JSON map for deep linking
  Map<String, dynamic> toDeepLinkJson() {
    // Serialize only messageData and shouldForward
    final Map<String, dynamic> serializableMessageData = {};
    messageData.forEach((key, value) {
      if (value is MessageType) {
        serializableMessageData[key] = value.value;
      } else if (value is Priority) {
        serializableMessageData[key] = value.value;
      } else if (value is FlightUpdateType) {
        serializableMessageData[key] = value.value;
      } else if (value is Uint8List) {
        // Include content if it was stored as Uint8List (e.g., basic message)
        serializableMessageData[key] = base64Encode(value);
      } else {
        serializableMessageData[key] = value;
      }
    });

    return {
      // Exclude: deviceName, rssi, timestamp, manufacturerId, rawData
      'messageData': serializableMessageData,
      'shouldForward': shouldForward,
    };
  }

  /// Create VuelinkReceivedMessage from a simplified deep link JSON map
  factory VuelinkReceivedMessage.fromDeepLinkJson(Map<String, dynamic> json) {
    final Map<String, dynamic> rawMessageData =
        json['messageData'] as Map<String, dynamic>;

    // Deserialize messageData (similar to fromJson)
    final Map<String, dynamic> deserializedMessageData = {};
    rawMessageData.forEach((key, value) {
      if (key == 'messageType' && value is int) {
        deserializedMessageData[key] = MessageType.fromValue(value);
      } else if (key == 'priority' && value is int) {
        deserializedMessageData[key] = Priority.fromValue(value);
      } else if (key == 'updateType' && value is int) {
        deserializedMessageData[key] = FlightUpdateType.values.firstWhere(
          (type) => type.value == value,
          orElse: () => FlightUpdateType.general,
        );
      } else if (key == 'content' &&
          value is String &&
          (deserializedMessageData['messageType'] ==
              MessageType.generalBasic)) {
        // Handle potential base64 encoded raw bytes if stored directly
        try {
          deserializedMessageData[key] = base64Decode(value);
        } catch (e) {
          deserializedMessageData[key] =
              value; // Keep as string if decode fails
        }
      } else {
        deserializedMessageData[key] = value;
      }
    });

    // Use defaults/placeholders for excluded fields
    return VuelinkReceivedMessage(
      deviceName: 'Shared Link', // Placeholder
      rssi: -100, // Placeholder
      timestamp: DateTime.now(), // Use current time for received link message
      manufacturerId: 0, // Placeholder
      messageData: deserializedMessageData,
      rawData: Uint8List(0), // Empty placeholder
      shouldForward:
          json['shouldForward'] as bool? ?? false, // Default if missing
    );
  }
}

/// Helper class for efficiently building strings
class StringBuilder {
  final StringBuffer _buffer = StringBuffer();

  void append(String text) {
    _buffer.write(text);
  }

  @override
  String toString() {
    return _buffer.toString();
  }
}
