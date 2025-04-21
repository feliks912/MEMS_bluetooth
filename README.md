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

#TODO:
* sensor data display
* selective char reads
* [done] char writing on reconnect
* [done] char display style
* [done] confirm reads from central to the peripheral
* Handling connection interruptions
* Reading large sensor data

#REDO:
* We fetch characteristics and read their values. The metadata map holds their old and new values. Old values are current values, and new values are to-be-set, but still unset values. When we read a characteristic, the value of the characteristic must go to the old value. The new value is the one set in the interface unless the characteristic is read for the first time (no such existing char yet). The chars are then ordered by whether the new value == old value or not.