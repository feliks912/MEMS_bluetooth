import 'dart:ffi';

import 'package:mems_bluetooth/helpers.dart';

class BluetoothTransaction {
  final Map<String, dynamic> metadata;
  final Map<String, int> characteristicValues;
  final List<SensorData>? sensorData;

  const BluetoothTransaction(
      {required this.metadata,
      required this.characteristicValues,
      required this.sensorData});

  @override
  String toString() {
    // TODO: implement toString
    String metadataString =
        metadata.entries.map((e) => "${e.key}: ${e.value}").join(", ");
    String characteristicValuesString = characteristicValues.entries
        .map((e) => "${e.key}: ${e.value}")
        .join(", ");
    String sensorDataString = sensorData == null
        ? "null"
        : sensorData!.map((e) => e.toString()).join(", ");

    return "BluetoothTransaction(metadata: {$metadataString}, characteristicValues: {$characteristicValuesString}, sensorData: {$sensorDataString})";
  }

  Map<String, dynamic> toSembastMap() {
    return {
      "metadata": metadata,
      "characteristic_values": characteristicValues,
      "sensor_data": sensorData == null
          ? "null"
          : sensorData!.map((element) => element.toSembastMap()).toList(),
    };
  }

  factory BluetoothTransaction.fromSembastMap(Map<String, Object?> map) {
    Map<String, Object?> tempCharMap = <String, Object?>{};
    List<Map<String, dynamic>> tempSensorDataMap = <Map<String, dynamic>>[];

    try {
      tempCharMap = map['characteristic_values'] as Map<String, Object?>;
    } catch (e) {
      printError("TYPES: Can't cast tempCharMap");
    }

    try {
      List<Object?> tempSensorDataList = map['sensor_data'] as List<Object?>;

      try {
        tempSensorDataMap = tempSensorDataList
            .map((element) => element as Map<String, dynamic>)
            .toList();
      } catch (e) {
        printError("TYPES: Can't cast tempSensorDataMap");
      }
    } catch (e) {
      printError("TYPES: Can't cast tempSensorDataList");
    }

    try {
      return BluetoothTransaction(
          metadata: map['metadata'] as dynamic,
          characteristicValues:
              tempCharMap.map((key, value) => MapEntry(key, value as int)),
          sensorData: tempSensorDataMap
              .map((element) => SensorData.fromSembastMap(element))
              .toList());
    } catch (e) {
      printError("TYPES: Can't create BluetoothTransaction: $e");
      return const BluetoothTransaction(
          metadata: {}, characteristicValues: {}, sensorData: []);
    }
  }
}

class SensorData {
  final int timestamp;
  final int dataLength;
  final List<int> rawData;

  //TODO: Use fixnum to create static unsigned integers. For now signed will do.
  const SensorData(
      {required this.timestamp,
      required this.dataLength,
      required this.rawData});

  @override
  String toString() {
    // TODO: implement toString
    return "SensorData(timestamp[ms]: ${timestamp.toString()}, dataLength: ${dataLength.toString()}, rawData: {${rawData.toString()})";
  }

  Map<String, dynamic> toSembastMap() {
    return {
      "timestamp": timestamp,
      "data_length": dataLength,
      "raw_data": rawData,
    };
  }

  static List<SensorData> fromRawSensorDataList(List<int> list) {
    List<SensorData> sensorDataList = [];

    printWarning("Starting data conversion from raw list.");

    if(list.length < 13){
      printError("TYPES: Raw sensor data list contains less than 13 bytes (unix timestamp and one sensor readout). Aborting conversion.");
      return [];
    }
    int previousTimestamp = bytesToIntLE(list.sublist(0, 8)); // First unix timestamp from BLE synchronization. All subsequent timestamps are a delta of time between them and previous timestamp.

    printWarning("First unix timestamp is $previousTimestamp");
    printWarning("Initial raw list length is ${list.length}");

    list = list.sublist(8);
    printWarning("Raw list length with unix timestamp excluded is ${list.length}");

    while (list.length > 5) {
      int timestamp = bytesToIntLE(list.sublist(0, 4)) + previousTimestamp; // 32-bit unsigned int
      printWarning("timestamp: $timestamp");
      int dataLength = bytesToIntLE(list.sublist(4, 5)); // 8-bit unsigned int
      printWarning("dataLength: $dataLength");
      List<int> rawData = list.sublist(5, 5 + dataLength); // List of 8-bit unsigned ints
      printWarning("rawData length: ${rawData.length}");

      SensorData sensorData = SensorData(timestamp: timestamp, dataLength: dataLength, rawData: rawData);
      sensorDataList.add(sensorData);

      previousTimestamp = timestamp;

      list = list.sublist(5 + dataLength);
      printWarning("\nNew raw list length: ${list.length}");

      if (list.isEmpty) break;
    }

    if (list.isNotEmpty) {
      printError(
          "TYPES: Created List<SensorData> from ${sensorDataList.length} sensor events, but ${list.length} elements remain.");
    } else {
      printWarning(
          "TYPES: Created List<SensorData> from ${sensorDataList.length} sensor events.");
    }

    return sensorDataList;
  }

  factory SensorData.fromBytesList(List<int> list, int previousTimestamp) {
    int dataLength = bytesToIntLE(list.sublist(4, 6)) ~/ 2;

    SensorData data = SensorData(
        timestamp: bytesToIntLE(list.sublist(0, 4)) + previousTimestamp,
        dataLength: dataLength,
        rawData: List.generate(dataLength, (index) {
          int startIndex = index * 2;
          try {
            if (startIndex + 1 < dataLength * 2) {
              int firstByte = list[16 + startIndex];
              int secondByte = list[17 + startIndex];
              return bytesToIntLE([firstByte, secondByte]);
            }
            printError(
                "TYPES: Error when converting daa from octets: if statement exited, returning '-1'");
            return -1;
          } catch (e) {
            printError(
                "TYPES: Error when converting sensor data from octets: $e");
            return -1;
          }
        }));
    //printWarning("Created SensorData with ${data.rawData.length} discrete readouts.");
    return data;
  }

  factory SensorData.fromSembastMap(Map<String, Object?> map) {
    return SensorData(
      timestamp: map['timestamp'] as int,
      dataLength: map['data_length'] as int,
      rawData: (map['raw_data'] as Iterable<Object?>?)
              ?.map((element) => element as int)
              .toList() ??
          [],
    );
  }
}
