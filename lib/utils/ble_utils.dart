import 'dart:typed_data';

/// Utility class for BLE-related operations
class BleUtils {
  /// Construct a manufacturer data payload with a company identifier
  ///
  /// [companyId] - The company identifier (16-bit)
  /// [data] - The payload data
  static Uint8List createManufacturerData(int companyId, List<int> data) {
    // Company ID is 2 bytes (little-endian)
    final List<int> completeData = [
      companyId & 0xFF, // Low byte of company ID
      (companyId >> 8) & 0xFF, // High byte of company ID
      ...data, // Payload data
    ];

    return Uint8List.fromList(completeData);
  }

  /// Create a standard format for advertising data
  ///
  /// [versionCode] - Version of the advertising protocol
  /// [deviceType] - Type of device (for filtering)
  /// [deviceId] - Unique identifier for the device
  /// [actionCode] - The action code for the advertisement
  static Uint8List createAdvertisementPayload({
    required int versionCode,
    required int deviceType,
    required String deviceId,
    required int actionCode,
  }) {
    // Convert deviceId string to bytes (limit to 10 bytes)
    final List<int> deviceIdBytes = deviceId.codeUnits;
    final List<int> truncatedDeviceId =
        deviceIdBytes.length > 10
            ? deviceIdBytes.sublist(0, 10)
            : deviceIdBytes;

    // Create the payload with a standard format:
    // [Version(1)][Type(1)][DeviceID(variable)][Action(1)]
    final List<int> payload = [
      versionCode & 0xFF,
      deviceType & 0xFF,
      ...truncatedDeviceId,
      actionCode & 0xFF,
    ];

    return Uint8List.fromList(payload);
  }

  /// Generate a standard service UUID for the application
  ///
  /// [appId] - Unique identifier for the application (0-9999)
  static String generateServiceUuid(int appId) {
    // Use a base UUID with the app ID replacing the last 4 digits
    // Format: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    final String baseUuid = '9a21e000-f5e7-4772-b7d9-000000000000';

    // Format the appId as a 4-digit hex string
    final String appIdHex = appId.toRadixString(16).padLeft(4, '0');

    // Replace the last 4 digits of the UUID with the app ID
    return baseUuid.substring(0, baseUuid.length - 4) + appIdHex;
  }
}
