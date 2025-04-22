import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mems_bluetooth/providers.dart';
import 'package:provider/provider.dart';
import '../helpers.dart';
import '../types.dart';

class TransactionList extends StatefulWidget {
  const TransactionList({super.key});

  @override
  State<StatefulWidget> createState() => _TransactionListState();
}

class _TransactionListState extends State<TransactionList> {

  Widget transactionList(CharProvider charProvider) {
    return charProvider.transactions.isEmpty ? const Text(
        "no transactions yet.") :
    Container(
      margin: const EdgeInsets.all(5),
      decoration: BoxDecoration(
          border: Border.all(width: 2),
          borderRadius: const BorderRadius.all(Radius.circular(10))),
      child: ListView.builder(
          itemCount: charProvider.transactions.length,
          itemBuilder: (context, index) {

            Color borderColor = Colors.green;

            List<BluetoothTransaction> transactions = charProvider.transactions;

            return InkWell(
              onTap: () {
                printWarning(transactions[index].toString());
              },
                child:
              Container(
                margin: const EdgeInsets.symmetric(
                    vertical: 4.0, horizontal: 10.0),
                decoration: BoxDecoration(
                  border: Border.all(width: 1),
                  borderRadius:
                  const BorderRadius.all(Radius.circular(5)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Text(transactions[index].metadata['timestamp'].toString()),
                    Text("Events: ${transactions[index].sensorData.length}")
                  ],
                ),
            ));
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    // TODO: implement build
    return Consumer<CharProvider>(builder: (context, charData, child) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Expanded(child: transactionList(charData)),
        ],
      );
    });
  }
}