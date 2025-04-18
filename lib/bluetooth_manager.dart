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
  StreamSubscription? _BLEConnectionState;
  BluetoothDevice? device;

  String? deviceName;
  String? deviceMAC;

  Completer<List<BluetoothService>> _servicesCompleter =
      Completer<List<BluetoothService>>();

  bool _isConnecting = false;

  final CharProvider charProvider;

  //Initializing BluetoothManager starts bluetooth
  BluetoothManager(this.deviceMAC, this.deviceName, this.charProvider) {
    FlutterBluePlus.setLogLevel(LogLevel.verbose, color: true);
    _checkBluetooth();
    _initializeBluetooth();
  }

  Future<StreamSubscription<List<int>>?> subscribeToCharacteristic(
    BluetoothCharacteristic characteristic,
    void Function(List<int>) onDataReceived,
  ) async {
    if (device == null) {
      printError("Can't subscribe to a characteristic, device isn't defined");
      return null;
    }

    if (device!.isDisconnected) {
      printError(
          "Characteristic ${characteristic.uuid} subscription error: device is disconnected");
    }

    final subscription = characteristic.onValueReceived.listen(onDataReceived);

    device!.cancelWhenDisconnected(subscription);

    await characteristic.setNotifyValue(true);

    printWarning("Subscribed to characteristic ${characteristic.uuid}");

    return Future.value(subscription);
  }

  Future<List<BluetoothService>> getServices() async {
    if (charProvider.discoveredServices.isNotEmpty) {
      return charProvider.discoveredServices;
    }
    return _servicesCompleter.future;
  }

  void _startScan(String? deviceMAC, String? deviceName) {
    if (deviceMAC != null) {
      FlutterBluePlus.startScan(
        withRemoteIds: [deviceMAC],
        androidScanMode: AndroidScanMode.lowLatency,
        //withNames: [deviceName],
        //removeIfGone: const Duration(seconds: 3),
        //oneByOne: true,
      );
    } else if (deviceName != null) {
      FlutterBluePlus.startScan(
        //withRemoteIds: ["80:32:53:74:15:A7"],
        androidScanMode: AndroidScanMode.lowLatency,
        withNames: [deviceName],
        //removeIfGone: const Duration(seconds: 3),
        //oneByOne: true,
      );
    } else {
      printError(
          "Device name and Device MAC not provided, what do I scan for?");
    }
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
          _startScan(deviceMAC, deviceName);
        } catch (e) {
          printError("Cant start scanning: $e");
        }
      }

      if (state == BluetoothAdapterState.turningOff) {
        _BLEStateStream.cancel();
        _BLEScanStream.cancel();

        if (_BLEConnectionState != null) {
          _BLEConnectionState!.cancel();
          _BLEConnectionState = null;
        }

        if (device != null && device!.isConnected) {
          device!.disconnect();

          device = null;

          charProvider.setDiscoveredCharacteristics = [];
          charProvider.setDiscoveredServices = [];

          _servicesCompleter = Completer<List<BluetoothService>>();
        }
      }
    });

    //FIXME: Multiple devices with equal names will all have this ran for.
    _BLEScanStream = FlutterBluePlus.onScanResults.listen(_handleScanResults);

    //FlutterBluePlus.cancelWhe nScanComplete(_BLEScanStream);
  }

  void _handleScanResults(List<ScanResult> results) async {
    printWarning("Scan callback");

    if (results.isEmpty) {
      printWarning("Results are empty.");
      return;
    }

    //FIXME: This can be some other device if name is not unique
    //TODO: Add MAC address filtration after the first connect

    for (ScanResult result in results) {
      final matchesMAC =
          deviceMAC != null && result.device.remoteId.toString() == deviceMAC;
      final matchesName =
          deviceName != null && result.device.advName == deviceName;
      final isNotConnected = !FlutterBluePlus.connectedDevices
          .any((device) => device.remoteId == result.device.remoteId);

      printWarning("""
      matchesMAC: $matchesMAC,
      matchesName: $matchesName,
      isNotConnected: $isNotConnected""");

      if ((matchesMAC || matchesName) && isNotConnected) {
        printWarning("Entered if");
        device = result.device;

        // if (FlutterBluePlus.isScanningNow) {
        //   FlutterBluePlus.stopScan();
        //   printWarning("Stopped scanning");
        // }

        //FIXME: Race condition - device can be reset to null if
        if (device!.isDisconnected) {
          if (_BLEConnectionState == null) {
            _BLEConnectionState = device!.connectionState
                .listen((BluetoothConnectionState state) {
              _handleDeviceConnectionStateChange(device!, state);
            });
          }

          void connect() async {
            if (!_isConnecting) {
              _isConnecting = true;
              try {
                await device!.connect(
                  timeout: const Duration(seconds: 5),
                  mtu: 512,
                );
                if (device!.isConnected) {
                  if(FlutterBluePlus.isScanningNow) {
                    try {
                      await FlutterBluePlus.stopScan();
                    } catch (e) {
                      printError("Can't stop scanning nooooo");
                    }
                  }
                  _isConnecting = false;
                } else {
                  printError(
                      "Connect returned true but device isn't connected?");
                }
              } catch (e) {
                _isConnecting = false;
                printError("connecting attempt failed!");
                connect();
              }
            }
          }

          connect();

          //Attempt connection
        }
      }
    }

    printWarning("Scan callback out");
  }

  void _handleDeviceConnectionStateChange(
      BluetoothDevice device, BluetoothConnectionState state) async {
    //We must re-discover all services on each re-connect
    if (state == BluetoothConnectionState.connected) {
      _isConnecting = false;

      printWarning("Device is connected yayyyy");

      //If freshly connected, discover services right away
      List<BluetoothService> services = await device.discoverServices();

      if (services.isEmpty) {
        //TODO: Handle empty services
        printError("No services discovered on connected device.");
        return;
      }

      charProvider.setDiscoveredServices = services;
      if (!_servicesCompleter.isCompleted) {
        _servicesCompleter.complete(services);
      }

      List<BluetoothCharacteristic> tempCharList = [];

      for (BluetoothService service in charProvider.discoveredServices) {
        if (service.characteristics.isNotEmpty) {
          for (BluetoothCharacteristic char in service.characteristics) {
            tempCharList.add(char);
          }
        } else {
          printError(
              "Service ${service.uuid} doesn't contain any characteristics.");
        }
      }

      if (charProvider.unsynchronizedCharacteristicsWithMetadata.isNotEmpty) {
        for (BluetoothCharacteristic char in tempCharList) {
          if (charProvider.unsynchronizedCharacteristicsWithMetadata
              .containsKey(char.uuid.toString())) {
            int newValue = charProvider.unsynchronizedCharacteristicsWithMetadata[
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
        charProvider.setDiscoveredCharacteristics = tempCharList;
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
        printWarning("Disconnecting device...");

        await device.disconnect();

        charProvider.setDiscoveredCharacteristics = [];
        charProvider.setDiscoveredServices = [];

        _servicesCompleter = Completer<List<BluetoothService>>();

        printWarning(
            "Connected devices at disconnect: ${FlutterBluePlus.connectedDevices}");

        printWarning("Device disconnected.");

        _startScan(deviceMAC, deviceName);

      } catch (e) {
        printError("Can't disconnect from device: $e");
      }
    }

    if (state == BluetoothConnectionState.disconnected) {
      printError("DISCONNECTED");

      // //FIXME: It seems we can't restart / reconnect after a disconnect without re-scanning?
      // // probably a FBP bug???
      // if(FlutterBluePlus.isScanningNow) {
      //   printWarning("Restarting scan but it's scanning...");
      // }
      // await FlutterBluePlus.stopScan();
      // _BLEScanStream.resume();
      // _startScan(deviceMAC, deviceName);
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
    await charProvider.metadataLoadFuture;

    if (charProvider.characteristicMetadata != null &&
        charProvider.characteristicMetadata!.isNotEmpty) {
      Map<String, dynamic> characteristicMetadata =
          charProvider.characteristicMetadata!;

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

      charProvider.setCharacteristicsWithMetadata = tempMap;
    }
  }

  Future<void> dispose() async {
    await _BLEStateStream.cancel();
    await _BLEScanStream.cancel();

    if (_BLEConnectionState != null) {
      await _BLEConnectionState!.cancel();
      _BLEConnectionState = null;
    }

    if (device != null && device!.isConnected) {
      device!.disconnect();
      device = null;
    }

    charProvider.setDiscoveredCharacteristics = [];
    charProvider.setDiscoveredServices = [];

    Completer<List<BluetoothService>>();
  }
}
