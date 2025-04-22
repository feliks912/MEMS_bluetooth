import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sembast/sembast.dart';
import 'helpers.dart';
import 'types.dart';

import 'database_manager.dart';

class UserData extends ChangeNotifier {}

class CharProvider extends ChangeNotifier {

  bool isRestore = true;

  final DatabaseManager databaseManager;

  final List<BluetoothTransaction> _transactions = [];
  List<BluetoothTransaction> get transactions => _transactions;

  set setTransactions(List<BluetoothTransaction> transactions) {
    _transactions.addAll(transactions);
    notifyListeners();
  }
  
  // List<BluetoothService> _discoveredServices = [];
  // List<BluetoothCharacteristic> _discoveredCharacteristics = [];

  late Future<void> _metadataLoadFuture;

  Future<void> get metadataLoadFuture => _metadataLoadFuture;

  CharProvider({required this.databaseManager}) {
    _metadataLoadFuture = _loadCharacteristicMetadata();
    _initFromDatabase();
    printWarning("CHAR_PROVIDER: Supposedly initialized characteristics provider...");
  }

  Future<void> _initFromDatabase() async {
    await databaseManager.database; //Wait for the database to initialize

    printWarning("CHAR_PROVIDER: Awaited database manager's database object");

    Map<String, Map<String, dynamic>>? tempChars = await databaseManager.restoreCharacteristicsWithMetadata;

    printWarning("CHAR_PROVIDER: Awaited database characteristicWithMetadata");

    if(tempChars == null) {
      printError("CHAR_PROVIDER: Can't restore characteristics, database manager returned null.");
      return;
    }

    setCharacteristicsWithMetadata = tempChars;

    printWarning("CHAR_PROVIDER: Set ${tempChars.length} database characteristics with metadata as local.");

    printWarning("CHAR_PROVIDER: Restoring transactions...");

    setTransactions = await databaseManager.restoreTransactions() ?? [];

    notifyListeners();
  }

  // List<BluetoothService> get discoveredServices => _discoveredServices;
  //
  // List<BluetoothCharacteristic> get discoveredCharacteristics =>
  //     _discoveredCharacteristics;
  //
  // set setDiscoveredServices(List<BluetoothService> services) {
  //   _discoveredServices = services;
  //   notifyListeners();
  // }
  //
  // set setDiscoveredCharacteristics(List<BluetoothCharacteristic> chars) {
  //   _discoveredCharacteristics = chars;
  //   notifyListeners();
  // }

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

    //FIXME: This part needs to be adjusted - on restore there is no md['characteristics']
    for (String uuid in mds.keys) {

      if ( ! _characteristicsWithMetadata.containsKey(uuid)) {
        // New characteristic discovered, add it

        printWarning("CHAR_PROVIDER: Char $uuid is new");

        _synchronizedCharacteristicsWithMetadata[uuid] = mds[uuid]!;
      } else {
        //Characteristic with the same uuid already exists.
        // Where will we put the new characteristic?
        if (mds[uuid]!['old_value'] == mds[uuid]!['new_value']) {
          // If the value read is the same as the one we wanted set

          printWarning("CHAR_PROVIDER: Char $uuid synchronized.");

          _synchronizedCharacteristicsWithMetadata[uuid] = mds[uuid]!;
          if (_unsynchronizedCharacteristicsWithMetadata.containsKey(uuid)) {
            _unsynchronizedCharacteristicsWithMetadata.remove(uuid);
          }
        } else {
          // If the value read is not the one we want set

          printWarning("CHAR_PROVIDER: Char $uuid not synchronized.");

          _unsynchronizedCharacteristicsWithMetadata[uuid] = mds[uuid]!;
          if (_synchronizedCharacteristicsWithMetadata.containsKey(uuid)) {
            _synchronizedCharacteristicsWithMetadata.remove(uuid);
          }
        }
      }

      // Only write characteristics if they're getting updated, not if they are restored from the database
      // Which happens at startup
      if( ! isRestore) {
        databaseManager.updateCharacteristicWithMetadata(uuid, mds[uuid]!);
        printWarning("CHAR_PROVIDER: Sent characteristics to the database.");
      }
      _characteristicsWithMetadata[uuid] = Map<String, dynamic>.from(mds[uuid]!);
    }

    if(isRestore) {
      isRestore = false;
      printWarning("CHAR_PROVIDER: Set isRestore bit to false.");
    }


    printError("""
    CHAR_PROVIDER: Executing notifyListeners after assigning characteristics...
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

    //FIXME: A temporary solution for somewhere else assigning an immutable map to the _characteristicsWithMetadata
    Map<String, dynamic> tempChar = Map<String, dynamic>.from(_characteristicsWithMetadata[uuid]!);
    tempChar['new_value'] = newValue;
    _characteristicsWithMetadata[uuid] = tempChar;
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

  void addTransactionToDatabase(BluetoothTransaction transaction) async {
    await databaseManager.storeTransaction(transaction);
    _transactions.add(transaction);
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
