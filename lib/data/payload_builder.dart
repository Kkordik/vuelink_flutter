import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../data/message_types.dart';
import '../utils/constants.dart';

/// Utility class for building and parsing Vuelink advertisement payloads
class PayloadBuilder {
  /// Build a Vuelink advertisement payload based on the simplified packet structure:
  /// - Byte 0: Part info (part number, total parts, repeat flag)
  /// - Byte 1: Flags (message type, priority)
  /// - Bytes 2+: Content (up to 21 bytes)
  ///
  /// [messageData] - The message data to encode
  ///
  /// Returns a Uint8List with the formatted payload
  static Uint8List buildVuelinkAdvertisementPayload(MessageData messageData) {
    // Get the encoded content - must do this first to check size
    Uint8List contentBytes;
    try {
      contentBytes = messageData.encode();
    } catch (e) {
      debugPrint('Error encoding message content: $e');
      // Provide a fallback empty content
      contentBytes = Uint8List(0);
    }

    // Validate the message data - we now make this non-fatal to handle split messages
    if (!messageData.validate()) {
      debugPrint('Warning: Proceeding with invalid message data');

      // Log more details about the content size
      debugPrint(
        'Content size: ${contentBytes.length} bytes (max: ${PacketFields.maxContentSize})',
      );

      // If content is drastically over the limit, we can't proceed
      if (contentBytes.length > PacketFields.maxContentSize * 2) {
        throw ArgumentError(
          'Content too large: ${contentBytes.length} bytes (max: ${PacketFields.maxContentSize})',
        );
      }

      // For smaller overages, we'll truncate the content
      if (contentBytes.length > PacketFields.maxContentSize) {
        debugPrint(
          'Truncating content to ${PacketFields.maxContentSize} bytes',
        );
        contentBytes = contentBytes.sublist(0, PacketFields.maxContentSize);
      }
    }

    // Create the part info byte
    final int partInfoByte = packPartInfo(
      messageData.getPartNumber(),
      messageData.getTotalParts(),
      messageData.getRepeatFlag(),
    );

    // Create the flags byte
    final int flagsByte = packMessageTypeAndPriority(
      messageData.getMessageType().value,
      messageData.getPriority().value,
    );

    // Safety check - truncate if too large
    if (contentBytes.length > PacketFields.maxContentSize) {
      debugPrint(
        'Warning: Content too large (${contentBytes.length} bytes), truncating to ${PacketFields.maxContentSize} bytes',
      );
      contentBytes = contentBytes.sublist(0, PacketFields.maxContentSize);
    }

    // Create the complete payload
    final Uint8List payload = Uint8List(
      PacketFields.minTotalSize + contentBytes.length,
    );

    // Set part info byte
    payload[PacketFields.partInfoOffset] = partInfoByte;

    // Set flags byte
    payload[PacketFields.flagsOffset] = flagsByte;

    // Set content
    payload.setRange(
      PacketFields.contentOffset,
      PacketFields.contentOffset + contentBytes.length,
      contentBytes,
    );

    return payload;
  }

  /// Parse a Vuelink advertisement payload into its components
  static Map<String, dynamic>? parseVuelinkAdvertisementPayload(
    Uint8List payload,
  ) {
    // Validate payload size
    if (payload.length < PacketFields.minTotalSize) {
      return null; // Invalid payload size
    }

    try {
      // Extract part info byte and flags byte
      final int partInfoByte = payload[PacketFields.partInfoOffset];
      final int flagsByte = payload[PacketFields.flagsOffset];

      // Parse part info
      final int partNumber = extractPartNumber(partInfoByte);
      final int totalParts = extractTotalParts(partInfoByte);
      final bool repeatFlag = extractRepeatFlag(partInfoByte);

      // Parse message type and priority
      final int messageTypeValue = extractMessageType(flagsByte);
      final int priorityValue = extractPriority(flagsByte);

      final MessageType messageType = MessageType.fromValue(messageTypeValue);
      final Priority priority = Priority.fromValue(priorityValue);

      // Extract content
      final Uint8List content = payload.sublist(PacketFields.contentOffset);

      return {
        'messageType': messageType,
        'priority': priority,
        'partNumber': partNumber,
        'totalParts': totalParts,
        'repeatFlag': repeatFlag,
        'content': content,
      };
    } catch (e) {
      return null; // Error parsing
    }
  }

  /// Validate a payload to ensure it meets size and format constraints
  static bool validatePayload(Uint8List payload) {
    // Check if payload meets minimum size
    if (payload.length < PacketFields.minTotalSize) {
      return false;
    }

    // Check if payload exceeds maximum size
    // Android manufacturer data should typically be kept under 24 bytes
    // as there is overhead in the advertisement packet
    if (payload.length >
        PacketFields.minTotalSize + PacketFields.maxContentSize) {
      return false;
    }

    // Additional validation could be added here
    return true;
  }

  /// Format payload information into a human-readable string
  static String formatPayloadInfo(Map<String, dynamic> payloadInfo) {
    final StringBuffer buffer = StringBuffer();

    buffer.writeln('Message Type: ${payloadInfo['messageType']}');
    buffer.writeln('Priority: ${payloadInfo['priority']}');
    buffer.writeln(
      'Part: ${payloadInfo['partNumber']}/${payloadInfo['totalParts']}',
    );
    buffer.writeln('Repeat: ${payloadInfo['repeatFlag']}');

    // Try to decode content as UTF-8 if it's text-based
    try {
      final String contentText = utf8.decode(payloadInfo['content']);
      buffer.writeln('Content (text): $contentText');
    } catch (e) {
      // If not text, show as hex
      final String contentHex = payloadInfo['content']
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      buffer.writeln('Content (hex): $contentHex');
    }

    return buffer.toString();
  }

  /// Split a large message into chunks that fit within BLE advertisement limits
  static List<MessageData> splitIntoChunks(MessageData messageData) {
    // If the message already fits in a single packet, return it as is
    final contentBytes = messageData.encode();
    debugPrint(
      'PayloadBuilder: Original message size: ${contentBytes.length} bytes',
    );
    debugPrint(
      'PayloadBuilder: Max content size: ${PacketFields.maxContentSize} bytes',
    );

    if (contentBytes.length <= PacketFields.maxContentSize) {
      debugPrint(
        'PayloadBuilder: Message fits in a single packet, not splitting',
      );
      return [messageData];
    }

    final List<MessageData> chunks = [];

    // Handle different message types differently
    switch (messageData.getMessageType()) {
      case MessageType.generalText:
        final textMessage = messageData as GeneralTextMessageData;
        final chunks = _splitTextMessage(textMessage);
        debugPrint(
          'PayloadBuilder: Split text message into ${chunks.length} parts',
        );
        return chunks;

      case MessageType.flightUpdateGeneral:
        final flightUpdateMessage =
            messageData as FlightUpdateGeneralMessageData;
        final chunks = _splitFlightUpdateGeneralMessage(flightUpdateMessage);
        debugPrint(
          'PayloadBuilder: Split flight update message into ${chunks.length} parts',
        );
        return chunks;
      case MessageType.generalBasic:
        final generalBasicMessage = messageData as GeneralBasicMessageData;
        final chunks = _splitGeneralBasicMessage(generalBasicMessage);
        debugPrint(
          'PayloadBuilder: Split general basic message into ${chunks.length} parts',
        );
        return chunks;
      default:
        // For other types, just return the original message
        // They should be small enough to fit in one packet
        debugPrint(
          'PayloadBuilder: Message type ${messageData.getMessageType()} not supported for splitting',
        );
        return [messageData];
    }
  }

  /// Split a text message into chunks
  static List<GeneralTextMessageData> _splitTextMessage(
    GeneralTextMessageData message,
  ) {
    final textBytes = Uint8List.fromList(utf8.encode(message.textContent));
    debugPrint(
      '_splitTextMessage: Original text length: ${textBytes.length} bytes',
    );

    // Calculate how many parts we need
    final int totalParts =
        (textBytes.length / PacketFields.maxContentSize).ceil();
    debugPrint('_splitTextMessage: Will split into $totalParts parts');

    // Create a list to hold all parts
    final List<GeneralTextMessageData> parts = [];

    // Split the message into parts
    for (int i = 0; i < totalParts; i++) {
      final int startIndex = i * PacketFields.maxContentSize;
      final int endIndex =
          (startIndex + PacketFields.maxContentSize > textBytes.length)
              ? textBytes.length
              : startIndex + PacketFields.maxContentSize;

      final partText = utf8.decode(textBytes.sublist(startIndex, endIndex));
      debugPrint(
        '_splitTextMessage: Part ${i + 1} text length: ${partText.length} characters',
      );

      // For part numbering in the packet, we need to handle the 3-bit limitation
      // The part number in the packet is modulo 8 (0-7), but we track the actual part number
      // in the MessageData object for higher-level processing
      final int packetPartNumber =
          (i % 7) + 1; // 1-7 (not 0-7, as 0 is invalid)
      final int packetTotalParts = totalParts > 7 ? 7 : totalParts.toInt();

      debugPrint(
        '_splitTextMessage: Part ${i + 1} - packetPartNumber: $packetPartNumber, packetTotalParts: $packetTotalParts',
      );

      parts.add(
        GeneralTextMessageData(
          textContent: partText,
          partNumber: packetPartNumber, // Use 1-7 range for packet
          totalParts: packetTotalParts, // Max 7 in packet
          repeatFlag: message.repeatFlag,
          priority: message.priority,
        ),
      );
    }

    debugPrint('_splitTextMessage: Created ${parts.length} parts');
    return parts;
  }

  /// Split a flight update general message into chunks
  static List<FlightUpdateGeneralMessageData> _splitFlightUpdateGeneralMessage(
    FlightUpdateGeneralMessageData message,
  ) {
    // The flight ID stays the same for all parts
    final flightId = message.flightId;
    debugPrint('_splitFlightUpdateGeneralMessage: FlightId: $flightId');

    // Split the text content
    final textBytes = Uint8List.fromList(utf8.encode(message.textContent));
    debugPrint(
      '_splitFlightUpdateGeneralMessage: Original text length: ${textBytes.length} bytes',
    );

    // Allow space for flight ID in each packet
    final int flightIdSize =
        utf8.encode(flightId).length + 1; // +1 for null terminator
    final int maxTextSize = PacketFields.maxContentSize - flightIdSize;
    debugPrint(
      '_splitFlightUpdateGeneralMessage: Max text size per part: $maxTextSize bytes (after accounting for flightId: $flightIdSize bytes)',
    );

    // Calculate how many parts we need
    final int totalParts = (textBytes.length / maxTextSize).ceil();
    debugPrint(
      '_splitFlightUpdateGeneralMessage: Will split into $totalParts parts',
    );

    // Create a list to hold all parts
    final List<FlightUpdateGeneralMessageData> parts = [];

    // Split the message into parts
    for (int i = 0; i < totalParts; i++) {
      final int startIndex = i * maxTextSize;
      final int endIndex =
          (startIndex + maxTextSize > textBytes.length)
              ? textBytes.length
              : startIndex + maxTextSize;

      final partText = utf8.decode(textBytes.sublist(startIndex, endIndex));
      debugPrint(
        '_splitFlightUpdateGeneralMessage: Part ${i + 1} text length: ${partText.length} characters',
      );

      // For part numbering in the packet, we need to handle the 3-bit limitation
      // The part number in the packet is modulo 8 (0-7), but we track the actual part number
      // in the MessageData object for higher-level processing
      final int packetPartNumber =
          (i % 7) + 1; // 1-7 (not 0-7, as 0 is invalid)
      final int packetTotalParts = totalParts > 7 ? 7 : totalParts.toInt();

      debugPrint(
        '_splitFlightUpdateGeneralMessage: Part ${i + 1} - packetPartNumber: $packetPartNumber, packetTotalParts: $packetTotalParts',
      );

      parts.add(
        FlightUpdateGeneralMessageData(
          flightId: flightId,
          textContent: partText,
          partNumber: packetPartNumber, // Use 1-7 range for packet
          totalParts: packetTotalParts, // Max 7 in packet
          repeatFlag: message.repeatFlag,
          priority: message.priority,
        ),
      );
    }

    debugPrint(
      '_splitFlightUpdateGeneralMessage: Created ${parts.length} parts',
    );
    return parts;
  }

  /// Split a general basic message into chunks
  static List<GeneralBasicMessageData> _splitGeneralBasicMessage(
    GeneralBasicMessageData message,
  ) {
    final contentBytes = Uint8List.fromList(utf8.encode(message.content));
    debugPrint(
      '_splitGeneralBasicMessage: Original content length: ${contentBytes.length} bytes',
    );

    // Calculate how many parts we need
    final int totalParts =
        (contentBytes.length / PacketFields.maxContentSize).ceil();
    debugPrint('_splitGeneralBasicMessage: Will split into $totalParts parts');

    // Create a list to hold all parts
    final List<GeneralBasicMessageData> parts = [];

    // Split the message into parts
    for (int i = 0; i < totalParts; i++) {
      final int startIndex = i * PacketFields.maxContentSize;
      final int endIndex =
          (startIndex + PacketFields.maxContentSize > contentBytes.length)
              ? contentBytes.length
              : startIndex + PacketFields.maxContentSize;

      final partContent = utf8.decode(
        contentBytes.sublist(startIndex, endIndex),
      );
      debugPrint(
        '_splitGeneralBasicMessage: Part ${i + 1} content length: ${partContent.length} characters',
      );

      // For part numbering in the packet, we need to handle the 3-bit limitation
      final int packetPartNumber =
          (i % 7) + 1; // 1-7 (not 0-7, as 0 is invalid)
      final int packetTotalParts = totalParts > 7 ? 7 : totalParts.toInt();

      debugPrint(
        '_splitGeneralBasicMessage: Part ${i + 1} - packetPartNumber: $packetPartNumber, packetTotalParts: $packetTotalParts',
      );

      parts.add(
        GeneralBasicMessageData(
          content: partContent,
          repeatFlag: message.repeatFlag,
          priority: message.priority,
        ),
      );
    }

    debugPrint('_splitGeneralBasicMessage: Created ${parts.length} parts');
    return parts;
  }
}
