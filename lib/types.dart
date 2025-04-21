import 'package:mems_bluetooth/helpers.dart';

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

  static List<SensorData> fromRawSensorDataList(List<int> list) {
    List<SensorData> sensorDataList = [];
    while(list.length > 16) {
      SensorData sensorData = SensorData.fromBytesList(list);
      sensorDataList.add(sensorData);
      list = list.sublist(sensorData.lengthData + 16);
      if(list.isNotEmpty) break;
    }
    return sensorDataList;
  }

  factory SensorData.fromBytesList(List<int> list) {
    int dataLength = bytesToIntLE(list.sublist(14, 16));

    return SensorData(
        startTime: bytesToIntLE(list.sublist(0, 8)),
        lengthTime: bytesToIntLE(list.sublist(8, 12)),
        ODR: bytesToIntLE(list.sublist(12, 14)),
        lengthData: dataLength,
        rawData: List.generate(dataLength ~/ 2, (index) {
          int startIndex = index * 2;
          if(startIndex + 1 < list.sublist(16).length) {
            return bytesToIntLE([list[16 + startIndex], list[17 + startIndex]]);
          }
          printError("TYPES: Error when converting sensor data from octets.");
          return -1;
        }));
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
