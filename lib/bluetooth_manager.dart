import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mems_bluetooth/types.dart';
import 'dart:async';
import 'dart:io';
import "helpers.dart";
import 'providers.dart';

class BluetoothManager {
  //TODO: Handle stream error values and timeouts with grace.

  static String sensorDataUUID = "c0debabe-face-4f89-b07d-f9d9b20a76c8";
  static String readConfirmationBitUUID = "aaaaaaaa-face-4f89-b07d-f9d9b20a76c8";

  late BluetoothCharacteristic rawSensorDataChar;

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
      printError("BLUETOOTH_MANAGER: Can't subscribe to a characteristic, device isn't defined");
      return null;
    }

    if (device!.isDisconnected) {
      printError(
          "BLUETOOTH_MANAGER: Characteristic ${characteristic.uuid} subscription error: device is disconnected");
    }

    final subscription = characteristic.onValueReceived.listen(onDataReceived);

    device!.cancelWhenDisconnected(subscription);

    await characteristic.setNotifyValue(true);

    printWarning("BLUETOOTH_MANAGER: Subscribed to characteristic ${characteristic.uuid}");

    return Future.value(subscription);
  }

  // Future<List<BluetoothService>> getServices() async {
  //   if (charProvider.discoveredServices.isNotEmpty) {
  //     return charProvider.discoveredServices;
  //   }
  //   return _servicesCompleter.future;
  // }

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
          "BLUETOOTH_MANAGER: Device name and Device MAC not provided, what do I scan for?");
    }
  }

  void _initializeBluetooth() {
    _BLEStateStream =
        FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
      printWarning("BLUETOOTH_MANAGER: Current bluetooth state: ${state.toString()}");

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
          printError("BLUETOOTH_MANAGER: Cant start scanning: $e");
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

          // charProvider.setDiscoveredCharacteristics = [];
          // charProvider.setDiscoveredServices = [];

          _servicesCompleter = Completer<List<BluetoothService>>();
        }
      }
    });

    //FIXME: Multiple devices with equal names will all have this ran for.
    _BLEScanStream = FlutterBluePlus.onScanResults.listen(_handleScanResults);

    //FlutterBluePlus.cancelWhe nScanComplete(_BLEScanStream);
  }

  void _handleScanResults(List<ScanResult> results) async {
    printWarning("BLUETOOTH_MANAGER: Scan callback");

    if (results.isEmpty) {
      printWarning("BLUETOOTH_MANAGER: Results are empty.");
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
      BLUETOOTH_MANAGER: matchesMAC: $matchesMAC,
      BLUETOOTH_MANAGER: matchesName: $matchesName,
      BLUETOOTH_MANAGER: isNotConnected: $isNotConnected""");

      if ((matchesMAC || matchesName) && isNotConnected) {
        printWarning("BLUETOOTH_MANAGER: Entered if");
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
                      printError("BLUETOOTH_MANAGER: Can't stop scanning nooooo");
                    }
                  }
                  _isConnecting = false;
                } else {
                  printError(
                      "BLUETOOTH_MANAGER: Connect returned true but device isn't connected?");
                }
              } catch (e) {
                _isConnecting = false;
                printError("BLUETOOTH_MANAGER: Connecting attempt failed!");
                connect();
              }
            }
          }

          connect();

          //Attempt connection
        }
      }
    }

    printWarning("BLUETOOTH_MANAGER: Scan callback out");
  }

  void _handleDeviceConnectionStateChange(
      BluetoothDevice device, BluetoothConnectionState state) async {
    //We must re-discover all services on each re-connect
    if (state == BluetoothConnectionState.connected) {
      _isConnecting = false;

      printWarning("BLUETOOTH_MANAGER: Device is connected yayyyy");

      //If freshly connected, discover services right away
      List<BluetoothService> services = await device.discoverServices();

      if (services.isEmpty) {
        //TODO: Handle empty services
        printError("BLUETOOTH_MANAGER: No services discovered on connected device.");
        return;
      }

      // charProvider.setDiscoveredServices = services;


      List<BluetoothCharacteristic> tempCharList = [];

      for (BluetoothService service in services) {
        if (service.characteristics.isNotEmpty) {
          for (BluetoothCharacteristic char in service.characteristics) {
            tempCharList.add(char);
          }
        } else {
          printError(
              "BLUETOOTH_MANAGER: Service ${service.uuid} doesn't contain any characteristics.");
        }
      }

      Map<String, Map<String, dynamic>> tempUnsynchronizedCharacteristics = Map<String, Map<String, dynamic>>.of(charProvider.unsynchronizedCharacteristicsWithMetadata);

      if (charProvider.unsynchronizedCharacteristicsWithMetadata.isNotEmpty) {
        for (BluetoothCharacteristic char in tempCharList) {

          String uuid = char.uuid.toString();

          if (charProvider.unsynchronizedCharacteristicsWithMetadata
              .containsKey(uuid)) {

            int newValue = charProvider.unsynchronizedCharacteristicsWithMetadata[
            uuid]!['new_value'] as int;

            printWarning("BLUETOOTH_MANAGER: Writing $newValue to char $uuid, equal to ${intToBytesLE(newValue)} in hex");

            try {
              await char.write(intToBytesLE(newValue));
            } catch (e) {
              printError(
                  "BLUETOOTH_MANAGER: Can't write to characteristic $uuid, reason: $e");
            }

            printWarning("BLUETOOTH_MANAGER: Write success.");
          }
        }
      };

      BluetoothCharacteristic readConfirmationCharacteristic =
          tempCharList.firstWhere((char) =>
              char.uuid.toString() == readConfirmationBitUUID);

      tempCharList.remove(readConfirmationCharacteristic);


      if(tempCharList.any((char) =>
      char.uuid.toString() == sensorDataUUID)) {
        rawSensorDataChar = tempCharList.firstWhere((char) =>
        char.uuid.toString() == sensorDataUUID);

        rawSensorDataChar.read();

        tempCharList.remove(rawSensorDataChar);
      }

      //TODO: Selectively read characteristics instead of reading them all to match metadata
      //TODO: Also implement local database
      if (tempCharList.isNotEmpty) {
        // charProvider.setDiscoveredCharacteristics = tempCharList;
        await _matchCharsWithMetadata(tempCharList, tempUnsynchronizedCharacteristics);
      }

      if (!_servicesCompleter.isCompleted) {
        _servicesCompleter.complete(services);
      }

      //Write read confirmation characteristic bit
      try {
        await readConfirmationCharacteristic.write([1]);
      } catch (e) {
        printError("BLUETOOTH_MANAGER: Can't write to read confirmation characteristic: $e");
      }

      //FIXME: Disconnect should be done from the embedded device to lower overhead etc upon receiving the readConfirmation
      // The only reason that doesn't happen here is Go's library lacks support for connection detection and therefore getting the connected device
      try {
        printWarning("BLUETOOTH_MANAGER: Disconnecting device...");

        await device.disconnect();

        // charProvider.setDiscoveredCharacteristics = [];
        // charProvider.setDiscoveredServices = [];

        _servicesCompleter = Completer<List<BluetoothService>>();

        printWarning(
            "BLUETOOTH_MANAGER: Connected devices at disconnect: ${FlutterBluePlus.connectedDevices}");

        printWarning("BLUETOOTH_MANAGER: Device disconnected.");

        _startScan(deviceMAC, deviceName);

      } catch (e) {
        printError("BLUETOOTH_MANAGER: Can't disconnect from device: $e");
      }
    }

    if (state == BluetoothConnectionState.disconnected) {
      printError("BLUETOOTH_MANAGER: DISCONNECTED");

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
      printError("BLUETOOTH_MANAGER: Bluetooth not supported on this platform.");
      exit(1);

      //TODO: Toast placeholder
    }
  }

  Future<void> _matchCharsWithMetadata(
      List<BluetoothCharacteristic> characteristics, Map<String, Map<String, dynamic>> tempUnsynchronizedCharacteristics) async {
    await charProvider.metadataLoadFuture;

    if (charProvider.characteristicMetadata == null ||
        charProvider.characteristicMetadata!.isEmpty) {
      return;
    }

    Map<String, dynamic> characteristicMetadata =
        charProvider.characteristicMetadata!;

    Map<String, Map<String, dynamic>> tempMap = {};

    for (String key in characteristicMetadata.keys) {
      printError("BLUETOOTH_MANAGER: Key is $key");
    }

    for (BluetoothCharacteristic char in characteristics) {
      if (characteristicMetadata.containsKey(char.uuid.toString()) &&
          char.properties.read) {
        try {
          //TODO: instead of reading, assign to the existing metadata?
          await char.read();
        } catch (e) {
          if (e.runtimeType == FlutterBluePlusException) {
            printError(
                "BLUETOOTH_MANAGER: Read problem: ${(e as FlutterBluePlusException).description}");
          }
        }


        int charValue = bytesToIntLE(char.lastValue);
        int? newCharValue;

        if(charProvider.characteristicsWithMetadata[char.uuid.toString()] != null) {
          newCharValue = charProvider.characteristicsWithMetadata[char.uuid.toString()]!['new_value'];
        }

        tempMap[char.uuid.toString()] = {
          "metadata": characteristicMetadata[char.uuid.toString()],
          "characteristic": char,
          "old_value": charValue,
          "new_value": newCharValue ?? charValue
        };
      }
    }

    BluetoothTransaction newTransaction = BluetoothTransaction(
        metadata: {
          "timestamp": DateTime.now().toString(),
          "updated_characteristics": tempUnsynchronizedCharacteristics
        },
        characteristicValues: tempMap.map((key, value) => MapEntry(key, value['new_value'])),
        sensorData: SensorData.fromRawSensorDataList(rawSensorDataChar.lastValue),
    );

    charProvider.addTransactionToDatabase(newTransaction);

    charProvider.setCharacteristicsWithMetadata = tempMap;
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

    // charProvider.setDiscoveredCharacteristics = [];
    // charProvider.setDiscoveredServices = [];

    Completer<List<BluetoothService>>();
  }
}
