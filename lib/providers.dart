import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'helpers.dart';

import 'database_manager.dart';

class UserData extends ChangeNotifier {}


class SensorData extends ChangeNotifier {
  List<SensorDataClass>? sensorData;
}

class CharProvider extends ChangeNotifier {
  List<BluetoothService> _discoveredServices = [];
  List<BluetoothCharacteristic> _discoveredCharacteristics = [];

  List<BluetoothService> get discoveredServices => _discoveredServices;

  List<BluetoothCharacteristic> get discoveredCharacteristics =>
      _discoveredCharacteristics;

  set setDiscoveredServices(List<BluetoothService> services) {
    _discoveredServices = services;
    notifyListeners();
  }

  set setDiscoveredCharacteristics(List<BluetoothCharacteristic> chars) {
    _discoveredCharacteristics = chars;
    notifyListeners();
  }

  Map<String, dynamic>? _characteristicMetadata;
  final Map<String, Map<String, dynamic>> _characteristicsWithMetadata = {};
  final Map<String, Map<String, dynamic>>
      _unsynchronizedCharacteristicsWithMetadata = {};
  final Map<String, Map<String, dynamic>>
      _synchronizedCharacteristicsWithMetadata = {};

  Map<String, dynamic>? get characteristicMetadata => _characteristicMetadata;

  Map<String, Map<String, dynamic>> get characteristicsWithMetadata =>
      _characteristicsWithMetadata;

  Map<String, Map<String, dynamic>>
      get unsynchronizedCharacteristicsWithMetadata =>
          _unsynchronizedCharacteristicsWithMetadata;

  Map<String, Map<String, dynamic>>
      get synchronizedCharacteristicsWithMetadata =>
          _synchronizedCharacteristicsWithMetadata;

  set setCharacteristicsWithMetadata(Map<String, Map<String, dynamic>> mds) {
    //TODO: remove old characteristics, ones which don't exist neither in discoveredCharacteristics or characteristicsWithMetadata

    // Save values we wanted written into old characteristics
    Map<String, int> tempNewValues =
        _characteristicsWithMetadata.map((key, value) {
      return MapEntry(key, value['new_value'] as int);
    });

    for (Map<String, dynamic> md in mds.values) {
      BluetoothCharacteristic char =
          md['characteristic'] as BluetoothCharacteristic;
      String uuid = char.uuid.toString();

      if (!tempNewValues.containsKey(uuid)) {
        // New characteristic discovered, add it

        printWarning("char $uuid is new");

        _synchronizedCharacteristicsWithMetadata[uuid] = md;
      } else {
        //Characteristic with the same uuid already exists.
        // Where will we put the new characteristic?
        if (md['old_value'] == tempNewValues[uuid]) {
          // If the value read is the same as the one we wanted set

          printWarning("char $uuid synchronized.");

          _synchronizedCharacteristicsWithMetadata[uuid] = md;
          if (_unsynchronizedCharacteristicsWithMetadata.containsKey(uuid)) {
            _unsynchronizedCharacteristicsWithMetadata.remove(uuid);
          } else {
            printError("error.");
          }
        } else {
          // If the value read is not the one we want set

          printWarning("char $uuid not synchronized.");

          md['new_value'] = tempNewValues[uuid];
          _unsynchronizedCharacteristicsWithMetadata[uuid] = md;
          if (_synchronizedCharacteristicsWithMetadata.containsKey(uuid)) {
            _synchronizedCharacteristicsWithMetadata.remove(uuid);
          } else {
            printError("error #2");
          }
        }
      }
      _characteristicsWithMetadata[uuid] = md;
    }

    printError("""Executing notifyListeners after assigning characteristics...
    Number of characteristics: ${discoveredCharacteristics.length}.
    Number of characteristics with metadata: ${characteristicsWithMetadata.length}.
    Number of synchronized: ${synchronizedCharacteristicsWithMetadata.length}.
    Number of unsynchronized: ${unsynchronizedCharacteristicsWithMetadata.length}""");

    notifyListeners();
  }

  void editLocalCharValue(String uuid, int newValue) {
    if (!_characteristicsWithMetadata.containsKey(uuid)) {
      printError(
          "Can set new value $newValue to char uuid $uuid because it's not in charsWithMetadata of BLEData provider.");
      return;
    }

    _characteristicsWithMetadata[uuid]!['new_value'] = newValue;

    if (_characteristicsWithMetadata[uuid]!['old_value'] == newValue) {
      _synchronizedCharacteristicsWithMetadata
          .addAll({uuid: _characteristicsWithMetadata[uuid]!});
      _unsynchronizedCharacteristicsWithMetadata.remove(uuid);
    } else {
      //The value differs
      _unsynchronizedCharacteristicsWithMetadata
          .addAll({uuid: _characteristicsWithMetadata[uuid]!});
      _synchronizedCharacteristicsWithMetadata.remove(uuid);
    }

    notifyListeners();
  }

  late Future<void> _metadataLoadFuture;

  Future<void> get metadataLoadFuture => _metadataLoadFuture;

  CharProvider() {
    _metadataLoadFuture = _loadCharacteristicMetadata();
  }

  Future<void> _loadCharacteristicMetadata() async {
    try {
      final dynamic jsonMap = jsonDecode(
          await rootBundle.loadString('assets/ble_characteristics.json'));

      if (jsonMap['characteristic_mappings'] == null) {
        printError(
            "There is no characteristic_mappings key in the ble_configuration.json file.");
      }

      _characteristicMetadata =
          (jsonMap as Map)['characteristic_mappings'] as Map<String, dynamic>;
    } catch (e) {
      printError("Error parsing the yaml file: $e");
    }
  }
}
