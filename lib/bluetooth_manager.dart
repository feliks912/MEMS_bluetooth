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

  static const String sensorDataLengthUUID = "0badf00d-cafe-4b1b-9b1b-2c931b1b1b1b";
  static const String sensorDataUUID = "c0debabe-face-4f89-b07d-f9d9b20a76c8";
  static const String flashClearDisconnectBitUUID =
      "cabba6ee-c0de-4414-a6f6-46a397e18422";
  static const String unixTimeSynchronizationUUID =
      "c0dec0fe-cafe-a1ca-992f-1b1b1b1b1b1b";
  static const String sensorDataReadConfirmUUID = "0badf00d-babe-47f5-b542-bbfd9b436872";

  static const int BT_LONG_TRANSFER_SIZE_BYTES_MAX = 500;

  List<int> longReadPartialRawSensorDataList = [];
  List<int> rawSensorDataList = [];
  int totalSensorDataLength = 0;
  bool longDataTransferInProgress = false;

  BluetoothCharacteristic? rawSensorDataChar;

  late StreamSubscription _BLEStateStream;
  late StreamSubscription _BLEScanStream;
  StreamSubscription? _BLEConnectionState;
  StreamSubscription? _BLEBondState;
  BluetoothDevice? device;

  static const int sensorDataMaxChunkSize = 420;
  int sensorDataLength = 0;
  static const int sensorDataLengthThreshold =
      0; //TODO: set threshold for initiating connection
  static const int MANUFACTURER_ID = 0xFFFF;

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
    if (FlutterBluePlus.isScanningNow) {
      FlutterBluePlus.stopScan();
      printWarning("BLUETOOTH_MANAGER: Stopped scanning");
    }

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
      FlutterBluePlus.startScan(androidScanMode: AndroidScanMode.lowLatency);
      printError(
          "BLUETOOTH_MANAGER: Device name and Device MAC not provided, scanning w/o filter.");
    }
  }

  void manuallyStartScan() {
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on &&
        FlutterBluePlus.connectedDevices.isEmpty &&
        FlutterBluePlus.isScanningNow == false) {
      _startScan(deviceMAC, deviceName);
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

    //FlutterBluePlus.cancelWhenScanComplete(_BLEScanStream);
  }

  void _handleScanResults(List<ScanResult> results) async {
    printWarning("BLUETOOTH_MANAGER: Scan callback");

    //print(results);

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
        if (FlutterBluePlus.isScanningNow) {
          FlutterBluePlus.stopScan();
          printWarning("BLUETOOTH_MANAGER: Stopped scanning");
        }

        if (result.advertisementData.manufacturerData.isEmpty) {
          printError(
              "BLUETOOTH_MANAGER: Device manufacturer data is empty. Aborting and restarting scan.");
          return;
        } else if (result.advertisementData.manufacturerData[MANUFACTURER_ID] ==
            null) {
          printError(
              "BLUETOOTH_MANAGER: Device manufacturer data under key $MANUFACTURER_ID doesn't exist. Aborting.");
        } else {
          printWarning(
              "BLUETOOTH_MANAGER: DEVICE MANUFACTURER DATA: ${result.advertisementData.manufacturerData}");

          List<int> manuList =
              result.advertisementData.manufacturerData[MANUFACTURER_ID]!;

          if (manuList.length != 3) {
            printError(
                "BLUETOOTH_MANAGER: Device manufacturer data list length is ${manuList.length} != 3. Aborting.");
            return;
          }

          sensorDataLength = bytesToIntLE(manuList.sublist(1, 2));
          printWarning(
              "BLUETOOTH_MANAGER: Sensor reports sensor data length of $sensorDataLength in manufacturer data.");

          if (manuList[0] == 1 &&
              sensorDataLength < sensorDataLengthThreshold) {
            printError(
                "BLUETOOTH_MANAGER: Sensor has been initialized but length $sensorDataLength of sensor data is less than threshold $sensorDataLengthThreshold. Aborting.");
            return;
          }
        }

        printWarning("BLUETOOTH_MANAGER: Entered if");
        device = result.device;

        //FIXME: Race condition - device can be reset to null if
        if (device!.isDisconnected) {
          _BLEConnectionState ??=
              device!.connectionState.listen((BluetoothConnectionState state) {
            _deviceConnectionStateChange(device!, state);
          });

          void connect() async {
            if (!_isConnecting) {
              _isConnecting = true;
              try {
                _BLEBondState =
                    device!.bondState.listen((BluetoothBondState state) {
                  printWarning(
                      "BLUETOOTH_MANAGER: Bond state changed. New bond state: $state");
                });
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

          //Attempt connection
          connect();
        }
      }
    }

    printWarning("BLUETOOTH_MANAGER: Scan callback out");
  }

  void _deviceConnectionStateChange(
      BluetoothDevice device, BluetoothConnectionState state) async {
    if (state == BluetoothConnectionState.connected) {
      _isConnecting = false;
      printWarning("BLUETOOTH_MANAGER: Device is connected.");

      //We must re-discover all services on each re-connect
      List<BluetoothService> services = await device.discoverServices();
      List<BluetoothCharacteristic> discoveredCharacteristics = [];

      if (services.isEmpty) {
        printError(
            "BLUETOOTH_MANAGER: No services discovered on connected device. Attempting reconnect.");
        await device.disconnect();
        return;
      }

      for (BluetoothService service in services) {
        if (service.uuid.toString() == "1801" ||
            service.uuid.toString() == "1800") {
          printError(
              "BLUETOOTH_MANAGER: Skipping generic service ${service.uuid}.");
          continue;
        }

        if (service.characteristics.isEmpty) {
          printError(
              "BLUETOOTH_MANAGER: Service ${service.uuid} doesn't contain any characteristics.");
          continue;
        }

        discoveredCharacteristics.addAll(service.characteristics);
      }

      BluetoothCharacteristic? sensorDataLengthChar;
      BluetoothCharacteristic? sensorDataChar;
      BluetoothCharacteristic? sensorDataReadConfirmChar;
      BluetoothCharacteristic? flashClearDisconnectChar;
      BluetoothCharacteristic? unixTimeSynchronizationChar;

      for (final char in discoveredCharacteristics) {
        if (char.uuid.toString() == sensorDataLengthUUID) {
          sensorDataLengthChar = char;
        } else if (char.uuid.toString() == sensorDataUUID) {
          sensorDataChar = char;
        } else if (char.uuid.toString() == flashClearDisconnectBitUUID) {
          flashClearDisconnectChar = char;
        } else if (char.uuid.toString() == unixTimeSynchronizationUUID) {
          unixTimeSynchronizationChar = char;
        } else if (char.uuid.toString() == sensorDataReadConfirmUUID) {
          sensorDataReadConfirmChar = char;
        }

        if (sensorDataLengthChar != null &&
            sensorDataChar != null &&
            flashClearDisconnectChar != null &&
            unixTimeSynchronizationChar != null &&
            sensorDataReadConfirmChar != null) {
          break;
        }
      }

      if (sensorDataLengthChar != null) {
        discoveredCharacteristics.remove(sensorDataLengthChar);
      } else {
        printError("BLUETOOTH_MANAGER: sensorDataLengthChar is null");
        await device.disconnect();
        return;
      }

      if(sensorDataReadConfirmChar != null) {
        discoveredCharacteristics.remove(sensorDataReadConfirmChar);
      } else {
        printError("BLUETOOTH_MANAGER: sensorDataReadConfirmChar is null");
        await device.disconnect();
        return;
      }

      if (sensorDataChar != null) {
        discoveredCharacteristics.remove(sensorDataChar);
      } else {
        printError("BLUETOOTH_MANAGER: sensorDataChar is null");
        await device.disconnect();
        return;
      }

      if (flashClearDisconnectChar != null) {
        discoveredCharacteristics.remove(flashClearDisconnectChar);
      } else {
        printError("BLUETOOTH_MANAGER: flashClearDisconnectChar is null");
        await device.disconnect();
        return;
      }

      if (unixTimeSynchronizationChar != null) {
        discoveredCharacteristics.remove(unixTimeSynchronizationChar);
      } else {
        printError("BLUETOOTH_MANAGER: unixTimeSynchronizationChar is null.");
        await device.disconnect();
        return;
      }

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
                "BLUETOOTH_MANAGER: Writing new value $newValue to char $uuid, equal to ${intToBytesLE(newValue)} in hex");

            //FIXME: Int to bytes truncates the int, so value determines the file list which must be constant and is checked on the SoC.
            try {
              await char.write(intToBytesLE(newValue));
              writtenUUIDs.add(char.uuid.toString());
            } catch (e) {
              printError(
                  "BLUETOOTH_MANAGER: Can't write to characteristic $uuid, reason: $e");
              await device.disconnect();
              return;
            }

            printWarning("BLUETOOTH_MANAGER: Write to $uuid success.");
          }
        }
      }

      // TODO: configuration characteristics s
      // Read unwritten characteristics (might have changed)
      for (BluetoothCharacteristic char in discoveredCharacteristics) {
        await char.read();
        printWarning(
            "BLUETOOTH_MANAGER: Characteristic ${char.uuid.toString()} read. Value is ${bytesToIntLE(char.lastValue)}");
      }

      int sensorDataLength = bytesToIntLE(await sensorDataLengthChar.read());

      List<SensorData> sensorDataList = [];
      List<int> sensorDataRawList = [];

      if (bytesToIntLE(sensorDataLengthChar.lastValue) >=
          sensorDataLengthThreshold) {
        try {
          await sensorDataChar.read();

          int dataReadLength = sensorDataChar.lastValue.length;
          printWarning("BLUETOOTH_MANAGER: First sensor data raw length is $dataReadLength.");

          sensorDataRawList.addAll(sensorDataChar.lastValue);
          printError(bytesToHexString(sensorDataChar.lastValue));

          while(dataReadLength >= BT_LONG_TRANSFER_SIZE_BYTES_MAX) {
            await sensorDataReadConfirmChar.write(intToBytesLEPadded(dataReadLength, 2));

            await sensorDataChar.read();

            sensorDataRawList.addAll(sensorDataChar.lastValue);
            printError(bytesToHexString(sensorDataChar.lastValue));

            dataReadLength = sensorDataChar.lastValue.length;

            printWarning("BLUETOOTH_MANAGER: Consequent sensor data raw length is $dataReadLength.");
          }

        } catch (e) {
          printError("BLUETOOTH_MANAGER: sensor data read exception: $e");
        }
      }

      printWarning("BLUETOOTH_MANAGER: Total sensor data raw length is ${sensorDataRawList.length}");

      int unixTime = DateTime.timestamp().millisecondsSinceEpoch;
      printWarning(
          "Sending unix miliseconds $unixTime to peripheral. Looking like ${intToBytesLEPadded(unixTime, 8)}");
      await unixTimeSynchronizationChar.write(intToBytesLEPadded(unixTime, 8));

      //FIXME: First get the sensor data, then report back the size.
      try{
        await flashClearDisconnectChar.write(
            intToBytesLEPadded(sensorDataList!.length, 2));
      } catch(e) {
        printWarning("Device terminated connection before flashClearDisconnectChar write confirmation has been received. Exception $e");
      }


      if (sensorDataChar.lastValue.isEmpty) {
        printError("BLUETOOTH_MANAGER: Sensor data characteristic is empty.");
      } else {
        sensorDataList =
            SensorData.fromRawSensorDataList(sensorDataRawList);

        if (sensorDataList.length != sensorDataLength) {
          printError(
              "BLUETOOTH_MANAGER: Sensor data list's length doesn't match its reported length. Extracted ${sensorDataList.length} elements, but $sensorDataLength are reported from the sensor.");
        }
      }

      sleep(const Duration(milliseconds: 500));

      if (device.isConnected) {
        printError("BLUETOOTH_MANAGER: Disconnecting device...");
        device.disconnect();
      }

      if (discoveredCharacteristics.isNotEmpty) {
        await _matchCharsWithMetadata(discoveredCharacteristics, writtenUUIDs);
      }

      BluetoothTransaction newTransaction = BluetoothTransaction(
        metadata: {
          "timestamp": DateTime.now().millisecondsSinceEpoch,
          "updated_characteristics": tempUnsynchronizedCharacteristics
        },
        characteristicValues:
            charProvider.characteristicsWithMetadata.map((key, value) {
          printWarning("BLUETOOTH_MANAGER: processing uuid ${key.toString()}");
          return MapEntry(key, value['new_value']);
        }),
        sensorData:
            sensorDataList, //FIXME: Replace this? Data is in the characteristic.
      );

      charProvider.addTransactionToDatabase(newTransaction);
    }

    if (state == BluetoothConnectionState.disconnected) {
      printError(
          "BLUETOOTH_MANAGER: state changed to DISCONNECTED. Starting scan.");
      //_startScan(deviceMAC, deviceName);
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

    for (BluetoothCharacteristic char in discoveredCharacteristics) {
      String uuid = char.uuid.toString();

      printWarning(
          "BLUETOOTH_MANAGER: _matchCharsWithMetadata is processing $uuid from ble_characteristics.json");

      if (!characteristicMetadata.containsKey(uuid) || !char.properties.read) {
        printError("Skipping characteristic $uuid in matchCharsWithMetadata.");
        continue;
      }

      int? charValue;
      int? newCharValue;

      try {
        if (writtenUUIDs.contains(uuid)) {
          charValue =
              charProvider.characteristicsWithMetadata[uuid]!['new_value'];
        } else {
          charValue = bytesToIntLE(char.lastValue);
        }
        printWarning("Char value: $charValue");
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

    for (String key in tempMap.keys) {
      Map<String, dynamic> entry = tempMap[key]!;

      printWarning(
          "tempMap uuid $key new value is ${entry["new_value"].toString()}");
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
