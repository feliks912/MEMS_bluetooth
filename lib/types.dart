import 'package:mems_bluetooth/helpers.dart';

class BluetoothTransaction {
  final Map<String, dynamic> metadata;
  final Map<String, int> characteristicValues;
  final List<SensorData> sensorData;

  const BluetoothTransaction(
      {required this.metadata,
      required this.characteristicValues,
      required this.sensorData});

  @override
  String toString() {
    // TODO: implement toString
    String metadataString = metadata.entries.map((e) => "${e.key}: ${e.value}").join(", ");
    String characteristicValuesString = characteristicValues.entries.map((e) => "${e.key}: ${e.value}").join(", ");
    String sensorDataString = sensorData.map((e) => e.toString()).join(", ");

    return "BluetoothTransaction(metadata: {$metadataString}, characteristicValues: {$characteristicValuesString}, sensorData: {$sensorDataString})";
  }
  
  Map<String, dynamic> toSembastMap() {
    return {
      "metadata": metadata,
      "characteristic_values": characteristicValues,
      "sensor_data": sensorData.map((element) => element.toSembastMap()).toList(),
    };
  }

  factory BluetoothTransaction.fromSembastMap(Map<String, Object?> map) {

    Map<String, Object?> tempCharMap = <String, Object?>{};
    List<Map<String, dynamic>> tempSensorDataMap = <Map<String, dynamic>>[];

    try {
      tempCharMap = map['characteristic_values'] as Map<String, Object?>;
    } catch(e) {
      printError("TYPES: Can't cast tempCharMap");
    }

    try {
      List<Object?> tempSensorDataList = map['sensor_data'] as List<Object?>;

      try {
        tempSensorDataMap = tempSensorDataList.map((element) => element as Map<String, dynamic>).toList();
      } catch(e) {
        printError("TYPES: Can't cast tempSensorDataMap");
      }

    } catch(e) {
      printError("TYPES: Can't cast tempSensorDataList");
    }

    try {
      return BluetoothTransaction(
        metadata: map['metadata'] as dynamic,
        characteristicValues: tempCharMap.map((key, value) => MapEntry(key, value as int)),
        sensorData: tempSensorDataMap.map((element) => SensorData.fromSembastMap(element)).toList()
      );
    } catch(e) {
      printError("TYPES: Can't create BluetoothTransaction: $e");
      return const BluetoothTransaction(metadata: {}, characteristicValues: {}, sensorData: []);
    }
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

  @override
  String toString() {
    // TODO: implement toString
    return "SensorData(startTime: ${startTime.toString()}, lengthTime: ${lengthTime.toString()}, ODR: ${ODR.toString()}, lengthData: ${lengthData.toString()}, rawData: {${rawData.toString()})";
  }

  Map<String, dynamic> toSembastMap() {
    return {
      "start_time": startTime,
      "length_time": lengthTime,
      "ODR": ODR,
      "length_data": lengthData,
      "raw_data": rawData,
    };
  }

  static List<SensorData> fromRawSensorDataList(List<int> list) {

    List<SensorData> sensorDataList = [];
    while(list.length > 16) {
      SensorData sensorData = SensorData.fromBytesList(list);
      sensorDataList.add(sensorData);
      list = list.sublist(sensorData.lengthData * 2 + 16); //lengthData is for int, this are raw bytes
      if(list.isNotEmpty) break;
    }
    //printWarning("Created List<SensorData> from ${sensorDataList.length} sensor events.");
    return sensorDataList;
  }

  factory SensorData.fromBytesList(List<int> list) {
    int dataLength = bytesToIntLE(list.sublist(14, 16)) ~/ 2;

    SensorData data = SensorData(
        startTime: bytesToIntLE(list.sublist(0, 8)),
        lengthTime: bytesToIntLE(list.sublist(8, 12)),
        ODR: bytesToIntLE(list.sublist(12, 14)),
        lengthData: dataLength,
        rawData: List.generate(dataLength , (index) {
          int startIndex = index * 2;
          if(startIndex + 1 < dataLength) {
            return bytesToIntLE([list[16 + startIndex], list[17 + startIndex]]);
          }
          printError("TYPES: Error when converting sensor data from octets.");
          return -1;
        }));
    //printWarning("Created SensorData with ${data.rawData.length} discrete readouts.");
    return data;
  }

  factory SensorData.fromSembastMap(Map<String, Object?> map) {
    return SensorData(
      startTime: map['start_time'] as int,
      lengthTime: map['length_time'] as int,
      ODR: map['ODR'] as int,
      lengthData: map['length_data'] as int,
      rawData: (map['raw_data'] as Iterable<Object?>?)?.map((element) => element as int).toList() ?? [],
    );
  }
}
