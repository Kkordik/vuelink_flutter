import 'dart:convert';
// For GZipCodec - NO LONGER NEEDED FOR BINARY
import 'dart:typed_data';
// For kDebugMode if needed

import '../services/vuelink_scanner_service.dart'; // Import the message class
import '../data/message_types.dart'; // Import for enums
// Import for PacketFields

// --- Binary Encoding/Decoding --- Version 1
const int _deepLinkFormatVersion = 1;

/// Encodes a list of VuelinkReceivedMessage objects into a compact binary format.
Uint8List? _encodeMessagesToBinary(List<VuelinkReceivedMessage> messages) {
  if (messages.length > 255) {
    // print('Error: Cannot encode more than 255 messages in deep link format v1.');
    return null;
  }

  final BytesBuilder builder = BytesBuilder();

  // 1. Header
  builder.addByte(_deepLinkFormatVersion); // Version
  builder.addByte(messages.length); // Message Count

  // 2. Message Entries
  for (final message in messages) {
    try {
      final messageData = message.messageData;
      final messageType =
          messageData['messageType'] as MessageType? ?? MessageType.unknown;
      final priority = messageData['priority'] as Priority? ?? Priority.low;
      final repeatFlag = messageData['repeatFlag'] as bool? ?? false;
      final shouldForward = message.shouldForward;

      // Build Flags Byte (reusing PacketFields logic)
      int flagsByte = 0;
      flagsByte |= (messageType.value & 0x07); // Bits 0-2: MessageType
      flagsByte |= ((priority.value & 0x07) << 3); // Bits 3-5: Priority
      flagsByte |= ((repeatFlag ? 1 : 0) << 6); // Bit 6: RepeatFlag
      builder.addByte(flagsByte);

      // Should Forward Flag
      builder.addByte(shouldForward ? 1 : 0);

      // Prepare Content Bytes based on type
      Uint8List contentBytes = Uint8List(0);
      switch (messageType) {
        case MessageType.generalText:
          final text = messageData['textContent'] as String? ?? '';
          contentBytes = Uint8List.fromList(utf8.encode(text));
          break;
        case MessageType.flightUpdate:
          final flightId = messageData['flightId'] as String? ?? '';
          final updateType =
              messageData['updateType'] as FlightUpdateType? ??
              FlightUpdateType.general;
          final idBytes = utf8.encode(flightId);
          final BytesBuilder content = BytesBuilder();
          content.addByte(updateType.value); // Add update type byte
          content.add(idBytes); // Add flight ID bytes
          contentBytes = content.toBytes();
          break;
        case MessageType.flightUpdateGeneral:
          final flightId = messageData['flightId'] as String? ?? '';
          final text = messageData['textContent'] as String? ?? '';
          final idBytes = utf8.encode(flightId);
          final textBytes = utf8.encode(text);
          if (idBytes.length > 255) {
            // print('Warning: Flight ID too long (>255 bytes) for binary format, skipping content.');
            contentBytes = Uint8List(0); // Or handle differently
          } else {
            final BytesBuilder content = BytesBuilder();
            content.addByte(idBytes.length); // Add flight ID length byte
            content.add(idBytes);
            content.add(textBytes);
            contentBytes = content.toBytes();
          }
          break;
        case MessageType.generalBasic:
          // Decide how to handle basic content. Encode as UTF-8 for now.
          final basicContent = messageData['content'] as dynamic;
          if (basicContent is String) {
            contentBytes = Uint8List.fromList(utf8.encode(basicContent));
          } else if (basicContent is Uint8List) {
            contentBytes = basicContent;
          } // else leave empty
          break;
        default:
          // Add other types or leave contentBytes empty
          break;
      }

      // Content Length (2 bytes, Big Endian)
      if (contentBytes.length > 65535) {
        // print('Warning: Content too long (>65535 bytes) for binary format, truncating.',);
        // Or skip message? For now, we just add 0 length
        builder.addByte(0);
        builder.addByte(0);
      } else {
        final lengthData = ByteData(2);
        lengthData.setUint16(0, contentBytes.length, Endian.big);
        builder.add(lengthData.buffer.asUint8List());
        // Content Bytes
        builder.add(contentBytes);
      }
    } catch (e) {
      // print('Error encoding message to binary, skipping: $e');
      // Add placeholder bytes for the failed message to maintain count?
      // For now, skip silently, which might corrupt decoding later if count mismatches.
      // A better approach might be to return null from the outer function.
      return null; // Indicate failure
    }
  }

  return builder.toBytes();
}

/// Decodes a compact binary format back into a list of VuelinkReceivedMessage objects.
List<VuelinkReceivedMessage>? _decodeMessagesFromBinary(Uint8List binaryData) {
  if (binaryData.length < 2) {
    // print('Error: Binary data too short for header.');
    return null;
  }

  final ByteData dataView = ByteData.view(binaryData.buffer);
  int offset = 0;

  // 1. Header
  final int version = dataView.getUint8(offset++);
  if (version != _deepLinkFormatVersion) {
    // print('Error: Unsupported deep link format version: $version');
    return null;
  }
  final int messageCount = dataView.getUint8(offset++);

  final List<VuelinkReceivedMessage> messages = [];

  // 2. Message Entries
  for (int i = 0; i < messageCount; i++) {
    try {
      if (offset + 4 > dataView.lengthInBytes) {
        // Need at least Flags, ShouldForward, Length(2)
        // print('Error: Incomplete message data at index $i');
        return null; // Corrupted data
      }

      // Flags Byte
      final int flagsByte = dataView.getUint8(offset++);
      final messageType = MessageType.fromValue(flagsByte & 0x07);
      final priority = Priority.fromValue((flagsByte >> 3) & 0x07);
      final repeatFlag = ((flagsByte >> 6) & 0x01) == 1;

      // Should Forward Flag
      final bool shouldForward = dataView.getUint8(offset++) == 1;

      // Content Length
      final int contentLength = dataView.getUint16(offset, Endian.big);
      offset += 2;

      if (offset + contentLength > dataView.lengthInBytes) {
        // print('Error: Declared content length ($contentLength) exceeds available data at index $i',);
        return null; // Corrupted data
      }

      // Content Bytes
      final contentBytes = binaryData.sublist(offset, offset + contentLength);
      offset += contentLength;

      // Build messageData map based on type
      final Map<String, dynamic> messageData = {
        'messageType': messageType,
        'priority': priority,
        'repeatFlag': repeatFlag,
        // Part numbers are not included in this format
        'partNumber': 1,
        'totalParts': 1,
      };

      switch (messageType) {
        case MessageType.generalText:
          messageData['textContent'] = utf8.decode(
            contentBytes,
            allowMalformed: true,
          );
          break;
        case MessageType.flightUpdate:
          if (contentBytes.isNotEmpty) {
            messageData['updateType'] = FlightUpdateType.values.firstWhere(
              (t) => t.value == contentBytes[0],
              orElse: () => FlightUpdateType.general,
            );
            if (contentBytes.length > 1) {
              messageData['flightId'] = utf8.decode(
                contentBytes.sublist(1),
                allowMalformed: true,
              );
            } else {
              messageData['flightId'] = '';
            }
          } else {
            messageData['updateType'] = FlightUpdateType.general;
            messageData['flightId'] = '';
          }
          break;
        case MessageType.flightUpdateGeneral:
          if (contentBytes.isNotEmpty) {
            final int idLength = contentBytes[0];
            if (contentBytes.length > idLength + 1) {
              messageData['flightId'] = utf8.decode(
                contentBytes.sublist(1, idLength + 1),
                allowMalformed: true,
              );
              messageData['textContent'] = utf8.decode(
                contentBytes.sublist(idLength + 1),
                allowMalformed: true,
              );
            } else if (contentBytes.length > 1 && idLength > 0) {
              // Only flight ID present
              messageData['flightId'] = utf8.decode(
                contentBytes.sublist(1, idLength + 1),
                allowMalformed: true,
              );
              messageData['textContent'] = '';
            } else {
              messageData['flightId'] = '';
              messageData['textContent'] = '';
            }
          } else {
            messageData['flightId'] = '';
            messageData['textContent'] = '';
          }
          break;
        case MessageType.generalBasic:
          // Store raw bytes as received
          messageData['content'] = contentBytes;
          break;
        default:
          // Store raw bytes for unhandled types
          messageData['content'] = contentBytes;
          break;
      }

      // Create the message object (using placeholders for BLE metadata)
      messages.add(
        VuelinkReceivedMessage(
          deviceName: 'Shared Link', // Placeholder
          rssi: -100, // Placeholder
          timestamp: DateTime.now(), // Use current time
          manufacturerId: 0, // Placeholder
          messageData: messageData,
          rawData: contentBytes, // Store decoded content as rawData?
          shouldForward: shouldForward,
        ),
      );
    } catch (e) {
      // print('Error decoding message from binary at index $i: $e');
      return null; // Corrupted data
    }
  }

  return messages;
}

/// Encodes a list of VuelinkReceivedMessage objects into a compressed, URL-safe Base64 string using a binary format.
///
/// Args:
///   messages: A list of VuelinkReceivedMessage objects.
///
/// Returns:
///   A URL-safe Base64 encoded string representing the compressed binary message list,
///   or null if encoding fails.
String? encodeMessagesForDeepLink(List<VuelinkReceivedMessage> messages) {
  try {
    // 1. Encode messages to binary format
    final Uint8List? binaryData = _encodeMessagesToBinary(messages);
    if (binaryData == null) {
      return null; // Encoding failed
    }

    // 2. Encode the binary bytes using URL-safe Base64
    final String base64UrlString = base64UrlEncode(
      binaryData,
    ).replaceAll('=', ''); // Remove padding

    // print('Encoded ${messages.length} messages. Binary size: ${binaryData.length} bytes, Encoded length: ${base64UrlString.length} chars.',);

    return base64UrlString;
  } catch (e) {
    // print('Error encoding messages for deep link: $e');
    return null;
  }
}

/// Decodes a compact binary, URL-safe Base64 string back into a list of VuelinkReceivedMessage objects.
///
/// Args:
///   encodedData: The URL-safe Base64 encoded string from the deep link.
///
/// Returns:
///   A list of VuelinkReceivedMessage objects, or null if decoding fails.
List<VuelinkReceivedMessage>? decodeMessagesFromDeepLink(String encodedData) {
  try {
    // 1. Decode the URL-safe Base64 string (add padding back if needed for decoder)
    String paddedEncodedData = encodedData;
    if (encodedData.length % 4 != 0) {
      paddedEncodedData += '=' * (4 - encodedData.length % 4);
    }
    final Uint8List binaryData = base64Url.decode(paddedEncodedData);

    // 2. Decode the binary data into message objects
    final List<VuelinkReceivedMessage>? messages = _decodeMessagesFromBinary(
      binaryData,
    );
    if (messages != null) {
      // print('Decoded ${messages.length} messages from binary deep link data.');
    }
    return messages;
  } catch (e) {
    // print('Error decoding messages from deep link: $e');
    return null;
  }
}
