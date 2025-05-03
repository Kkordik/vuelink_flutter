/// Constants for Vuelink BLE advertisement packet format

/// Manufacturer ID for Vuelink packets (using a standard reserved testing ID)
/// In a production app, you would register with Bluetooth SIG
const int VUELINK_MANUFACTURER_ID = 0xFFFF; // Standard testing ID

/// Constants for packet field offsets and sizes
class PacketFields {
  /// Offset for part and repeat info byte
  static const int partInfoOffset = 0;

  /// Size of part info field in bytes (part number, total parts, repeat flag)
  static const int partInfoSize = 1;

  /// Offset for flags field in bytes (message type, priority)
  static const int flagsOffset = 1;

  /// Size of flags field in bytes
  static const int flagsSize = 1;

  /// Offset for content field in bytes
  static const int contentOffset = 2;

  /// Maximum content size in bytes (BLE max 23 - header bytes)
  static const int maxContentSize = 21; // 23 - 2

  /// Minimum total payload size in bytes (without content)
  static const int minTotalSize = 2; // Part info + flags

  /// Extract the total parts from part info byte
  static int getTotalParts(int partInfoByte) {
    return extractTotalParts(partInfoByte);
  }

  /// Extract the part number from part info byte
  static int getPartNumber(int partInfoByte) {
    return extractPartNumber(partInfoByte);
  }

  /// Extract the message type from flags byte
  static int getMessageType(int flagsByte) {
    return extractMessageType(flagsByte);
  }

  /// Extract the priority from flags byte
  static int getPriority(int flagsByte) {
    return extractPriority(flagsByte);
  }

  /// Extract the repeat flag from part info byte
  static bool getRepeatFlag(int partInfoByte) {
    return extractRepeatFlag(partInfoByte);
  }
}

/// Bit positions in the flags byte
class FlagBits {
  /// Start position of the message type bits (0-2)
  static const int messageTypeStartBit = 0;

  /// Length of message type field in bits
  static const int messageTypeBits = 3;

  /// Start position of the priority bits (3-5)
  static const int priorityStartBit = 3;

  /// Length of priority field in bits
  static const int priorityBits = 3;

  /// Reserved bits (6-7)
  static const int reservedStartBit = 6;

  /// Length of reserved field in bits
  static const int reservedBits = 2;
}

/// Bit positions in the part info byte
class PartInfoBits {
  /// Start position of the part number bits (0-2)
  static const int partNumberStartBit = 0;

  /// Length of part number field in bits (supports up to 8 parts)
  static const int partNumberBits = 3;

  /// Start position of the total parts bits (3-5)
  static const int totalPartsStartBit = 3;

  /// Length of total parts field in bits (supports up to 8 parts)
  static const int totalPartsBits = 3;

  /// Repeat flag bit (bit 6)
  static const int repeatFlagBit = 6;

  /// Reserved bit (bit 7)
  static const int reservedBit = 7;
}

/// Maximum advertisement name length
const int MAX_ADVERTISEMENT_NAME_LENGTH = 8; // 'VL' is recommended

/// Utility functions for flags byte manipulation
int packMessageTypeAndPriority(int messageType, int priority) {
  int flags = 0;

  // Set message type bits (0-2)
  flags |=
      (messageType & ((1 << FlagBits.messageTypeBits) - 1)) <<
      FlagBits.messageTypeStartBit;

  // Set priority bits (3-5)
  flags |=
      (priority & ((1 << FlagBits.priorityBits) - 1)) <<
      FlagBits.priorityStartBit;

  return flags;
}

/// Utility functions for part info byte manipulation
int packPartInfo(int partNumber, int totalParts, bool repeatFlag) {
  int partInfo = 0;

  // Set part number bits (0-2)
  partInfo |=
      (partNumber & ((1 << PartInfoBits.partNumberBits) - 1)) <<
      PartInfoBits.partNumberStartBit;

  // Set total parts bits (3-5)
  partInfo |=
      (totalParts & ((1 << PartInfoBits.totalPartsBits) - 1)) <<
      PartInfoBits.totalPartsStartBit;

  // Set repeat flag bit (bit 6)
  if (repeatFlag) {
    partInfo |= (1 << PartInfoBits.repeatFlagBit);
  }

  return partInfo;
}

/// Extract functions for flags byte
int extractMessageType(int flagsByte) {
  return (flagsByte >> FlagBits.messageTypeStartBit) &
      ((1 << FlagBits.messageTypeBits) - 1);
}

int extractPriority(int flagsByte) {
  return (flagsByte >> FlagBits.priorityStartBit) &
      ((1 << FlagBits.priorityBits) - 1);
}

/// Extract functions for part info byte
int extractPartNumber(int partInfoByte) {
  return (partInfoByte >> PartInfoBits.partNumberStartBit) &
      ((1 << PartInfoBits.partNumberBits) - 1);
}

int extractTotalParts(int partInfoByte) {
  return (partInfoByte >> PartInfoBits.totalPartsStartBit) &
      ((1 << PartInfoBits.totalPartsBits) - 1);
}

bool extractRepeatFlag(int partInfoByte) {
  return (partInfoByte & (1 << PartInfoBits.repeatFlagBit)) != 0;
}
