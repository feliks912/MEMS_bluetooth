import 'dart:async';
import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

import 'helpers.dart';

class BluetoothTransaction {
  final Map<String, dynamic> metadata;
  final Map<String, int> characteristicValues;
  final List<SensorData> sensorData;

  const BluetoothTransaction(
      {required this.metadata,
      required this.characteristicValues,
      required this.sensorData});

  Map<String, dynamic> toSembastMap() {
    return {
      "metadata": metadata,
      "characteristic_values": characteristicValues,
      "sensor_data": sensorData,
    };
  }

  factory BluetoothTransaction.fromSembastMap(Map<String, Object?> map) {
    return BluetoothTransaction(
        metadata: map['metadata'] as dynamic,
        characteristicValues: map['characteristic_values'] as Map<String, int>,
        sensorData: map['sensor_data'] as List<SensorData>,
    );
  }
}

class SensorData {
  final int startTime;
  final int lengthTime;
  final int ODR;
  final int lengthData;
  final List<int> rawData;

  //TODO: Use fixnum to create static unsigned integers. For now signed will do.
  const SensorData(
      {required this.startTime,
      required this.lengthTime,
      required this.ODR,
      required this.lengthData,
      required this.rawData});
  
  Map<String, dynamic> toSembastMap() {
    return {
      "start_time": startTime,
      "length_time": lengthTime,
      "ODR": ODR,
      "length_data": lengthData,
      "raw_data": rawData,
    };
  }

  factory SensorData.fromSembastMap(Map<String, Object?> map) {
    return SensorData(
      startTime: map['start_time'] as int,
      lengthTime: map['lengthTime'] as int,
      ODR: map['odr'] as int,
      lengthData: map['length_data'] as int,
      rawData: map['raw_data'] as List<int>,
    );
  }
}

class DatabaseManager {
  static DatabaseManager? _instance;
  static Database? _database;
  final Completer<Database> _dbCompleter = Completer<Database>();
  final StoreRef<Object?, Object?> store = StoreRef.main();

  final StoreRef<String, Map<String, Object?>> characteristicsStateStore = stringMapStoreFactory.store('characteristics_state');
  final StoreRef<int, Map<String, dynamic>> transactionStore = intMapStoreFactory.store('transactions');

  static const int databaseVersion = 1;
  static const String databaseTitle = "Main MEMS Sensor Mobile database";

  factory DatabaseManager() => _instance ??= DatabaseManager._internal();

  DatabaseManager._internal() {
    _initDatabase();
    printWarning("DATABASE: Database manager initialized.");
  }

  Future<Database> get database async {
    return _dbCompleter.future;
  }

  void _initDatabase() async {


    final Directory dbPath;

    try {
      dbPath = await getApplicationDocumentsDirectory();
      printWarning("DATABASE: Fetched application documents directory: ${dbPath.path}");
    } catch(e) {
      printError("DATABASE: Can't get application document path.");
      return;
    }

    final String path = join(dbPath.path, 'sensor_database.db');

    try {
      _database =
          await databaseFactoryIo.openDatabase(path, version: databaseVersion);

      printWarning("DATABASE: Database oppened");

      _dbCompleter.complete(_database);
    } catch (e) {
      _dbCompleter.completeError(e);
      printError("DATABASE: Can't open a database");
    }

    if (_database != null) {
      Object? dbTitle = await store.record('title').get(_database!);
      Object? dbVersion = await store.record('version').get(_database!);

      if (dbTitle == null) {
        await store.record('title').put(_database!, databaseTitle);
        printWarning("DATABASE: Written title to the database.");
      } else {
        printWarning("DATABASE: Title already exists in the database");
      }

      if (dbVersion == null || dbVersion != databaseVersion) {
        await store.record('version').put(_database!, databaseVersion);
        printWarning("DATABASE: Written version to the database.");
      } else {
        printWarning("DATABASE: Version already exists in the database");
      }
    }
  }

  Future<int> updateCharacteristicWithMetadata(String uuid, Map<String, dynamic> char) async {

    // BluetoothCharacteristic can't be written to the database
    // TODO: Make sure characteristic is only read over metadata instead of char before being re-discovered on the next connect.
    char['characteristic'] = null;

    if(_database == null) {
      printError("DATABASE: Can't update characteristic with metadata, _database is null.");
      return 0;
    }

    try {
      await characteristicsStateStore.record(uuid).put(_database!, char);
      printWarning("DATABASE: Updated database characteristic $uuid with new value ${char.toString()}");
      return 1;
    } catch(e) {
      printError("DATABASE: Can't update characteristic with metadata: $e");
    }

    return 0;
  }

  Future<Map<String, Map<String, dynamic>>?> get restoreCharacteristicsWithMetadata async {
    //FIXME: Add await for store snapshot on all getters.

    if(_database == null) {
      printError("DATABASE: Can't restore characteristics with metadata, _database is null.");
      return null;
    }

    try {
      final Map<String, Map<String, dynamic>> returnMap = {};
      final storeSnapshot = await characteristicsStateStore.find(_database!);
      for(final record in storeSnapshot) {
        returnMap[record.key] = record.value;
      }

      printWarning("DATABASE: Restored ${returnMap.length} characteristics from state.");

      return returnMap;

    } catch(e) {
      printError("DATABASE: Can't restore characteristics, $e");
    }

    return null;
  }

  Future<int?> storeTransaction(BluetoothTransaction transaction) async {

    if(_database == null) {
      printError("DATABASE: Can't write transaction, _database is null.");
      return Future.value(null);
    }

    try {
      int? returnKey;
      final storeSnapshot = await transactionStore.find(_database!);
      //FIXME: Switch await for future completer, but for this much data don't bother.
      printWarning("DATABASE: Starting write of transaction to database: ${transaction.toString()}");
      _database!.transaction((txn) async {
        returnKey = await transactionStore.add(txn, transaction.toSembastMap());
      });
      printWarning("DATABASE: Written Transaction to database: ${transaction.toString()}");
      return returnKey;
    } catch(e) {
      printError("DATABASE: Can't write transaction: $e");
      return Future.value(null);
    }
  }

  Future<BluetoothTransaction?> readTransaction(int key) async {

    Map<String, Object?>? transactionMap;

    try {
      Object? tempObject = await transactionStore.record(key).get(_database!);
      if(tempObject == null) {
        printError("DATABASE: Can't read transaction from _database: transaction tempObject is null.");
        return null;
      }
      transactionMap = tempObject as Map<String, Object>;
    } catch (e) {
      printError("DATABASE: Can't read transaction from _database: $e");
      return null;
    }

    BluetoothTransaction tempTransaction = BluetoothTransaction.fromSembastMap(transactionMap);

    printWarning("DATABASE: Successfully read transaction from database: ${tempTransaction.toString()}");

    return tempTransaction;
  }

  Future<bool> databaseWrite(Object key, Object value) async {
    await _dbCompleter.future;

    if (_database == null) {
      printError("DATABASE: Database write error: _database is null");
      return true;
    }

    try {
      await store.record(key).put(_database!, value);
    } catch (e) {
      printError("DATABASE: Database write error: $e");
      return true;
    }
    return false;
  }

  Future<Object?> databaseRead(Object key) async {
    await _dbCompleter.future;

    if (_database == null) {
      printError("DATABASE: Database read error: _database is null");
      return null;
    }

    try {
      return await store.record(key).get(_database!);
    } catch (e) {
      printError("DATABASE: Database read error: $e");
      return null;
    }
  }
}
