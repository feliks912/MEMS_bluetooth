# mems_bluetooth

Communication app for ultra low power MEMS Bluetooth module.

## General notes

#FIXME:
* Moving a variable to unsynchronized characteristics doesn't persist the uncategorized state on reboot. The variable goes back to the synchronized section with the to-be-set value displayed as set already. Something about new_value == old_value somewhere on changing the states of the variable.
* I assign an immutable map at some point to discoveredCharacteristics, probably during restoring them from the database. This breaks changing variables. Bad state: read only. Tried making a deep copy in providers.dart:179 but broke synchronization, now values aren't written to the peripheral, or at least not assigned properly before looking which must be written (no ack on peripheral)

* #WIP:
* [wip] database:
* * D doesn't support BluetoothCharacteristic, I must contend with the fact that we'll be starting an application with nonexistent characteristics.......
* * Which should be possible, in fact almost without an issue?
* Fix range checking, sometimes 
* Large sensor data: discover characteristics, subscribe to sensor data, on new data add it to buffer and send confirmation bit. When the sensor data isn't full (mtu sized) continue reading characteristics as normal. On Linux's side change the sensor data buffer each time the data read confirmation bit is received. On sensor data read send 0, on characteristic data read send 1. On central: discover characteristics, read data length characteristic. If Total Sensor Data <= mtu (512 for Go program) read sensor data, otherwise subscribe to sensor data, receive it, and write 0 to read confirmation bit.

#TODO:
* [important] add handling of write or read failures outside of bluetooth connection failing.
* sensor data display
* selective char reads
* [done] char writing on reconnect
* [done] char display style
* [done] confirm reads from central to the peripheral
* Handling connection interruptions
* Reading large sensor data
* Fetch for interrupts during sequential bit transfers, because the sensor deletes the data...? Or just redo the transfer? Anyway power consumption aware sequential transfer of large data.
    * Data could but doesn't have to get deleted on the partial write bit, but if it doesn't delete and the transfer isn't done completely and the user walks away it will keep all data stored until the next disconnect?
    * Alternative is to store data locally and if disconnect happens we store that part until the next connect is made, and we append it.
    * I stored the total length of the data but don't need it for now? Also, if the interruption happens before the peripheral received the request to send new data (eqv to indication ack) then the data isn't deleted and will be re-sent during the next transfer, meaning we must overlap it with existing data or better, discard that data from the list.
      * Pseudo: store each chunk in a global var, if disconnect happens before the ack flag is set, discard that data from the end of the list.
      * Or, append that data to the list only after the ack is [successfully] sent.

#REDO:
* We fetch characteristics and read their values. The metadata map holds their old and new values. Old values are current values, and new values are to-be-set, but still unset values. When we read a characteristic, the value of the characteristic must go to the old value. The new value is the one set in the interface unless the characteristic is read for the first time (no such existing char yet). The chars are then ordered by whether the new value == old value or not.