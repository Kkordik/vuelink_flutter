import 'dart:async';
import 'dart:io';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

/// Implementation of BLE Service using bluetooth_low_energy package
class BleService {
  /// Logger for BLE service
  final _log = Logger('BleService');

  /// Central manager for BLE operations in client mode
  final CentralManager _centralManager = CentralManager();

  /// Peripheral manager for BLE operations in peripheral/server mode
  final PeripheralManager _peripheralManager = PeripheralManager();

  /// Stream subscriptions
  StreamSubscription? _centralStateSubscription;
  StreamSubscription? _peripheralStateSubscription;
  StreamSubscription? _advertisementSubscription;

  /// Controller for peripheral state changes to expose publicly
  final StreamController<BluetoothLowEnergyState> _peripheralStateController =
      StreamController.broadcast();

  /// Controller for received advertisements
  final StreamController<Advertisement> _advertisementController =
      StreamController.broadcast();

  /// Public stream for peripheral state
  Stream<BluetoothLowEnergyState> get peripheralStateStream =>
      _peripheralStateController.stream;

  /// Public stream for received advertisements
  Stream<Advertisement> get advertisementStream =>
      _advertisementController.stream;

  /// Flag indicating if service is initialized
  bool _isInitialized = false;

  /// Flag indicating if advertising is active
  bool _isAdvertising = false;

  /// Flag indicating if scanning is active
  bool _isScanning = false;

  /// UUID for our service
  final String _serviceUuid = 'bf27730d-860a-4e09-889c-2d8b6a9e0fe7';

  /// Initialize the BLE service
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    // Set up logging
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      if (kDebugMode) {
        print('${record.level.name}: ${record.time}: ${record.message}');
      }
    });

    // Subscribe to BLE state changes *before* requesting permissions
    // This ensures we catch the state change after permissions are granted
    _centralStateSubscription = _centralManager.stateChanged.listen((args) {
      _log.info('Central BLE state changed: ${args.state}');

      // If scanning and state is no longer powered on, stop scanning
      if (_isScanning && args.state != BluetoothLowEnergyState.poweredOn) {
        stopScanning();
      }
    });

    _peripheralStateSubscription = _peripheralManager.stateChanged.listen((
      args,
    ) {
      _log.info('Peripheral BLE state changed: ${args.state}');
      // Feed the stream controller
      _peripheralStateController.add(args.state);

      // If advertising and state is no longer powered on, stop advertising
      if (_isAdvertising && args.state != BluetoothLowEnergyState.poweredOn) {
        stopAdvertising();
      }

      // Automatically request authorization if needed on Android
      if (args.state == BluetoothLowEnergyState.unauthorized &&
          Platform.isAndroid) {
        _log.warning(
          'Peripheral state is unauthorized. Requesting authorization...',
        );
        _peripheralManager.authorize().catchError((e) {
          _log.severe('Error during automatic peripheral authorization: $e');
          return false; // Return false to indicate authorization failed
        });
      }
    });

    // Request required permissions
    final permissionsGranted = await requestPermissions();
    if (!permissionsGranted) {
      _log.severe('BLE permissions not granted during initialization');
      // Add the current (likely unauthorized or unknown) state to the stream
      _peripheralStateController.add(_peripheralManager.state);
      return false; // Indicate initialization failed due to permissions
    }

    // Add the current state *after* attempting permission request
    _peripheralStateController.add(_peripheralManager.state);
    _isInitialized = true;
    return true;
  }

  /// Start scanning for BLE advertisements
  Future<bool> startScanning({int? manufacturerId}) async {
    if (!_isInitialized) {
      _log.warning('BLE service not initialized');
      return false;
    }

    if (_centralManager.state != BluetoothLowEnergyState.poweredOn) {
      _log.severe(
        'Cannot start scanning. Central state is not poweredOn (${_centralManager.state}).',
      );
      return false;
    }

    try {
      if (_isScanning) {
        await stopScanning();
      }

      // --- Re-check state just before starting discovery ---
      if (_centralManager.state != BluetoothLowEnergyState.poweredOn) {
        _log.warning(
          'Central state changed to ${_centralManager.state} just before starting discovery. Aborting scan.',
        );
        return false;
      }
      // -------------------------------------------------

      // Process advertisement events when discovered
      _advertisementSubscription = _centralManager.discovered.listen((args) {
        // Forward the advertisement to listeners
        _advertisementController.add(args.advertisement);
      });

      // Start the scan operation
      await _centralManager.startDiscovery();
      _isScanning = true;
      _log.info('Started scanning for advertisements');

      return true;
    } catch (e) {
      _log.severe('Error starting scan: $e');
      return false;
    }
  }

  /// Stop scanning for BLE advertisements
  Future<bool> stopScanning() async {
    if (!_isInitialized || !_isScanning) {
      return false;
    }

    try {
      await _centralManager.stopDiscovery();
      _advertisementSubscription?.cancel();
      _advertisementSubscription = null;
      _isScanning = false;
      _log.info('Stopped scanning');
      return true;
    } catch (e) {
      _log.severe('Error stopping scan: $e');
      return false;
    }
  }

  /// Check if device is currently scanning
  bool isScanning() {
    return _isScanning;
  }

  void dispose() {
    _centralStateSubscription?.cancel();
    _peripheralStateSubscription?.cancel();
    _advertisementSubscription?.cancel();
    _peripheralStateController.close(); // Close the stream controller
    _advertisementController.close();
    if (_isAdvertising) {
      stopAdvertising();
    }
    if (_isScanning) {
      stopScanning();
    }
  }

  /// Check if BLE peripheral mode is supported and powered on
  /// Note: Call this *after* initialize() and ensuring permissions are granted.
  Future<bool> isPeripheralReady() async {
    // Ensure Location Services are enabled on Android (cannot check programmatically easily)
    if (Platform.isAndroid) {
      _log.info(
        "Reminder: Ensure Location Services are enabled in Android system settings for BLE peripheral mode.",
      );
    }

    try {
      // Use the *current* state, not just checking for 'unsupported'
      return _peripheralManager.state == BluetoothLowEnergyState.poweredOn;
    } catch (e) {
      _log.severe('Error checking peripheral readiness: $e');
      return false;
    }
  }

  /// Request required permissions for BLE
  Future<bool> requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = {};
    List<Permission> permissionsToRequest = [];

    int androidSdkVersion = 0; // Variable to hold SDK version

    if (Platform.isAndroid) {
      // Get Android SDK version
      final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      androidSdkVersion = androidInfo.version.sdkInt;
      _log.info('Android SDK Version: $androidSdkVersion');

      if (androidSdkVersion >= 31) {
        // Android 12+ specific permissions
        _log.info('Requesting Android 12+ BLE permissions...');
        permissionsToRequest.addAll([
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
          // Location is not strictly required for BLE ops on Android 12+
          // unless using `neverForLocation=false` flag or needing location data itself.
          // Keep it for now if your app relies on location for other reasons or
          // if scanning needs location (unlikely with neverForLocation flag).
          // If location is *only* for BLE below Android 12, you can remove this for SDK 31+.
          Permission.locationWhenInUse,
        ]);
      } else {
        // Android < 12 permissions
        _log.info('Requesting legacy Android BLE permissions...');
        permissionsToRequest.addAll([
          Permission.bluetooth,
          // Location is required for BLE scanning on older Android versions
          Permission.locationWhenInUse, // Or locationAlways if needed
        ]);
      }
    } else if (Platform.isIOS) {
      // iOS handles permissions differently via authorize() and Info.plist
      _log.info('Requesting iOS BLE permissions (handled by authorize)...');
      permissionsToRequest.add(Permission.bluetooth);
    }

    if (permissionsToRequest.isEmpty && !Platform.isIOS) {
      _log.info('No specific permissions needed for this platform.');
      // Still need to authorize for iOS/macOS etc. handled later
    } else if (permissionsToRequest.isNotEmpty) {
      // Request necessary permissions
      _log.info('Requesting permissions: $permissionsToRequest');
      statuses = await permissionsToRequest.request();
    }

    bool allRequiredGranted = true;
    // --- Check statuses based on platform and SDK version ---
    if (Platform.isAndroid) {
      if (androidSdkVersion >= 31) {
        // Check Android 12+ permissions
        allRequiredGranted &=
            statuses[Permission.bluetoothScan]?.isGranted ?? false;
        allRequiredGranted &=
            statuses[Permission.bluetoothAdvertise]?.isGranted ?? false;
        allRequiredGranted &=
            statuses[Permission.bluetoothConnect]?.isGranted ?? false;
        // Also check location if it was requested for SDK 31+
        if (permissionsToRequest.contains(Permission.locationWhenInUse)) {
          allRequiredGranted &=
              statuses[Permission.locationWhenInUse]?.isGranted ?? false;
        }

        // Log individual statuses for debugging
        _log.info('--- Permission Request Results (Android 12+) ---');
        _log.info('bluetoothScan: ${statuses[Permission.bluetoothScan]}');
        _log.info(
          'bluetoothAdvertise: ${statuses[Permission.bluetoothAdvertise]}',
        );
        _log.info('bluetoothConnect: ${statuses[Permission.bluetoothConnect]}');
        if (permissionsToRequest.contains(Permission.locationWhenInUse)) {
          _log.info(
            'locationWhenInUse: ${statuses[Permission.locationWhenInUse]}',
          );
        }
        _log.info('---------------------------------');
      } else {
        // Check legacy Android permissions
        allRequiredGranted &=
            statuses[Permission.bluetooth]?.isGranted ?? false;
        allRequiredGranted &=
            statuses[Permission.locationWhenInUse]?.isGranted ?? false;

        // Log individual statuses for debugging
        _log.info('--- Permission Request Results (Android < 12) ---');
        _log.info('bluetooth: ${statuses[Permission.bluetooth]}');
        _log.info(
          'locationWhenInUse: ${statuses[Permission.locationWhenInUse]}',
        );
        _log.info('---------------------------------');
      }
    } else if (Platform.isIOS) {
      // For iOS, we primarily rely on the `authorize()` call later.
      // However, `permission_handler` can report the status.
      // We only check the base Bluetooth permission status here.
      allRequiredGranted &= statuses[Permission.bluetooth]?.isGranted ?? false;
      _log.info('--- Permission Request Results (iOS) ---');
      _log.info('bluetooth: ${statuses[Permission.bluetooth]}');
      _log.info('---------------------------------');
    }
    // Add checks for other platforms if needed

    // Log permanent denials if any occurred (useful for user guidance)
    statuses.forEach((permission, status) {
      if (status.isPermanentlyDenied) {
        _log.severe(
          '$permission permanently denied. User must enable in settings.',
        );
        // Consider setting a flag or state to guide the user later
        // Optionally: openAppSettings();
      }
    });

    if (!allRequiredGranted) {
      _log.severe('Not all *required* BLE permissions were granted.');
      return false; // Return false as required permissions are missing
    }

    _log.info('Required permissions appear to be granted for this platform.');

    // Authorize with the plugin *after* granting system permissions
    // These calls handle the platform-specific authorization flows (like iOS popups)
    // and confirm the plugin can access the underlying BLE stack.
    try {
      await _centralManager.authorize();
      await _peripheralManager.authorize();
      _log.info('Central and Peripheral managers authorized.');
    } catch (e) {
      _log.severe('Error during plugin authorization: $e');
      // Even if system permissions are granted, plugin authorization might fail
      return false;
    }

    return true; // All required permissions granted and plugin authorized
  }

  /// Start advertising BLE data
  Future<bool> startAdvertising({
    String? name,
    int? manufacturerId,
    Uint8List? manufacturerData,
    bool includeServiceUuid = false,
  }) async {
    if (!_isInitialized) {
      _log.warning('BLE service not initialized');
      return false;
    }

    if (_isAdvertising) {
      // If already advertising, stop first to refresh
      await stopAdvertising();
    }

    // --- Add check for peripheral state ---
    if (_peripheralManager.state != BluetoothLowEnergyState.poweredOn) {
      _log.severe(
        'Cannot start advertising. Peripheral state is not poweredOn (${_peripheralManager.state}).',
      );
      return false;
    }

    try {
      // Create manufacturer specific data if provided
      final List<ManufacturerSpecificData> manufacturerSpecificData =
          (manufacturerId != null && manufacturerData != null)
              ? [
                ManufacturerSpecificData(
                  id: manufacturerId,
                  data: manufacturerData,
                ),
              ]
              : [];

      // Create a UUID for our service
      final serviceUuid = UUID.fromString(_serviceUuid);

      // Create an empty service with no characteristics
      final service = GATTService(
        uuid: serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [],
      );

      // Clear existing services and add our new service
      await _peripheralManager.removeAllServices();
      await _peripheralManager.addService(service);

      // For Android, ensure the device name is short
      final String advertisingName =
          (name != null && name.length > 8)
              ? name.substring(0, 8)
              : (name ?? 'VL');

      // Create advertisement data - optionally include service UUID
      final advertisement = Advertisement(
        name: advertisingName,
        // On Android, sometimes including service UUIDs can cause problems
        // Only include if explicitly requested
        serviceUUIDs: includeServiceUuid ? [serviceUuid] : [],
        manufacturerSpecificData: manufacturerSpecificData,
      );

      // Add logging for advertisement debugging
      _log.info('Starting advertisement with:');
      _log.info('- Name: $advertisingName');
      _log.info('- Include Service UUID: $includeServiceUuid');
      _log.info('- Manufacturer data length: ${manufacturerData?.length ?? 0}');

      // Start advertising
      await _peripheralManager.startAdvertising(advertisement);

      _isAdvertising = true;
      _log.info('Started advertising successfully');
      return true;
    } catch (e) {
      _log.severe('Error starting advertising: $e');
      return false;
    }
  }

  /// Stop BLE advertising
  Future<bool> stopAdvertising() async {
    if (!_isInitialized || !_isAdvertising) {
      return false;
    }

    try {
      await _peripheralManager.stopAdvertising();
      _isAdvertising = false;
      _log.info('Stopped advertising');
      return true;
    } catch (e) {
      _log.severe('Error stopping advertising: $e');
      return false;
    }
  }

  /// Check if device is currently advertising
  Future<bool> isAdvertising() async {
    // Also check the manager's state just in case
    return _isAdvertising &&
        _peripheralManager.state == BluetoothLowEnergyState.poweredOn;
  }

  /// Open app settings to enable Bluetooth
  Future<void> openSettings() async {
    try {
      await _peripheralManager.showAppSettings();
    } catch (e) {
      _log.severe('Error opening settings: $e');
    }
  }
}
