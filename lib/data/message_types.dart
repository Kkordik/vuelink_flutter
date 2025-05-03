/// Message types and priority definitions for Vuelink BLE system

import 'dart:typed_data';
import 'dart:convert';
import '../utils/constants.dart';
import 'package:flutter/foundation.dart';

/// Message types that can be encoded in a packet
enum MessageType {
  /// Unknown or invalid message type
  unknown(0),

  /// General Basic message type
  generalBasic(1),

  /// General Text message type
  generalText(2),

  /// Flight Update message type
  flightUpdate(3),

  /// Flight Update General message type
  flightUpdateGeneral(4),

  /// System message type
  system(5),

  /// Emergency message type
  emergency(6),

  /// Reserved for future use
  reserved(7);

  /// The integer value used in the flags byte
  final int value;
  const MessageType(this.value);

  /// Create a MessageType from an integer value
  factory MessageType.fromValue(int value) {
    return MessageType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => MessageType.unknown,
    );
  }
}

/// Priority levels for messages
enum Priority {
  /// Lowest priority
  low(0),

  /// Medium priority
  medium(1),

  /// High priority
  high(2),

  /// Urgent priority
  urgent(3),

  /// Emergency priority
  emergency(4),

  /// System message priority
  system(5),

  /// Test message priority
  test(6),

  /// Reserved for future use
  reserved(7);

  /// The integer value used in the flags byte
  final int value;
  const Priority(this.value);

  /// Create a Priority from an integer value
  factory Priority.fromValue(int value) {
    return Priority.values.firstWhere(
      (priority) => priority.value == value,
      orElse: () => Priority.low,
    );
  }
}

/// Base class for all message data structures
abstract class MessageData {
  /// Get the message type
  MessageType getMessageType();

  /// Part number for multi-part messages (1-based)
  int getPartNumber();

  /// Total parts in this message
  int getTotalParts();

  /// Whether message should be repeated/forwarded
  bool getRepeatFlag();

  /// Priority of the message
  Priority getPriority();

  /// Encode message to bytes for transmission
  Uint8List encode();

  /// Validate the message data
  bool validate();

  /// Create a MessageData instance from a map
  static MessageData fromMap(Map<String, dynamic> map) {
    final messageType = map['messageType'];

    // Determine message type and create appropriate instance
    if (messageType == MessageType.generalBasic) {
      return GeneralBasicMessageData(
        content: map['content'] ?? '',
        repeatFlag: map['repeatFlag'] ?? false,
        priority: map['priority'] ?? Priority.medium,
      );
    } else if (messageType == MessageType.generalText) {
      return GeneralTextMessageData(
        textContent: map['textContent'] ?? '',
        partNumber: map['partNumber'] ?? 1,
        totalParts: map['totalParts'] ?? 1,
        repeatFlag: map['repeatFlag'] ?? false,
        priority: map['priority'] ?? Priority.medium,
      );
    } else if (messageType == MessageType.flightUpdate) {
      return FlightUpdateMessageData(
        flightId: map['flightId'] ?? '',
        updateType: map['updateType'] ?? FlightUpdateType.general,
        repeatFlag: map['repeatFlag'] ?? true,
        priority: map['priority'] ?? Priority.high,
      );
    } else if (messageType == MessageType.flightUpdateGeneral) {
      return FlightUpdateGeneralMessageData(
        flightId: map['flightId'] ?? '',
        textContent: map['textContent'] ?? '',
        partNumber: map['partNumber'] ?? 1,
        totalParts: map['totalParts'] ?? 1,
        repeatFlag: map['repeatFlag'] ?? true,
        priority: map['priority'] ?? Priority.high,
      );
    } else {
      // Default to basic message if type is unknown
      return GeneralBasicMessageData(
        content: 'Unknown message type',
        repeatFlag: false,
        priority: Priority.low,
      );
    }
  }
}

/// General Basic message data
class GeneralBasicMessageData implements MessageData {
  /// Message content
  final String content;

  /// Whether message should be repeated
  final bool repeatFlag;

  /// Message priority
  final Priority priority;

  /// Constructor
  GeneralBasicMessageData({
    required this.content,
    this.repeatFlag = false,
    this.priority = Priority.medium,
  });

  @override
  MessageType getMessageType() {
    return MessageType.generalBasic;
  }

  @override
  int getPartNumber() {
    return 1;
  }

  @override
  int getTotalParts() {
    return 1;
  }

  @override
  bool getRepeatFlag() {
    return repeatFlag;
  }

  @override
  Priority getPriority() {
    return priority;
  }

  @override
  Uint8List encode() {
    // Return UTF-8 encoded content
    return Uint8List.fromList(utf8.encode(content));
  }

  @override
  bool validate() {
    // Validate content isn't empty and won't exceed max size
    if (content.isEmpty) {
      return false;
    }

    final encoded = utf8.encode(content);
    return encoded.length <= PacketFields.maxContentSize;
  }
}

/// General Text message data
class GeneralTextMessageData implements MessageData {
  /// Text content
  final String textContent;

  /// Part number for multi-part messages
  final int partNumber;

  /// Total parts in multi-part messages
  final int totalParts;

  /// Whether message should be repeated
  final bool repeatFlag;

  /// Message priority
  final Priority priority;

  /// Constructor
  GeneralTextMessageData({
    required this.textContent,
    this.partNumber = 1,
    this.totalParts = 1,
    this.repeatFlag = false,
    this.priority = Priority.medium,
  });

  @override
  MessageType getMessageType() {
    return MessageType.generalText;
  }

  @override
  int getPartNumber() {
    return partNumber;
  }

  @override
  int getTotalParts() {
    return totalParts;
  }

  @override
  bool getRepeatFlag() {
    return repeatFlag;
  }

  @override
  Priority getPriority() {
    return priority;
  }

  @override
  Uint8List encode() {
    // Return UTF-8 encoded content
    return Uint8List.fromList(utf8.encode(textContent));
  }

  @override
  bool validate() {
    if (textContent.isEmpty) {
      debugPrint(
        'GeneralTextMessageData validation failed: textContent is empty',
      );
      return false;
    }

    if (partNumber < 1 || totalParts < 1 || partNumber > totalParts) {
      debugPrint(
        'GeneralTextMessageData validation failed: invalid part numbers - partNumber: $partNumber, totalParts: $totalParts',
      );
      return false;
    }

    // We have 3 bits for part number and total parts (values 0-7)
    // But messages can be split into more parts at a higher level,
    // so don't restrict total parts here
    if (partNumber > 7) {
      debugPrint(
        'GeneralTextMessageData validation failed: partNumber ($partNumber) exceeds 7-bit limit',
      );
      return false; // Part number must still fit in 3 bits
    }

    final encoded = utf8.encode(textContent);
    final contentSize = encoded.length;
    final isValidSize = contentSize <= PacketFields.maxContentSize;
    if (!isValidSize) {
      debugPrint(
        'GeneralTextMessageData validation failed: content size ($contentSize) exceeds max content size (${PacketFields.maxContentSize})',
      );
    }
    return isValidSize;
  }
}

/// Flight Update message data
class FlightUpdateMessageData implements MessageData {
  /// Flight ID (e.g., airline code + flight number)
  final String flightId;

  /// Type of update
  final FlightUpdateType updateType;

  /// Whether message should be repeated
  final bool repeatFlag;

  /// Message priority
  final Priority priority;

  /// Constructor
  FlightUpdateMessageData({
    required this.flightId,
    required this.updateType,
    this.repeatFlag = true, // Default to repeating important flight updates
    this.priority = Priority.high,
  });

  @override
  MessageType getMessageType() {
    return MessageType.flightUpdate;
  }

  @override
  int getPartNumber() {
    return 1;
  }

  @override
  int getTotalParts() {
    return 1;
  }

  @override
  bool getRepeatFlag() {
    return repeatFlag;
  }

  @override
  Priority getPriority() {
    return priority;
  }

  @override
  Uint8List encode() {
    // Encode flight ID and update type efficiently
    // This is a simple implementation; could be optimized further
    final updateTypeByte = updateType.value;
    final flightIdBytes = utf8.encode(flightId);

    final result = Uint8List(flightIdBytes.length + 1);
    result[0] = updateTypeByte;
    result.setRange(1, result.length, flightIdBytes);

    return result;
  }

  @override
  bool validate() {
    if (flightId.isEmpty) {
      return false;
    }

    // Extra byte for update type + flight ID
    final encodedSize = 1 + utf8.encode(flightId).length;
    return encodedSize <= PacketFields.maxContentSize;
  }
}

/// Flight Update General message data
class FlightUpdateGeneralMessageData implements MessageData {
  /// Flight ID (e.g., airline code + flight number)
  final String flightId;

  /// Text content
  final String textContent;

  /// Part number for multi-part messages
  final int partNumber;

  /// Total parts in multi-part messages
  final int totalParts;

  /// Whether message should be repeated
  final bool repeatFlag;

  /// Message priority
  final Priority priority;

  /// Constructor
  FlightUpdateGeneralMessageData({
    required this.flightId,
    required this.textContent,
    this.partNumber = 1,
    this.totalParts = 1,
    this.repeatFlag = true, // Default to repeating important flight updates
    this.priority = Priority.high,
  });

  @override
  MessageType getMessageType() {
    return MessageType.flightUpdateGeneral;
  }

  @override
  int getPartNumber() {
    return partNumber;
  }

  @override
  int getTotalParts() {
    return totalParts;
  }

  @override
  bool getRepeatFlag() {
    return repeatFlag;
  }

  @override
  Priority getPriority() {
    return priority;
  }

  @override
  Uint8List encode() {
    // Encode flight ID and text content
    final flightIdBytes = utf8.encode(flightId);
    final textBytes = utf8.encode(textContent);

    final result = Uint8List(flightIdBytes.length + 1 + textBytes.length);
    result[0] = flightIdBytes.length; // First byte is length of flight ID
    result.setRange(1, flightIdBytes.length + 1, flightIdBytes);
    result.setRange(flightIdBytes.length + 1, result.length, textBytes);

    return result;
  }

  @override
  bool validate() {
    if (flightId.isEmpty || textContent.isEmpty) {
      debugPrint(
        'FlightUpdateGeneralMessageData validation failed: flightId or textContent is empty',
      );
      return false;
    }

    if (partNumber < 1 || totalParts < 1 || partNumber > totalParts) {
      debugPrint(
        'FlightUpdateGeneralMessageData validation failed: invalid part numbers - partNumber: $partNumber, totalParts: $totalParts',
      );
      return false;
    }

    // We have 3 bits for part number and total parts (values 0-7)
    if (partNumber > 7) {
      debugPrint(
        'FlightUpdateGeneralMessageData validation failed: partNumber ($partNumber) exceeds 7-bit limit',
      );
      return false;
    }

    // Calculate the size requirements
    final flightIdBytes = utf8.encode(flightId);
    final textBytes = utf8.encode(textContent);
    final totalBytes =
        flightIdBytes.length + 1 + textBytes.length; // +1 for separator
    final isValidSize = totalBytes <= PacketFields.maxContentSize;
    if (!isValidSize) {
      debugPrint(
        'FlightUpdateGeneralMessageData validation failed: total content size ($totalBytes) exceeds max content size (${PacketFields.maxContentSize})',
      );
    }
    return isValidSize;
  }
}

/// Types of flight updates
enum FlightUpdateType {
  /// General update
  general(0),

  /// Gate change
  gateChange(1),

  /// Boarding has started
  boarding(2),

  /// Flight is delayed
  delay(3),

  /// Flight is cancelled
  cancellation(4),

  /// Emergency situation
  emergency(5);

  /// The integer value used in the packet
  final int value;
  const FlightUpdateType(this.value);
}

/// Factory for creating message data instances
class MessageDataFactory {
  /// Create a General Basic message
  static GeneralBasicMessageData createGeneralBasic({
    required String content,
    bool repeatFlag = false,
    Priority priority = Priority.medium,
  }) {
    return GeneralBasicMessageData(
      content: content,
      repeatFlag: repeatFlag,
      priority: priority,
    );
  }

  /// Create a General Text message
  static GeneralTextMessageData createGeneralText({
    required String textContent,
    int partNumber = 1,
    int totalParts = 1,
    bool repeatFlag = false,
    Priority priority = Priority.medium,
  }) {
    return GeneralTextMessageData(
      textContent: textContent,
      partNumber: partNumber,
      totalParts: totalParts,
      repeatFlag: repeatFlag,
      priority: priority,
    );
  }

  /// Create a Flight Update message
  static FlightUpdateMessageData createFlightUpdate({
    required String flightId,
    required FlightUpdateType updateType,
    bool repeatFlag = true,
    Priority priority = Priority.high,
  }) {
    return FlightUpdateMessageData(
      flightId: flightId,
      updateType: updateType,
      repeatFlag: repeatFlag,
      priority: priority,
    );
  }

  /// Create a Flight Update General message
  static FlightUpdateGeneralMessageData createFlightUpdateGeneral({
    required String flightId,
    required String textContent,
    int partNumber = 1,
    int totalParts = 1,
    bool repeatFlag = true,
    Priority priority = Priority.high,
  }) {
    return FlightUpdateGeneralMessageData(
      flightId: flightId,
      textContent: textContent,
      partNumber: partNumber,
      totalParts: totalParts,
      repeatFlag: repeatFlag,
      priority: priority,
    );
  }
}
