import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sembast/sembast.dart';
import 'helpers.dart';

import 'database_manager.dart';

class UserData extends ChangeNotifier {}

class CharProvider extends ChangeNotifier {

  bool isRestore = true;

  List<BluetoothTransaction> transactions = [];

  final DatabaseManager databaseManager;

  List<BluetoothService> _discoveredServices = [];
  List<BluetoothCharacteristic> _discoveredCharacteristics = [];

  late Future<void> _metadataLoadFuture;

  Future<void> get metadataLoadFuture => _metadataLoadFuture;

  CharProvider({required this.databaseManager}) {
    _metadataLoadFuture = _loadCharacteristicMetadata();
    _initFromDatabase();
    printWarning("CHAR_PROVIDER: Supposedly initialized characteristics provider...");
  }

  Future<void> _initFromDatabase() async {
    await databaseManager.database; //Wait for the database to initialize

    printWarning("CHAR_PROVIDER: awaited database manager's database object");

    Map<String, Map<String, dynamic>>? tempChars = await databaseManager.restoreCharacteristicsWithMetadata;

    printWarning("CHAR_PROVIDER: awaited database characteristicWithMetadata");

    if(tempChars == null) {
      printError("CHAR_PROVIDER: Can't restore characteristics, database manager returned null.");
      return;
    }

    _characteristicsWithMetadata = tempChars;

    printWarning("CHAR_PROVIDER: set database characteristics with metadata as local.");

    notifyListeners();
  }

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
  Map<String, Map<String, dynamic>> _characteristicsWithMetadata = {};
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

  set databaseAddTransaction(BluetoothTransaction transaction) {
    databaseManager.storeTransaction(transaction);
  }

  set setCharacteristicsWithMetadata(Map<String, Map<String, dynamic>> mds) {
    //TODO: remove old characteristics, ones which don't exist neither in discoveredCharacteristics or characteristicsWithMetadata

    if(mds.isEmpty && isRestore) {
      printError("CHAR_PROVIDER: provided mds are empty and now they should be restored. What now?");
    }

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

        printWarning("CHAR_PROVIDER: Char $uuid is new");

        _synchronizedCharacteristicsWithMetadata[uuid] = md;
      } else {
        //Characteristic with the same uuid already exists.
        // Where will we put the new characteristic?
        if (md['old_value'] == tempNewValues[uuid]) {
          // If the value read is the same as the one we wanted set

          printWarning("CHAR_PROVIDER: Char $uuid synchronized.");

          _synchronizedCharacteristicsWithMetadata[uuid] = md;
          if (_unsynchronizedCharacteristicsWithMetadata.containsKey(uuid)) {
            _unsynchronizedCharacteristicsWithMetadata.remove(uuid);
          } else {
            printError("CHAR_PROVIDER: Error.");
          }
        } else {
          // If the value read is not the one we want set

          printWarning("CHAR_PROVIDER: Char $uuid not synchronized.");

          md['new_value'] = tempNewValues[uuid];
          _unsynchronizedCharacteristicsWithMetadata[uuid] = md;
          if (_synchronizedCharacteristicsWithMetadata.containsKey(uuid)) {
            _synchronizedCharacteristicsWithMetadata.remove(uuid);
          } else {
            printError("CHAR_PROVIDER: Error #2");
          }
        }
      }

      // Only write characteristics if they're getting updated, not if they are restored from the database
      // Which happens at startup
      if( ! isRestore) {
        databaseManager.updateCharacteristicWithMetadata(uuid, md);
        printWarning("CHAR_PROVIDER: Sent characteristics to the database.");
      }
      _characteristicsWithMetadata[uuid] = md;
    }

    isRestore = false;

    printError("""CHAR_PROVIDER: Executing notifyListeners after assigning characteristics...
    CHAR_PROVIDER: Number of characteristics: ${discoveredCharacteristics.length}.
    CHAR_PROVIDER: Number of characteristics with metadata: ${characteristicsWithMetadata.length}.
    CHAR_PROVIDER: Number of synchronized: ${synchronizedCharacteristicsWithMetadata.length}.
    CHAR_PROVIDER: Number of unsynchronized: ${unsynchronizedCharacteristicsWithMetadata.length}""");

    notifyListeners();
  }

  void editLocalCharValue(String uuid, int newValue) {
    if (!_characteristicsWithMetadata.containsKey(uuid)) {
      printError(
          "CHAR_PROVIDER: Can't set new value $newValue to char uuid $uuid because it's not in charsWithMetadata of BLEData provider.");
      return;
    }

    _characteristicsWithMetadata[uuid]!['new_value'] = newValue;
    databaseManager.updateCharacteristicWithMetadata(uuid, _characteristicsWithMetadata[uuid]!);

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

  Future<void> _loadCharacteristicMetadata() async {
    try {
      final dynamic jsonMap = jsonDecode(
          await rootBundle.loadString('assets/ble_characteristics.json'));

      if (jsonMap['characteristic_mappings'] == null) {
        printError(
            "CHAR_PROVIDER: There is no characteristic_mappings key in the ble_configuration.json file.");
      }

      _characteristicMetadata =
          (jsonMap as Map)['characteristic_mappings'] as Map<String, dynamic>;
    } catch (e) {
      printError("CHAR_PROVIDER: Error parsing the json file: $e");
    }
  }
}
