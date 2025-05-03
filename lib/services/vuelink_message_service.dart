import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../data/message_types.dart';
import '../services/ble_service.dart';
import '../utils/constants.dart';
import '../data/payload_builder.dart';

/// Service class for handling Vuelink message operations
class VuelinkMessageService {
  // Track current broadcasting state
  static MessageType? _currentMessageType;
  static Priority? _currentPriority;
  static bool? _currentRepeatFlag;
  static int? _currentPartNumber;
  static int? _currentTotalParts;
  static Timer? _autoStopTimer;

  // Track multi-part message sequences
  static List<MessageData>? _messageParts;
  static int _currentPartIndex = 0;
  static Timer? _sequenceTimer;
  static bool _isSequenceRunning = false;

  /// Create advertisement data with a Vuelink payload and start advertising
  ///
  /// [bleService] - The BLE service instance
  /// [messageData] - The message data to send
  /// [includeServiceUuid] - Whether to include service UUID
  /// [autoStopDuration] - Duration after which to auto-stop (null for no auto-stop)
  /// [onAutoStopped] - Callback when advertising is auto-stopped
  static Future<bool> startVuelinkAdvertising({
    required BleService bleService,
    required MessageData messageData,
    bool includeServiceUuid = false,
    Duration? autoStopDuration = const Duration(seconds: 3),
    VoidCallback? onAutoStopped,
  }) async {
    try {
      // Cancel any existing timers
      _autoStopTimer?.cancel();
      _sequenceTimer?.cancel();
      _isSequenceRunning = false;

      // Split message into parts if needed
      final messageParts = PayloadBuilder.splitIntoChunks(messageData);

      if (messageParts.isEmpty) {
        debugPrint('Error: Message splitting returned empty parts list');
        return false;
      }

      // Log the message parts for debugging
      debugPrint(
        'VuelinkMessageService: Message split into ${messageParts.length} parts',
      );
      for (int i = 0; i < messageParts.length; i++) {
        final part = messageParts[i];
        final bool validates = part.validate();
        debugPrint(
          'VuelinkMessageService: Part ${i + 1}/${messageParts.length} - validates: $validates',
        );
        if (!validates) {
          debugPrint('VuelinkMessageService: Part ${i + 1} validation failed');
          // Continue anyway - we'll catch these errors when trying to build the payload
        }
      }

      // If it's a single part message, handle it normally
      if (messageParts.length == 1) {
        return _advertiseMessagePart(
          bleService: bleService,
          messageData: messageParts[0],
          includeServiceUuid: includeServiceUuid,
          autoStopDuration: autoStopDuration,
          onAutoStopped: onAutoStopped,
        );
      }

      // For multi-part messages, start the sequence
      _messageParts = messageParts;
      _currentPartIndex = 0;
      _isSequenceRunning = true;

      // Start the first part
      final success = await _advertiseMessagePart(
        bleService: bleService,
        messageData: messageParts[0],
        includeServiceUuid: includeServiceUuid,
        autoStopDuration: autoStopDuration,
        onAutoStopped: () {
          _sequenceNextPart(
            bleService: bleService,
            includeServiceUuid: includeServiceUuid,
            autoStopDuration: autoStopDuration,
            onCompleted: onAutoStopped,
          );
        },
      );

      return success;
    } catch (e) {
      debugPrint('Error starting advertising: $e');
      return false;
    }
  }

  /// Advertise a single message part
  static Future<bool> _advertiseMessagePart({
    required BleService bleService,
    required MessageData messageData,
    bool includeServiceUuid = false,
    Duration? autoStopDuration = const Duration(seconds: 3),
    VoidCallback? onAutoStopped,
  }) async {
    try {
      // Cancel any existing timer
      _autoStopTimer?.cancel();

      // First, check if the message data validates
      if (!messageData.validate()) {
        debugPrint('Message data validation failed');

        // Try to provide more details about the message
        final msgType = messageData.getMessageType().toString().split('.').last;
        final partNum = messageData.getPartNumber();
        final totalParts = messageData.getTotalParts();

        debugPrint('Invalid message: $msgType part $partNum/$totalParts');

        // Log the message content size
        if (messageData is GeneralTextMessageData) {
          final textContent = messageData.textContent;
          final contentBytes = utf8.encode(textContent);
          debugPrint(
            'Text content size: ${contentBytes.length} bytes (max: ${PacketFields.maxContentSize})',
          );
        } else if (messageData is FlightUpdateGeneralMessageData) {
          final flightMsg = messageData;
          final flightIdBytes = utf8.encode(flightMsg.flightId);
          final textBytes = utf8.encode(flightMsg.textContent);
          final totalSize = flightIdBytes.length + 1 + textBytes.length;
          debugPrint(
            'Flight message size: $totalSize bytes (max: ${PacketFields.maxContentSize})',
          );
        }

        // We'll attempt to create the payload anyway
      }

      // Create the Vuelink payload
      Uint8List payloadData;
      try {
        payloadData = PayloadBuilder.buildVuelinkAdvertisementPayload(
          messageData,
        );
      } catch (e) {
        debugPrint('Failed to build payload: $e');
        return false;
      }

      // Validate payload size
      if (!PayloadBuilder.validatePayload(payloadData)) {
        debugPrint(
          'Payload too large: ${payloadData.length} bytes (max: ${PacketFields.maxContentSize + 2})',
        );
        return false;
      }

      // Store current settings
      _currentMessageType = messageData.getMessageType();
      _currentPriority = messageData.getPriority();
      _currentRepeatFlag = messageData.getRepeatFlag();
      _currentPartNumber = messageData.getPartNumber();
      _currentTotalParts = messageData.getTotalParts();

      // Start advertising with manufacturer data
      final success = await bleService.startAdvertising(
        name: 'VL',
        manufacturerId: VUELINK_MANUFACTURER_ID,
        manufacturerData: payloadData,
        includeServiceUuid: includeServiceUuid,
      );

      // Set auto-stop timer if requested and advertising started successfully
      if (success && autoStopDuration != null) {
        _autoStopTimer = Timer(autoStopDuration, () async {
          await stopVuelinkAdvertising(bleService);
          debugPrint(
            'Auto-stopped advertising part ${messageData.getPartNumber()}/${messageData.getTotalParts()} after $autoStopDuration',
          );
          onAutoStopped?.call();
        });
      }

      return success;
    } catch (e) {
      debugPrint('Error advertising part: $e');
      return false;
    }
  }

  /// Process the next part in a multi-part message sequence
  static void _sequenceNextPart({
    required BleService bleService,
    bool includeServiceUuid = false,
    Duration? autoStopDuration,
    VoidCallback? onCompleted,
  }) {
    if (!_isSequenceRunning || _messageParts == null) {
      return;
    }

    _currentPartIndex++;

    // Check if we've completed all parts
    if (_currentPartIndex >= _messageParts!.length) {
      debugPrint('Completed advertising all ${_messageParts!.length} parts');
      _isSequenceRunning = false;
      _messageParts = null;
      onCompleted?.call();
      return;
    }

    // Start advertising the next part
    final nextPart = _messageParts![_currentPartIndex];

    // Add a small delay between parts to ensure clean separation
    _sequenceTimer = Timer(const Duration(milliseconds: 100), () async {
      final success = await _advertiseMessagePart(
        bleService: bleService,
        messageData: nextPart,
        includeServiceUuid: includeServiceUuid,
        autoStopDuration: autoStopDuration,
        onAutoStopped: () {
          _sequenceNextPart(
            bleService: bleService,
            includeServiceUuid: includeServiceUuid,
            autoStopDuration: autoStopDuration,
            onCompleted: onCompleted,
          );
        },
      );

      if (!success) {
        debugPrint(
          'Failed to advertise part ${nextPart.getPartNumber()}/${nextPart.getTotalParts()}',
        );
        _isSequenceRunning = false;
        onCompleted?.call();
      }
    });
  }

  /// Stop BLE advertising
  static Future<bool> stopVuelinkAdvertising(BleService bleService) async {
    try {
      // Cancel auto-stop timer
      _autoStopTimer?.cancel();
      _autoStopTimer = null;

      final result = await bleService.stopAdvertising();
      if (result) {
        // Clear current state
        _currentMessageType = null;
        _currentPriority = null;
        _currentRepeatFlag = null;
        _currentPartNumber = null;
        _currentTotalParts = null;
      }
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Cancel any ongoing multi-part message sequence
  static Future<bool> cancelSequence(BleService bleService) async {
    _sequenceTimer?.cancel();
    _isSequenceRunning = false;
    _messageParts = null;
    return await stopVuelinkAdvertising(bleService);
  }

  /// Get current broadcast information
  static Future<Map<String, dynamic>> getCurrentBroadcastInfo(
    BleService bleService,
  ) async {
    final isActive = await bleService.isAdvertising();

    return {
      'isActive': isActive,
      'messageType': _currentMessageType?.toString().split('.').last ?? 'none',
      'priority': _currentPriority?.toString().split('.').last ?? 'none',
      'repeatFlag': _currentRepeatFlag ?? false,
      'partNumber': _currentPartNumber ?? 0,
      'totalParts': _currentTotalParts ?? 0,
    };
  }

  /// Parse manufacturer data to extract Vuelink packet information
  ///
  /// [manufacturerData] - The raw manufacturer data received
  /// [manufacturerId] - The manufacturer ID received
  static Map<String, dynamic>? parseVuelinkPayload(
    Uint8List data,
    int manufacturerId,
  ) {
    if (manufacturerId != VUELINK_MANUFACTURER_ID) {
      // Not a Vuelink message
      return null;
    }

    try {
      // Need a minimum of 2 bytes (part info and flags)
      if (data.length < PacketFields.minTotalSize) {
        return null;
      }

      // Extract the part info byte
      final partInfoByte = data[PacketFields.partInfoOffset];
      final totalParts = PacketFields.getTotalParts(partInfoByte);
      final partNumber = PacketFields.getPartNumber(partInfoByte);

      // Extract the flags byte
      final flagsByte = data[PacketFields.flagsOffset];
      final priorityValue = PacketFields.getPriority(flagsByte);
      final priority = Priority.values.firstWhere(
        (p) => p.value == priorityValue,
        orElse: () => Priority.medium,
      );
      final repeatFlag = PacketFields.getRepeatFlag(flagsByte);

      // Extract the message type
      final messageTypeByte = PacketFields.getMessageType(flagsByte);
      final messageType = MessageType.values.firstWhere(
        (type) => type.value == messageTypeByte,
        orElse: () => MessageType.generalBasic,
      );

      // Extract the payload bytes (everything after the header)
      final contentBytes = data.sublist(
        PacketFields.contentOffset,
        data.length,
      );

      // Parse the content based on message type
      final Map<String, dynamic> messageInfo = {
        'messageType': messageType,
        'priority': priority,
        'repeatFlag': repeatFlag,
        'partNumber': partNumber,
        'totalParts': totalParts,
      };

      // Process specific message types
      switch (messageType) {
        case MessageType.generalBasic:
          // Content is just raw bytes - could be any format
          messageInfo['content'] = contentBytes;
          break;

        case MessageType.generalText:
          // Content is UTF-8 text
          messageInfo['textContent'] = String.fromCharCodes(contentBytes);
          break;

        case MessageType.flightUpdate:
          // First bytes should be the flight ID string until null terminator or end
          int nullTerminatorIndex = contentBytes.indexOf(0);
          if (nullTerminatorIndex == -1) {
            nullTerminatorIndex = contentBytes.length;
          }

          final flightId = String.fromCharCodes(
            contentBytes.sublist(0, nullTerminatorIndex),
          );
          messageInfo['flightId'] = flightId;

          // If there's more data, it's the update type
          if (contentBytes.length > nullTerminatorIndex + 1) {
            final updateTypeByte = contentBytes[nullTerminatorIndex + 1];
            final updateType = FlightUpdateType.values.firstWhere(
              (type) => type.value == updateTypeByte,
              orElse: () => FlightUpdateType.general,
            );
            messageInfo['updateType'] = updateType;
          } else {
            messageInfo['updateType'] = FlightUpdateType.general;
          }
          break;

        case MessageType.flightUpdateGeneral:
          // First bytes should be the flight ID string until null terminator
          int nullTerminatorIndex = contentBytes.indexOf(0);
          if (nullTerminatorIndex == -1) {
            // No null terminator found, assume the whole content is the flight ID
            messageInfo['flightId'] = String.fromCharCodes(contentBytes);
            messageInfo['textContent'] = '';
          } else {
            // Extract flight ID and text content
            messageInfo['flightId'] = String.fromCharCodes(
              contentBytes.sublist(0, nullTerminatorIndex),
            );

            // If there's more data after the null terminator, it's the text content
            if (contentBytes.length > nullTerminatorIndex + 1) {
              messageInfo['textContent'] = String.fromCharCodes(
                contentBytes.sublist(nullTerminatorIndex + 1),
              );
            } else {
              messageInfo['textContent'] = '';
            }
          }
          break;

        default:
          // Unknown message type, store as raw content
          messageInfo['content'] = contentBytes;
      }

      return messageInfo;
    } catch (e) {
      debugPrint('Error parsing Vuelink payload: $e');
      return null;
    }
  }

  /// Format a parsed message into a human-readable string
  static String formatPayloadInfo(Map<String, dynamic> messageInfo) {
    final StringBuffer output = StringBuffer();

    // Output basic message info
    final messageType = messageInfo['messageType'];
    final priority = messageInfo['priority'];
    final repeatFlag = messageInfo['repeatFlag'];

    output.writeln('Type: ${messageType.toString().split('.').last}');
    output.writeln('Priority: ${priority.toString().split('.').last}');
    output.writeln('Repeat: ${repeatFlag ? 'Yes' : 'No'}');

    if (messageInfo.containsKey('partNumber') &&
        messageInfo.containsKey('totalParts')) {
      output.writeln(
        'Part: ${messageInfo['partNumber']}/${messageInfo['totalParts']}',
      );
    }

    // Output message-specific content
    switch (messageType) {
      case MessageType.generalBasic:
        if (messageInfo.containsKey('content')) {
          final content = messageInfo['content'] as Uint8List;
          output.writeln('\nRaw Content (${content.length} bytes):');
          output.writeln(_formatHexData(content));
        }
        break;

      case MessageType.generalText:
        if (messageInfo.containsKey('textContent')) {
          output.writeln('\nContent:');
          output.writeln('"${messageInfo['textContent']}"');
        }
        break;

      case MessageType.flightUpdate:
        if (messageInfo.containsKey('flightId')) {
          output.writeln('\nFlight ID: ${messageInfo['flightId']}');
        }
        if (messageInfo.containsKey('updateType')) {
          final updateType = messageInfo['updateType'];
          output.writeln(
            'Update Type: ${updateType.toString().split('.').last}',
          );
        }
        break;

      case MessageType.flightUpdateGeneral:
        if (messageInfo.containsKey('flightId')) {
          output.writeln('\nFlight ID: ${messageInfo['flightId']}');
        }
        if (messageInfo.containsKey('textContent')) {
          output.writeln('Message:');
          output.writeln('"${messageInfo['textContent']}"');
        }
        break;

      default:
        // Generic output for unknown types
        if (messageInfo.containsKey('content')) {
          final content = messageInfo['content'] as Uint8List;
          output.writeln('\nRaw Content (${content.length} bytes):');
          output.writeln(_formatHexData(content));
        }
    }

    return output.toString();
  }

  /// Format a byte array as a hex string for display
  static String _formatHexData(Uint8List data, {int bytesPerLine = 8}) {
    if (data.isEmpty) return '(empty)';

    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < data.length; i++) {
      if (i % bytesPerLine == 0 && i > 0) {
        buffer.writeln();
      }

      final String hex =
          data[i].toRadixString(16).padLeft(2, '0').toUpperCase();
      buffer.write('$hex ');
    }

    return buffer.toString();
  }

  /// Check if a received message should be forwarded
  ///
  /// This takes into account the repeat flag and other factors
  /// like urgency of the message
  static bool shouldForwardMessage(Map<String, dynamic> payloadInfo) {
    // Always forward if repeat flag is set
    if (payloadInfo['repeatFlag'] == true) {
      return true;
    }

    // Always forward emergency and urgent messages
    final priority = payloadInfo['priority'] as Priority;
    if (priority == Priority.emergency || priority == Priority.urgent) {
      return true;
    }

    // Don't forward general messages without repeat flag
    return false;
  }
}
