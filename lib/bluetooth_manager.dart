import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mems_bluetooth/types.dart';
import 'dart:async';
import 'dart:io';
import "helpers.dart";
import 'providers.dart';

class BluetoothManager {
  //TODO: Handle stream error values and timeouts with grace.

  static String sensorDataLengthUUID = "0badf00d-cafe-4b1b-9b1b-2c931b1b1b1b";
  static String sensorDataUUID = "c0debabe-face-4f89-b07d-f9d9b20a76c8";
  static String readConfirmationBitUUID =
      "aaaaaaaa-face-4f89-b07d-f9d9b20a76c8";

  StreamSubscription? _rawDataNotificationSubscription;
  List<int> longReadPartialRawSensorDataList = [];
  List<int> rawSensorDataList = [];
  int totalSensorDataLength = 0;
  bool longDataTransferInProgress = false;

  BluetoothCharacteristic? rawSensorDataChar;

  late StreamSubscription _BLEStateStream;
  late StreamSubscription _BLEScanStream;
  StreamSubscription? _BLEConnectionState;
  BluetoothDevice? device;

  int sensorDataMaxChunkSize = 420;

  String? deviceName;
  String? deviceMAC;

  Completer<List<BluetoothService>> _servicesCompleter =
      Completer<List<BluetoothService>>();

  Completer<bool> _rawDataTransferComplete = Completer<bool>();

  bool _isConnecting = false;

  final CharProvider charProvider;

  //Initializing BluetoothManager starts bluetooth
  BluetoothManager(this.deviceMAC, this.deviceName, this.charProvider) {
    FlutterBluePlus.setLogLevel(LogLevel.verbose, color: true);
    _checkBluetooth();
    _initializeBluetooth();
  }

  Future<void> _checkBluetooth() async {
    if (await FlutterBluePlus.isSupported == false) {
      printError(
          "BLUETOOTH_MANAGER: Bluetooth not supported on this platform.");
      exit(1);

      //TODO: Toast placeholder
    }
  }

  Future<StreamSubscription<List<int>>?> subscribeToCharacteristic(
    BluetoothCharacteristic characteristic,
    void Function(List<int>) onDataReceived,
  ) async {
    if (device == null) {
      printError(
          "BLUETOOTH_MANAGER: Can't subscribe to a characteristic, device isn't defined");
      return null;
    }

    if (device!.isDisconnected) {
      printError(
          "BLUETOOTH_MANAGER: Characteristic ${characteristic.uuid} subscription error: device is disconnected");
    }

    final subscription = characteristic.onValueReceived.listen(onDataReceived);

    device!.cancelWhenDisconnected(subscription);

    await characteristic.setNotifyValue(true);

    printWarning(
        "BLUETOOTH_MANAGER: Subscribed to characteristic ${characteristic.uuid}");

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
      printWarning(
          "BLUETOOTH_MANAGER: Current bluetooth state: ${state.toString()}");

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

        printWarning(
            "BLUETOOTH_MANAGER: Clearing rawSensorDataList due to adapter poweroff.");
        rawSensorDataList.clear();

        _servicesCompleter = Completer<List<BluetoothService>>();
        _rawDataTransferComplete = Completer<bool>();

        if (device != null && device!.isConnected) {
          device!.disconnect();

          device = null;

          // charProvider.setDiscoveredCharacteristics = [];
          // charProvider.setDiscoveredServices = [];
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
                  if (FlutterBluePlus.isScanningNow) {
                    try {
                      await FlutterBluePlus.stopScan();
                    } catch (e) {
                      printError(
                          "BLUETOOTH_MANAGER: Can't stop scanning nooooo");
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
        printError(
            "BLUETOOTH_MANAGER: No services discovered on connected device. Attempting reconnect.");
        await device.disconnect();
        await device.connect();
        return;
      }

      List<BluetoothCharacteristic> discoveredCharacteristics = [];

      for (BluetoothService service in services) {
        if (service.characteristics.isEmpty) {
          printError(
              "BLUETOOTH_MANAGER: Service ${service.uuid} doesn't contain any characteristics.");
          continue;
        }

        for (BluetoothCharacteristic char in service.characteristics) {
          discoveredCharacteristics.add(char);
        }
      }

      //FIXME: Add missing character by uuid handling, right now it's empty and we're not even using ornull
      // --- READ SENSOR DATA LENGTH AND SENSOR DATA

      BluetoothCharacteristic? readConfirmationCharacteristic =
          discoveredCharacteristics.firstWhereOrNull(
              (char) => char.uuid.toString() == readConfirmationBitUUID);

      BluetoothCharacteristic? sensorDataLengthChar =
          discoveredCharacteristics.firstWhereOrNull(
              (char) => char.uuid.toString() == sensorDataLengthUUID);

      rawSensorDataChar = discoveredCharacteristics
          .firstWhereOrNull((char) => char.uuid.toString() == sensorDataUUID);

      if (readConfirmationCharacteristic == null) {
        printError(
            "BLUETOOTH_MANAGER: readConfirmationCharacteristic is null!");
        return;
      }

      discoveredCharacteristics.remove(readConfirmationCharacteristic);
      discoveredCharacteristics.remove(rawSensorDataChar);

      void readRawSensorData() async {

        if (sensorDataLengthChar == null) {
          printError("BLUETOOTH_MANAGER: sensorDataLengthChar is null.");
          return;
        }
        if (rawSensorDataChar == null) {
          printError("BLUETOOTH_MANAGER: rawSensorDataChar is null.");
          return;
        }

        try {
          rawSensorDataList.addAll(charProvider.partialRawSensorData); //Load remaining data from previous transaction.
        } catch(e) {
          printError("BLUETOOTH_MANAGER: Can't restore partialRawSensorData from db.");
        }

        int sensorDataLength = bytesToIntLE(await sensorDataLengthChar.read());
        longReadPartialRawSensorDataList.clear();

        if (sensorDataLength >= sensorDataMaxChunkSize) {

          void handleNewRawSensorData(List<int> sensorData) {
            printWarning(
                "BLUETOOTH_MANAGER: Next chunk of raw sensor data received.");

            longReadPartialRawSensorDataList.addAll(sensorData);

            totalSensorDataLength = sensorData.length;

            if (totalSensorDataLength < sensorDataMaxChunkSize) {
              _rawDataNotificationSubscription!.cancel();

              _rawDataTransferComplete.complete(true);

              return;
            }

            try {
              readConfirmationCharacteristic.write([0]);
              //Append partial data to the rawSensorDataList.
              rawSensorDataList.addAll(longReadPartialRawSensorDataList);
              longReadPartialRawSensorDataList.clear();
            } catch(e) {
              printError("BLUETOOTH_MANAGER: Failed to write 0 to readConfirmationCharacteristic. Ack is not sent, not appending data.");
            }
          }

          _rawDataNotificationSubscription = await subscribeToCharacteristic(
              rawSensorDataChar!, handleNewRawSensorData);

          if (_rawDataNotificationSubscription != null) {
            device.cancelWhenDisconnected(_rawDataNotificationSubscription!);
          }

          longDataTransferInProgress = true;

          try {
            await rawSensorDataChar!.read(); // Trigger the first callback.
          } catch (e) {
            printError(
                "BLUETOOTH_MANAGER: Can't read first batch of raw sensor data.");
          }

          return;

        } else {

          try {
            rawSensorDataList.addAll(await rawSensorDataChar!.read());
            _rawDataTransferComplete.complete(true);
          } catch (e) {
            printError(
                "BLUETOOTH_MANAGER: Can't read raw sensor data with length <= sensorDataMaxChunkSize ($sensorDataMaxChunkSize).");
          }
        }
      }

      readRawSensorData();

      printWarning("BLUETOOTH_MANAGER: Waiting for raw data to be read...");
      await _rawDataTransferComplete.future;
      printWarning("BLUETOOTH_MANAGER: All raw data read... Continuing.");

      Map<String, Map<String, dynamic>> tempUnsynchronizedCharacteristics =
          Map<String, Map<String, dynamic>>.of(
              charProvider.unsynchronizedCharacteristicsWithMetadata);

      List<String> writtenUUIDs = [];

      if (charProvider.unsynchronizedCharacteristicsWithMetadata.isNotEmpty) {
        for (BluetoothCharacteristic char in discoveredCharacteristics) {
          if (!char.properties.write) {
            continue;
          }

          String uuid = char.uuid.toString();

          if (charProvider.unsynchronizedCharacteristicsWithMetadata
              .containsKey(uuid)) {
            int newValue =
                charProvider.unsynchronizedCharacteristicsWithMetadata[uuid]![
                    'new_value'] as int;

            printWarning(
                "BLUETOOTH_MANAGER: Writing $newValue to char $uuid, equal to ${intToBytesLE(newValue)} in hex");

            try {
              await char.write(intToBytesLE(newValue));
              writtenUUIDs.add(char.uuid.toString());

              //TODO: Write is successful so we know what the value is, don't read it.
            } catch (e) {
              printError(
                  "BLUETOOTH_MANAGER: Can't write to characteristic $uuid, reason: $e");
            }

            printWarning("BLUETOOTH_MANAGER: Write to $uuid success.");
          }
        }
      }

      //TODO: Exempt those written to from being read.

      if (discoveredCharacteristics.isNotEmpty) {
        await _matchCharsWithMetadata(discoveredCharacteristics,
            writtenUUIDs); //FIXME: Why send tempUnsynchronizedCharacteristics?
      }

      //Write read confirmation characteristic bit
      try {
        await readConfirmationCharacteristic
            .write([1]); // x01 signifies disconnect.

        rawSensorDataList.addAll(longReadPartialRawSensorDataList);
        longReadPartialRawSensorDataList.clear();

        longDataTransferInProgress = false;
        charProvider.setPartialRawSensorData = [];
        printWarning("CHAR_PROVIDER: Data transfer is done and partialRawSensorData has been reset.");

      } catch (e) {
        printError(
            "BLUETOOTH_MANAGER: Can't write to read confirmation characteristic: $e");
      }

      // Complete if
      if (!_servicesCompleter.isCompleted) {
        _servicesCompleter.complete(services);
      }

      BluetoothTransaction newTransaction = BluetoothTransaction(
        metadata: {
          "timestamp": DateTime.now().millisecondsSinceEpoch,
          "updated_characteristics": tempUnsynchronizedCharacteristics
        },
        characteristicValues: charProvider.characteristicsWithMetadata
            .map((key, value) => MapEntry(key, value['new_value'])),
        sensorData: SensorData.fromRawSensorDataList(rawSensorDataList),
      );

      charProvider.addTransactionToDatabase(newTransaction);

      //FIXME: Disconnect should be done from the embedded device to lower overhead etc upon receiving the readConfirmation
      // The only reason that doesn't happen here is Go's library lacks support for connection detection and therefore getting the connected device
      try {
        printWarning("BLUETOOTH_MANAGER: Disconnecting device...");

        await device.disconnect();

        _servicesCompleter = Completer<List<BluetoothService>>();
        _rawDataTransferComplete = Completer<bool>();

        printWarning(
            "BLUETOOTH_MANAGER: Connected devices at disconnect: ${FlutterBluePlus.connectedDevices}");

        printWarning("BLUETOOTH_MANAGER: Device disconnected.");

        //TODO: Implement rescan logic
        _startScan(deviceMAC, deviceName);
      } catch (e) {
        printError(
            "BLUETOOTH_MANAGER: Can't disconnect from device / scan restart error: $e");
      }
    }

    if (state == BluetoothConnectionState.disconnected) {
      printError("BLUETOOTH_MANAGER: DISCONNECTED");

      //TODO: Store remaining data.
      if(longDataTransferInProgress && rawSensorDataList.isNotEmpty) {

        charProvider.storePartialTransferData(rawSensorDataList, totalSensorDataLength);

        printWarning("BLUETOOTH_MANAGER: Stored rawSensorDataList into DataProvider.");
      }

      printWarning(
          "BLUETOOTH_MANAGER: Clearing rawSensorDataList due to disconnect.");
      rawSensorDataList.clear();
    }
  }

  Future<void> _matchCharsWithMetadata(
      List<BluetoothCharacteristic> discoveredCharacteristics,
      List<String> writtenUUIDs) async {
    // Wait for ble_characteristics.json to get processed
    await charProvider.metadataLoadFuture;

    if (charProvider.characteristicMetadata == null ||
        charProvider.characteristicMetadata!.isEmpty) {
      printError(
          "BLUETOOTH_MANAGER: characteristicMetadata in _matchCharsWithMetadata is empty.");
      return;
    }

    Map<String, dynamic> characteristicMetadata =
        charProvider.characteristicMetadata!;

    Map<String, Map<String, dynamic>> tempMap = {};

    characteristicMetadata.forEach((key, value) => printWarning(
        "BLUETOOTH_MANAGER: _matchCharsWithMetadata is processing $key from ble_characteristics.json"));

    for (BluetoothCharacteristic char in discoveredCharacteristics) {
      String uuid = char.uuid.toString();

      if (!characteristicMetadata.containsKey(uuid) || !char.properties.read) {
        continue;
      }

      int? charValue;
      int? newCharValue;

      try {
        //DONE TODO: instead of reading those which have been written, assign them directly.
        //FIXME: Handling write errors outside of this function.
        if (!writtenUUIDs.contains(uuid)) {
          charValue = bytesToIntLE(await char.read());
        } else {
          charValue =
              charProvider.characteristicsWithMetadata[uuid]!['new_value'];
        }
      } catch (e) {
        if (e.runtimeType == FlutterBluePlusException) {
          printError(
              "BLUETOOTH_MANAGER: Read problem: ${(e as FlutterBluePlusException).description}");
        }
      }

      if (charProvider.characteristicsWithMetadata[char.uuid.toString()] !=
          null) {
        newCharValue =
            charProvider.characteristicsWithMetadata[uuid]!['new_value'];
      }

      tempMap[uuid] = {
        "metadata": characteristicMetadata[uuid],
        "characteristic": char,
        "old_value": charValue,
        "new_value": newCharValue ?? charValue
      };
    }

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

    Completer<List<BluetoothService>>();
  }
}
