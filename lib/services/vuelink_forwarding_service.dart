import 'dart:convert';
import 'package:flutter/foundation.dart'; // Re-add for debugPrint, listEquals
import 'package:shared_preferences/shared_preferences.dart';
import '../data/message_types.dart';
import 'vuelink_scanner_service.dart'; // Import for VuelinkReceivedMessage
// import 'package:flutter/foundation.dart' as foundation; // Remove prefixed import, use direct

/// Service to handle message forwarding logic and history tracking
class VuelinkForwardingService {
  /// Maximum number of messages to keep in history
  static const int maxHistorySize = 50;

  /// Number of recent messages to check for duplicates
  static const int duplicateCheckDepth = 10;

  /// List of received messages as JSON strings (most recent first)
  final List<String> _savedMessagesJson = [];

  /// Shared preferences instance for small data
  SharedPreferences? _prefs;

  /// Singleton instance
  static VuelinkForwardingService? _instance;

  /// Key for shared preferences storing full messages
  static const String _prefsKey = 'vuelink_saved_messages_json';

  /// Create or get the singleton instance
  factory VuelinkForwardingService() {
    _instance ??= VuelinkForwardingService._internal();
    return _instance!;
  }

  /// Private constructor
  VuelinkForwardingService._internal();

  /// Initialize the service
  Future<void> initialize() async {
    // Initialize shared preferences
    _prefs = await SharedPreferences.getInstance();

    // Load message history from persistent storage
    await _loadSavedMessages();
  }

  /// Load saved messages from persistent storage
  Future<void> _loadSavedMessages() async {
    try {
      final historyJson = _prefs?.getStringList(_prefsKey) ?? [];
      _savedMessagesJson.clear();
      _savedMessagesJson.addAll(historyJson);
      debugPrint(
        'Loaded ${_savedMessagesJson.length} saved messages from storage',
      );
    } catch (e) {
      debugPrint('Error loading saved messages: $e');
      // Optionally clear if loading fails?
      _savedMessagesJson.clear();
    }
  }

  /// Save message history (JSON strings) to persistent storage
  Future<void> _saveMessages() async {
    try {
      await _prefs?.setStringList(_prefsKey, _savedMessagesJson);
      debugPrint('Saved ${_savedMessagesJson.length} messages to storage');
    } catch (e) {
      debugPrint('Error saving messages: $e');
    }
  }

  /// Checks if two message data maps represent the same core message content.
  /// Ignores timestamps and fields not relevant to identity.
  bool _areMessagesContentEquivalent(
    Map<String, dynamic> msg1,
    Map<String, dynamic> msg2,
  ) {
    // Compare essential fields for identity
    if (msg1['messageType'] != msg2['messageType']) return false;

    // Compare based on type
    final type = msg1['messageType'] as MessageType?;
    if (type == MessageType.generalText) {
      return msg1['textContent'] == msg2['textContent'];
    } else if (type == MessageType.generalBasic) {
      // Compare raw content bytes if available
      final content1 = msg1['content'];
      final content2 = msg2['content'];
      if (content1 is Uint8List && content2 is Uint8List) {
        // Use listEquals for byte comparison (now available directly)
        return listEquals(content1, content2);
      }
      // Fallback or if content isn't bytes (e.g., string was stored)
      return content1 == content2;
    } else if (type == MessageType.flightUpdate) {
      // Ensure enums are compared correctly (they should be after rehydration)
      final updateType1 = msg1['updateType'] as FlightUpdateType?;
      final updateType2 = msg2['updateType'] as FlightUpdateType?;
      return msg1['flightId'] == msg2['flightId'] && updateType1 == updateType2;
    } else if (type == MessageType.flightUpdateGeneral) {
      return msg1['flightId'] == msg2['flightId'] &&
          msg1['textContent'] == msg2['textContent'];
    }
    // Add comparisons for other types if needed

    // Default to not equivalent if type isn't handled or doesn't match known types
    return false;
  }

  /// Determines if an incoming message should be processed (saved and potentially forwarded)
  /// based on duplication checks and the repeat flag.
  bool shouldProcessMessage(Map<String, dynamic> incomingMessageData) {
    final incomingRepeatFlag = incomingMessageData['repeatFlag'] == true;
    bool isDuplicate = false;
    bool isDuplicateWithRepeat = false;

    // Prepare incoming message for comparison (mainly to handle enums if needed)
    // Note: _prepareForSerialization adds timestamp, which we ignore in comparison
    final comparableIncomingData = _prepareForSerialization(
      Map.from(incomingMessageData),
    );

    // Check the last 'duplicateCheckDepth' messages
    final checkLimit =
        _savedMessagesJson.length < duplicateCheckDepth
            ? _savedMessagesJson.length
            : duplicateCheckDepth;

    for (int i = 0; i < checkLimit; i++) {
      try {
        final savedMessageMapRaw = jsonDecode(_savedMessagesJson[i]);

        // --- FIX: Rehydrate the saved map before comparison ---
        final savedMessageMap = _rehydrateMapFromStorage(savedMessageMapRaw);
        // -----------------------------------------------------

        // Note: savedMessageMap now has enums as enums, content as Uint8List etc.
        // comparableIncomingData also has enums as enums, content as Uint8List etc.
        // because _prepareForSerialization handles the conversion for comparison needs implicitly.
        // However, let's adjust _prepareForSerialization to NOT add timestamp for comparison.

        if (_areMessagesContentEquivalent(
          // Pass the original incoming data, _areMessagesContentEquivalent will handle comparison
          incomingMessageData, // Use original data before _prepare adds timestamp
          savedMessageMap,
        )) {
          isDuplicate = true;
          final savedRepeatFlag = savedMessageMap['repeatFlag'] == true;
          if (savedRepeatFlag) {
            isDuplicateWithRepeat = true;
            break; // Found the critical case (duplicate with repeat flag)
          }
          // Keep checking other recent messages even if a non-repeat duplicate is found,
          // in case a duplicate *with* repeat exists further down.
        }
      } catch (e) {
        debugPrint(
          'Error deserializing message during duplicate check: $e - Skipping message.',
        );
        continue; // Skip corrupted message
      }
    }

    // Logic: Process if it's NOT a duplicate, OR if it IS a duplicate
    // but the incoming message has the repeat flag AND the duplicate found
    // did NOT have the repeat flag (preventing infinite loops).
    final bool shouldProcess =
        !isDuplicate || (incomingRepeatFlag && !isDuplicateWithRepeat);

    if (!shouldProcess) {
      debugPrint('Skipping message due to duplication rules.');
      if (isDuplicate && incomingRepeatFlag && isDuplicateWithRepeat) {
        debugPrint(' -> Reason: Incoming repeat matches recent repeat.');
      } else if (isDuplicate && !incomingRepeatFlag) {
        debugPrint(' -> Reason: Duplicate found, incoming has no repeat flag.');
      }
    }

    return shouldProcess;
  }

  /// Prepare message data for JSON serialization
  Map<String, dynamic> _prepareForSerialization(
    Map<String, dynamic> messageData, {
    bool addTimestamp = true, // Add optional flag
  }) {
    final serializableData = Map<String, dynamic>.from(messageData);

    // Convert non-serializable types to strings or lists
    if (serializableData.containsKey('content') &&
        serializableData['content'] is Uint8List) {
      final content = serializableData['content'] as Uint8List;
      // Store as base64 string for efficiency and JSON compatibility
      serializableData['content_base64'] = base64Encode(content);
      serializableData.remove('content'); // Remove original Uint8List
    }
    if (serializableData.containsKey('messageType') &&
        serializableData['messageType'] is Enum) {
      serializableData['messageType'] =
          (serializableData['messageType'] as Enum).name;
    }
    if (serializableData.containsKey('priority') &&
        serializableData['priority'] is Enum) {
      serializableData['priority'] =
          (serializableData['priority'] as Enum).name;
    }
    if (serializableData.containsKey('updateType') &&
        serializableData['updateType'] is Enum) {
      serializableData['updateType'] =
          (serializableData['updateType'] as Enum).name;
    }
    // Add timestamp only if requested (i.e., when actually saving, not just comparing)
    if (addTimestamp && !serializableData.containsKey('receivedTimestamp')) {
      serializableData['receivedTimestamp'] = DateTime.now().toIso8601String();
    }

    return serializableData;
  }

  /// Convert a map loaded from storage back to a map with proper types (Enums, Uint8List)
  Map<String, dynamic> _rehydrateMapFromStorage(
    Map<String, dynamic> mapFromStorage,
  ) {
    final Map<String, dynamic> rehydratedMap = Map.from(mapFromStorage);
    // Convert serialized fields back (similar logic to getSavedMessages)
    if (rehydratedMap.containsKey('messageType') &&
        rehydratedMap['messageType'] is String) {
      rehydratedMap['messageType'] = MessageType.values.firstWhere(
        (e) => e.name == rehydratedMap['messageType'],
        orElse: () => MessageType.unknown,
      );
    }
    if (rehydratedMap.containsKey('priority') &&
        rehydratedMap['priority'] is String) {
      rehydratedMap['priority'] = Priority.values.firstWhere(
        (e) => e.name == rehydratedMap['priority'],
        orElse: () => Priority.low,
      );
    }
    if (rehydratedMap.containsKey('updateType') &&
        rehydratedMap['updateType'] is String) {
      rehydratedMap['updateType'] = FlightUpdateType.values.firstWhere(
        (e) => e.name == rehydratedMap['updateType'],
        orElse: () => FlightUpdateType.general,
      );
    }
    if (rehydratedMap.containsKey('content_base64') &&
        rehydratedMap['content_base64'] is String) {
      try {
        rehydratedMap['content'] = base64Decode(
          rehydratedMap['content_base64'] as String,
        );
      } catch (e) {
        debugPrint("Error decoding base64 content during rehydration: $e");
        rehydratedMap['content'] = Uint8List(0); // Assign empty list on error
      }
      rehydratedMap.remove('content_base64');
    }
    // Keep other fields like repeatFlag, partNumber, totalParts, textContent, flightId as they are
    return rehydratedMap;
  }

  /// Record a received message in history (SHOULD ONLY BE CALLED AFTER shouldProcessMessage returns true)
  ///
  /// [messageData] - Parsed message data map
  Future<void> recordMessage(Map<String, dynamic> messageData) async {
    try {
      // Prepare data for serialization, ensuring timestamp is added
      final serializableData = _prepareForSerialization(
        messageData,
        addTimestamp: true,
      );

      // Convert the prepared map to a JSON string
      final messageJson = jsonEncode(serializableData);

      // Add JSON string to history (most recent first)
      _savedMessagesJson.insert(0, messageJson);

      // Trim history if it exceeds max size
      if (_savedMessagesJson.length > maxHistorySize) {
        _savedMessagesJson.removeRange(
          maxHistorySize,
          _savedMessagesJson.length,
        );
      }

      // Save updated list to persistent storage
      await _saveMessages();
    } catch (e, stackTrace) {
      debugPrint('Error recording message: $e');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Get the list of saved messages, deserialized from JSON
  /// Returns maps representing the message data.
  List<Map<String, dynamic>> getSavedMessages() {
    final List<Map<String, dynamic>> messages = [];
    for (final jsonString in _savedMessagesJson) {
      try {
        final Map<String, dynamic> messageMap = jsonDecode(jsonString);

        // Convert serialized fields back if needed (e.g., enums, base64 content)
        if (messageMap.containsKey('messageType') &&
            messageMap['messageType'] is String) {
          messageMap['messageType'] = MessageType.values.firstWhere(
            (e) => e.name == messageMap['messageType'],
            orElse: () => MessageType.unknown, // Default if name doesn't match
          );
        }
        if (messageMap.containsKey('priority') &&
            messageMap['priority'] is String) {
          messageMap['priority'] = Priority.values.firstWhere(
            (e) => e.name == messageMap['priority'],
            orElse: () => Priority.low, // Default if name doesn't match
          );
        }
        if (messageMap.containsKey('updateType') &&
            messageMap['updateType'] is String) {
          messageMap['updateType'] = FlightUpdateType.values.firstWhere(
            (e) => e.name == messageMap['updateType'],
            orElse:
                () => FlightUpdateType.general, // Default if name doesn't match
          );
        }
        // Convert base64 content back to Uint8List
        if (messageMap.containsKey('content_base64') &&
            messageMap['content_base64'] is String) {
          messageMap['content'] = base64Decode(
            messageMap['content_base64'] as String,
          );
          messageMap.remove('content_base64'); // Remove the base64 field
        }

        messages.add(messageMap);
      } catch (e) {
        debugPrint('Error deserializing saved message: $e');
        // Skip this message if deserialization fails
      }
    }
    // Messages are already stored most recent first
    return messages;
  }

  /// Adds messages received from a deep link, checking for duplicates.
  /// Returns the number of new messages added.
  Future<int> addMessagesFromDeepLink(
    List<VuelinkReceivedMessage> messages,
  ) async {
    int newMessagesAdded = 0;
    if (_prefs == null) await initialize(); // Ensure initialized

    // Process messages in reverse order so the oldest from the link get checked first
    for (final message in messages.reversed) {
      // Use the messageData map from the VuelinkReceivedMessage object
      final messageData = message.messageData;

      // Check if this message should be processed (using existing duplication logic)
      if (shouldProcessMessage(messageData)) {
        // Record the message using the existing method
        // This will prepare it for serialization and save it
        await recordMessage(messageData);
        newMessagesAdded++;
      } else {
        debugPrint(
          'Deep link message skipped due to duplication rules: ${messageData['messageType']}',
        );
      }
    }

    if (newMessagesAdded > 0) {
      debugPrint('Added $newMessagesAdded new messages from deep link.');
      // No need to explicitly call _saveMessages here as recordMessage already does.
    } else {
      debugPrint('No new messages added from deep link (all duplicates).');
    }

    return newMessagesAdded;
  }

  /// Clears all saved messages from memory and persistent storage
  Future<void> clearHistory() async {
    _savedMessagesJson.clear();
    await _prefs?.remove(_prefsKey); // Remove from SharedPreferences
    debugPrint('Cleared all saved messages.');
  }
}
