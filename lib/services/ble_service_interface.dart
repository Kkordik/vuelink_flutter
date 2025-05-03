import 'dart:typed_data';

/// Interface for BLE peripheral functionality
abstract class BleServiceInterface {
  /// Initialize the BLE service
  Future<bool> initialize();

  /// Check if BLE is supported on this device
  Future<bool> isSupported();

  /// Start advertising with the given parameters
  ///
  /// [serviceUuid] - The UUID to advertise
  /// [manufacturerData] - Optional manufacturer specific data (Android only)
  /// [serviceDataMap] - Optional map of service data (Android only)
  Future<bool> startAdvertising({
    required String serviceUuid,
    Uint8List? manufacturerData,
    Map<String, Uint8List>? serviceDataMap,
  });

  /// Stop BLE advertising
  Future<bool> stopAdvertising();

  /// Check if device is currently advertising
  Future<bool> isAdvertising();

  /// Request necessary permissions for BLE functionality
  Future<bool> requestPermissions();
}
