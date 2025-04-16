import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'dart:io';
import "helpers.dart";
import 'providers.dart';

class BluetoothManager {
  //TODO: Handle stream error values and timeouts with grace.

  late StreamSubscription _BLEStateStream;
  late StreamSubscription _BLEScanStream;
  late StreamSubscription _BLEConnectionState;
  late BluetoothDevice device;
  final String deviceName;
  final Completer<List<BluetoothService>> _servicesCompleter =
      Completer<List<BluetoothService>>();

  final BLEData bleData;

  //Initializing BluetoothManager starts bluetooth
  BluetoothManager(this.deviceName, this.bleData) {
    FlutterBluePlus.setLogLevel(LogLevel.verbose, color: true);
    _checkBluetooth();
    _initializeBluetooth();
  }

  Future<StreamSubscription<List<int>>> subscribeToCharacteristic(
    BluetoothCharacteristic characteristic,
    void Function(List<int>) onDataReceived,
  ) async {
    if (device.isDisconnected) {
      printError(
          "Characteristic ${characteristic.uuid} subscription error: device is disconnected");
    }

    final subscription = characteristic.onValueReceived.listen(onDataReceived);
    device.cancelWhenDisconnected(subscription);
    await characteristic.setNotifyValue(true);

    printWarning("Subscribed to characteristic ${characteristic.uuid}");

    return Future.value(subscription);
  }

  Future<List<BluetoothService>> getServices() async {
    if (bleData.discoveredServices.isNotEmpty) {
      return bleData.discoveredServices;
    }
    return _servicesCompleter.future;
  }

  void _startScan(String deviceName) {
    FlutterBluePlus.startScan(
      androidScanMode: AndroidScanMode.lowLatency,
      withNames: [deviceName],
      //removeIfGone: const Duration(seconds: 3),
      //oneByOne: true,
    );
  }

  void _initializeBluetooth() {
    _BLEStateStream =
        FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
      printWarning("Current bluetooth state: ${state.toString()}");

      if (state == BluetoothAdapterState.off) {
        //Request BLE turn on from the user (Android only?)s
        if (!kIsWeb && Platform.isAndroid) {
          FlutterBluePlus.turnOn();
        } else {
          //TODO: Platform doesn't support turning on Bluetooth. Ask the user to turn on manually.
        }
      }

      if (state == BluetoothAdapterState.on) {
        try {
          _startScan(deviceName);
        } catch (e) {
          printError("Cant start scanning: $e");
        }
      }
    });

    //FIXME: Multiple devices with equal names will all have this ran for.
    _BLEScanStream =
        FlutterBluePlus.onScanResults.listen((List<ScanResult> results) {
      printWarning("Scan callback");
      for (ScanResult result in results) {
        if (result.device.advName == deviceName &&
            !FlutterBluePlus.connectedDevices
                .any((element) => element.advName == deviceName)) {
          device = result.device;

          if (device.isDisconnected) {
            //FIXME: Do we need this here?
            _BLEConnectionState =
                device.connectionState.listen((BluetoothConnectionState state) {
              _handleDeviceConnectionStateChange(device, state);
            });

            //Attempt connection
            device.connect(
              timeout: const Duration(seconds: 5),
              mtu: 512,
            );
          }
        } else {
          printError("No devices found by scanning?");
        }
      }
      printWarning("Scan callback out");
    });

    //FlutterBluePlus.cancelWhenScanComplete(_BLEScanStream);
  }

  void _handleDeviceConnectionStateChange(
      BluetoothDevice device, BluetoothConnectionState state) async {
    //We must re-discover all services on each re-connect
    if (state == BluetoothConnectionState.connected) {
      printWarning("Device is connected yayyyy");

      //If freshly connected, discover services right away
      List<BluetoothService> services = await device.discoverServices();

      if (services.isEmpty) {
        //TODO: Handle empty services
        printError("No services discovered on connected device.");
        return;
      }

      bleData.setDiscoveredServices = services;
      if (!_servicesCompleter.isCompleted) {
        _servicesCompleter.complete(services);
      }

      List<BluetoothCharacteristic> tempCharList = [];

      for (BluetoothService service in bleData.discoveredServices) {
        if (service.characteristics.isNotEmpty) {
          for (BluetoothCharacteristic char in service.characteristics) {
            tempCharList.add(char);
          }
        } else {
          printError(
              "Service ${service.uuid} doesn't contain any characteristics.");
        }
      }

      if (bleData.unsynchronizedCharacteristicsWithMetadata.isNotEmpty) {
        for (BluetoothCharacteristic char in tempCharList) {
          if (bleData.unsynchronizedCharacteristicsWithMetadata
              .containsKey(char.uuid.toString())) {
            int newValue = bleData.unsynchronizedCharacteristicsWithMetadata[
                char.uuid.toString()]!['new_value'] as int;

            printWarning("Writing $newValue to char ${char.uuid.toString()}");

            try {
              await char.write(intToBytesLE(newValue));
            } catch (e) {
              printError(
                  "Can't write to characteristic ${char.uuid.toString()}, reason: $e");
            }

            printWarning("Write success.");
          }
        }
      }

      String readConfirmationCharacteristicUUID =
          "aaaaaaaa-face-4f89-b07d-f9d9b20a76c8";

      BluetoothCharacteristic readConfirmationCharacteristic =
          tempCharList.firstWhere((char) =>
              char.uuid.toString() == readConfirmationCharacteristicUUID);

      tempCharList.remove(readConfirmationCharacteristic);

      //TODO: Selectively read characteristics instead of reading them all to match metadata
      //TODO: Also implement local database
      if (tempCharList.isNotEmpty) {
        bleData.setDiscoveredCharacteristics = tempCharList;
        await _matchCharsWithMetadata(tempCharList);
      }

      //Write read confirmation characteristic bit
      try {
        await readConfirmationCharacteristic.write([1]);
      } catch (e) {
        printError("Can't write to read confirmation characteristic: $e");
      }

      //FIXME: Disconnect should be done from the embedded device to lower overhead etc upon receiving the readConfirmation
      // The only reason that doesn't happen here is Go's library lacks support for connection detection and therefore getting the connected device
      try {
        device.disconnect(queue: true);
      } catch (e) {
        printError("Can't disconnect from device: $e");
      }
    }

    if (state == BluetoothConnectionState.disconnected) {
      //FIXME: Sounds too easy to be true
      _BLEConnectionState.cancel();

      //FIXME: It seems we can't restart / reconnect after a disconnect without re-scanning?
      // probably a FBP bug???
      await FlutterBluePlus.stopScan();
      _startScan(deviceName);
    }
  }

  Future<void> _checkBluetooth() async {
    if (await FlutterBluePlus.isSupported == false) {
      printError("Bluetooth not supported on this platform.");
      exit(1);

      //TODO: Toast placeholder
    }
  }

  Future<void> _matchCharsWithMetadata(
      List<BluetoothCharacteristic> discoveredCharacteristics) async {
    await bleData.metadataLoadFuture;

    if (bleData.characteristicMetadata != null &&
        bleData.characteristicMetadata!.isNotEmpty) {
      Map<String, dynamic> characteristicMetadata =
          bleData.characteristicMetadata!;

      Map<String, Map<String, dynamic>> tempMap = {};

      for (String key in characteristicMetadata.keys) {
        printError("Key is $key");
      }

      for (BluetoothCharacteristic char in discoveredCharacteristics) {
        if (characteristicMetadata.containsKey(char.uuid.toString()) &&
            char.properties.read) {
          try {
            await char.read();
          } catch (e) {
            if (e.runtimeType == FlutterBluePlusException) {
              printError(
                  "read problem: ${(e as FlutterBluePlusException).description}");
            }
          }

          int charValue = bytesToIntLE(char.lastValue);

          tempMap[char.uuid.toString()] = {
            "metadata": characteristicMetadata[char.uuid.toString()],
            "characteristic": char,
            "old_value": charValue,
            "new_value": charValue
          };
        }
      }

      bleData.setCharacteristicsWithMetadata = tempMap;
    }
  }

  Future<void> dispose() async {
    await _BLEStateStream.cancel();
    await _BLEScanStream.cancel();
    await _BLEConnectionState.cancel();
    await device.disconnect();
  }
}
