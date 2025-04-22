import 'dart:ffi';


void printWarning(String text) {
  bool indent = false;
  final pattern = new RegExp('.{1,1000}'); // 800 is the size of each chunk
  pattern.allMatches(text).forEach((match) {
    print("${indent ? "### " : ""}\x1B[33m${match.group(0)}\x1B[0m");
    indent = true;
  });
}

void printError(String text) {
  bool indent = false;
  final pattern = new RegExp('.{1,1000}'); // 800 is the size of each chunk
  pattern.allMatches(text).forEach((match) {
    print("${indent ? "### " : ""}\x1B[31m${match.group(0)}\x1B[0m");
    indent = true;
  });
}

int bytesToIntLE(List<int> bytes) {
  int value = 0;
  for(int i = 0; i < bytes.length; i++) {
    value |= (bytes[i] & 0xFF) << (i*8);
  }
  return value;
}

List<int> intToBytesLE(int value) {

  List<int> bytes = [];

  if(value == 0) {
    return [0];
  }

  int size = 0;

  if(value < 0) {
    size = 8;
  } else {
    int tempValue = value;

    while(tempValue > 0) {
      tempValue >>= 8;
      size++;
    }
  }

  for(int i = 0; i < size; i++) {
    bytes.add((value >> (i * 8)) & 0xFF);
  }

  return bytes;
}