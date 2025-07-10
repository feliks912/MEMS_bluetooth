import 'dart:async';

import 'package:mems_bluetooth/widgets/transaction_list.dart';

import 'database_manager.dart';
import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';
import "bluetooth_manager.dart";
import "widgets/characteristic_list.dart";
import 'package:provider/provider.dart';
import 'providers.dart';

Future<void> main() async {
  const String deviceName = "MEMS_Bluetooth";
  const String deviceMAC = "80:32:53:74:15:A7";

  WidgetsFlutterBinding.ensureInitialized();

  final DatabaseManager databaseManager = DatabaseManager();

  await databaseManager.database; //Ensure db is initialized.

  final charProvider = CharProvider(databaseManager: databaseManager);

  final BluetoothManager BLEManager = BluetoothManager(
      null,//deviceMAC,
      deviceName,
      charProvider
  );

  runApp(MultiProvider(providers: [
    Provider(create: (context) => UserData()),
    ChangeNotifierProvider(create: (context) => charProvider)
  ], child: MyApp(BLEManager: BLEManager)));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.BLEManager});

  final BluetoothManager BLEManager;

  @override
  Widget build(BuildContext context) {
    return ToastificationWrapper(
        child: MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: MyHomePage(title: 'MEMS Sensor app', BLEManager: BLEManager),
    ));
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title, required this.BLEManager});

  final BluetoothManager BLEManager;

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  void initState() {
    // TODO: implement initState
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _createToast() {
    toastification.show(
      type: ToastificationType.error,
      style: ToastificationStyle.flat,
      title: const Text("Bluetooth unsupported."),
      description: const Text(
        "Bluetooth Low Energy is a requirement for this application.",
      ),
      alignment: Alignment.bottomCenter,
      autoCloseDuration: const Duration(seconds: 4),
      borderRadius: BorderRadius.circular(12.0),
      closeOnClick: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CharProvider>(builder: (context, bleData, child) {
      return DefaultTabController(
          length: 2,
          child: Scaffold(
              appBar: AppBar(
                backgroundColor: Theme.of(context).colorScheme.inversePrimary,
                title: Text(widget.title),
              ),
              bottomNavigationBar: const TabBar(tabs: [
                Tab(icon: Icon(Icons.abc)),
                Tab(icon: Icon(Icons.directions_transit)),
              ]),
              body: TabBarView(children: [
                TransactionList(BLEManager: widget.BLEManager),
                // Center(
                //     child: Column(
                //         mainAxisAlignment: MainAxisAlignment.center,
                //         children: [
                //       AspectRatio(
                //           aspectRatio: 2.0,
                //           child: LineChart(
                //             LineChartData(
                //               lineBarsData: [
                //                 LineChartBarData(
                //                   color: Colors.redAccent,
                //                   spots: const [
                //                     FlSpot(1, 1),
                //                     FlSpot(2, 3),
                //                     FlSpot(3, 2),
                //                   ],
                //                   isCurved: true,
                //                   preventCurveOverShooting: true,
                //                   belowBarData: BarAreaData(
                //                       show: true, color: Colors.greenAccent),
                //                   dotData: const FlDotData(
                //                     show: false,
                //                   ),
                //                   barWidth: 3,
                //                   dashArray: [3, 4],
                //                 ),
                //               ],
                //               maxX: 0,
                //               minX: 4,
                //             ),
                //           )),
                //     ])),
                // bleData.characteristicsWithMetadata.isEmpty
                //     ? const Center(child: Text("Getting services..."))
                //     : const CharacteristicList(),
                CharacteristicList()
              ])));
    });

    Consumer<CharProvider>(
      builder: (context, bleData, child) {
        // floatingActionButton: Column(
        //   mainAxisAlignment: MainAxisAlignment.end,
        //   children: [
        //     Container(
        //       margin: const EdgeInsets.all(10),
        //       child: FloatingActionButton(
        //         onPressed: _incrementCounter,
        //         tooltip: 'Increment',
        //         child: const Icon(Icons.add),
        //       ),
        //     ),
        //     FloatingActionButton(
        //       onPressed: _createToast,
        //       tooltip: 'toast',
        //       child: const Icon(Icons.notification_add),
        //     )
        //   ],
        // ), // This trailing comma makes auto-formatting nicer for build methods.
      },
    );
  }
}
