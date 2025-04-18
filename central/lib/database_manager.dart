import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'helpers.dart';

class SensorDataClass {
  final double startTime;
  final int usLength;
  final int ODR;
  final int dataLength;
  final List<int> rawData;

  const SensorDataClass(
      {required this.startTime,
      required this.usLength,
      required this.ODR,
      required this.dataLength,
      required this.rawData});
}

class DatabaseManager {
  static Database? _database;
  final Completer<Database> _dbCompleter = Completer<Database>();

  DatabaseManager() {
    _initDatabase();
  }

  Future<Database> get database async {
    return _dbCompleter.future;
  }

  void _initDatabase() async {
    final String path = join(await getDatabasesPath(), 'sensor_database.db');

    try {
      _database = await openDatabase(path);
      _dbCompleter.complete(_database);
    } catch (e) {
      _dbCompleter.completeError(e);
      printError("Can't open a database");
    }
  }



}
