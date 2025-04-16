import 'dart:collection';
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:yaml/yaml.dart';
import "helpers.dart";
import 'dart:convert';
import 'providers.dart';

class CharacteristicList extends StatefulWidget {
  const CharacteristicList({super.key});

  @override
  State<CharacteristicList> createState() => _CharacteristicListState();
}

class _CharacteristicListState extends State<CharacteristicList> {
  bool _isInitialized = false;

  @override
  void initState() {
    // TODO: implement initState
    super.initState();
  }

  @override
  didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      _isInitialized = true;
    }
  }

  Widget characteristicSelection(
      BLEData bleData, Map<String, dynamic> charWithMeta) {
    int previousNewValue = charWithMeta['new_value'];

    BluetoothCharacteristic char =
        charWithMeta['characteristic'] as BluetoothCharacteristic;
    String uuid = char.uuid.toString();

    if (!char.properties.write) {
      return Column(
        children: [Text(bytesToIntLE(char.lastValue).toString())],
      );
    }

    if (charWithMeta['metadata']['editing'] == null) {
      printError(
          "characteristic is writeable but 'editing' field doesn't exist.");
      return const Text("oops");
    }

    String selectionType = charWithMeta['metadata']['editing'];

    switch (selectionType) {
      case "selection":
        if (charWithMeta['metadata']['selection_options'] == null) {
          printError("editing is 'selection' but selection_options is null");
          return const Text("Error: Missing selection options");
        }

        List<dynamic> dynamicOptions =
            charWithMeta['metadata']['selection_options'] as List<dynamic>;
        List<int> options =
            dynamicOptions.map((option) => option as int).toList();
        List<String> optionsString =
            options.map((option) => option.toString()).toList();

        return DropdownMenu(
          dropdownMenuEntries: optionsString
              .map((option) => DropdownMenuEntry(value: option, label: option))
              .toList(),
          onSelected: (selection) {
            if (selection != null) {
              try {
                bleData.editLocalCharValue(uuid, int.parse(selection));
              } on FormatException catch (e) {
                printError("String to int parsing error in selection: $e");
              }
            }
          },
          initialSelection: previousNewValue.toString(),
        );

      case "checkbox":
        if (charWithMeta['metadata']['data_type'] != 'bool') {
          printError("editing is 'checkbox' but variable isn't bool.");
          return const Text("Error: Wrong char var type.");
        }

        return Checkbox(
            value: previousNewValue == 0 ? false : true,
            onChanged: (state) {
              if (state != null) {
                bleData.editLocalCharValue(uuid, state ? 1 : 0);
              }
            });

      case "write":
        if (charWithMeta['metadata']['range'] == null) {
          printError("Editing is 'write' but 'range' isn't defined.");
          return const Text("Range property missing from 'writing' edit.");
        }

        final TextEditingController textController =
            TextEditingController(text: previousNewValue.toString() ?? '');

        void handleSubmit(String text) {
          printWarning("Entered handleSubmit");

          List<dynamic> rangeOptions =
              charWithMeta['metadata']['range'] as List<dynamic>;
          List<int> rangeOptionsInt =
              rangeOptions.map((option) => option as int).toList();

          if (text.isEmpty) {
            text = charWithMeta['new_value'].toString();
          }

          int? newValue;
          try {
            newValue = int.parse(text);
          } on FormatException catch (e) {
            printError("Parsing text as digits failed: $e");
          }

          if (newValue == null) {
            printError("newValue is null.");
            return;
          }

          if (rangeOptions.length != 2) {
            printError(
                "Characteristic $uuid range option are not 2 values min and max.");
            return;
          }

          if (newValue <= rangeOptionsInt.first) {
            printError("Min allowed value is ${rangeOptionsInt.first}");
            newValue = rangeOptionsInt.first;
          } else if (newValue >= rangeOptionsInt.last) {
            printError("Max allowed value is ${rangeOptionsInt.last}");
            newValue = rangeOptionsInt.last;
          }

          bleData.editLocalCharValue(uuid, newValue);
          printWarning("text input parsed to char value...");
        }

        return TextField(
          controller: textController,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly
          ],
          textAlign: TextAlign.right,
          onSubmitted: ((text) => handleSubmit),
          onTapOutside: ((event) {
            handleSubmit(textController.text);
            FocusScope.of(context).unfocus();
          }),
          onEditingComplete: (() => handleSubmit(textController.text)),
        );

      default:
        printError("No editing property...");
        return const Text("err");
    }
  }

  Widget charList(context, BLEData bleData,
      Map<String, Map<String, dynamic>> charsWithMeta, Color color) {
    return charsWithMeta.isEmpty
        ? const Text("no such characteristics...")
        : Container(
            margin: const EdgeInsets.all(5),
            decoration: BoxDecoration(
                border: Border.all(width: 2, color: color),
                borderRadius: const BorderRadius.all(Radius.circular(10))),
            child: ListView.builder(
                itemCount: charsWithMeta.length,
                itemBuilder: (context, index) {
                  final uuid = charsWithMeta.keys.elementAt(index);
                  final charMetadata =
                      charsWithMeta[uuid]!['metadata'] as Map<String, dynamic>;

                  return Container(
                      margin: const EdgeInsets.symmetric(
                          vertical: 4.0, horizontal: 10.0),
                      decoration: BoxDecoration(
                        border: Border.all(width: 1),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(5)),
                      ),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Padding(
                                padding: const EdgeInsets.fromLTRB(10, 5, 0, 5),
                                child: Column(
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    children: [
                                      Center(child: Text(charMetadata['name'])),
                                      // Center(
                                      //     child:
                                      //         Text(charMetadata['description']))
                                    ])),
                            Flexible(
                              // Use Flexible instead of Expanded
                              child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(0, 5, 10, 5),
                                  child: Column(
                                      // Keep the Column
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        characteristicSelection(
                                            bleData, charsWithMeta[uuid]!)
                                      ])),
                            ),
                          ]));
                }),
          );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BLEData>(builder: (context, bleData, child) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          const Text("Unsynchronized:"),
          Flexible(
            flex: 1,
            child: charList(context, bleData,
                bleData.unsynchronizedCharacteristicsWithMetadata, Colors.red),
          ),
          const Text("Synchronized:"),
          Flexible(
            flex: 1,
            child: charList(context, bleData,
                bleData.synchronizedCharacteristicsWithMetadata, Colors.green),
          )
        ],
      );
    });
  }
}
