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
  for (int i = 0; i < bytes.length; i++) {
    value |= (bytes[i] & 0xFF) << (i * 8);
  }
  return value;
}

List<int> intToBytesLE(int value) {
  List<int> bytes = [];

  if (value == 0) {
    return [0];
  }

  int size = 0;

  if (value < 0) {
    size = 8;
  } else {
    int tempValue = value;

    while (tempValue > 0) {
      tempValue >>= 8;
      size++;
    }
  }

  for (int i = 0; i < size; i++) {
    bytes.add((value >> (i * 8)) & 0xFF);
  }

  return bytes;
}

List<int> intToBytesLEPadded(int value, int paddedSize){
  if (paddedSize <= 0) {
    throw ArgumentError('paddedSize must be a positive integer.');
  }

  List<int> bytes = [];

  for (int i = 0; i < paddedSize; i++) {
    bytes.add((value >> (i * 8)) & 0xFF);
  }

  return bytes;
}


String bytesToHexString(List<int> bytes) {
  if (bytes.isEmpty) {
    return "";
  }

  // Use a StringBuffer for efficient string concatenation
  final buffer = StringBuffer();
  for (int i = 0; i < bytes.length; i++) {
    // Ensure the byte is treated as unsigned and format as two hex digits
    // padLeft(2, '0') ensures "A" becomes "0A"
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));

    // Add a space for readability, except after the last byte
    if (i < bytes.length - 1) {
      buffer.write(' ');
    }
  }
  return buffer.toString().toLowerCase(); // Convert to uppercase for A-F hex digits
}