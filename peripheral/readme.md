FIXME:
New data written to sensorDataHandle. Notifying...
Sleeping for 11 seconds.
Transmit power set to: 9
Auto disconnect bit set to: 1
Confirm read value set to: 1 resetting all values...
Turning off adapter...
Confirm read value set to: 1 resetting all values...
panic: runtime error: slice bounds out of range [124:0]

goroutine 118 [running]:
main.init.func4(0xcf40?, 0xc00013bb90?, {0xc00013f1f4, 0x1, 0x1})
        /home/feliks/Projects/zavrsni/MEMS_bluetooth/peripheral/main.go:317 +0x51f
tinygo.org/x/bluetooth.(*bluezChar).WriteValue(0xc00018f400, {0xc00013f1f4, 0x1, 0x1}, 0x1?)
        /home/feliks/go/pkg/mod/tinygo.org/x/bluetooth@v0.11.0/gatts_linux.go:69 +0x8b
reflect.Value.call({0x5d06c0?, 0xc00018f400?, 0xc00036ebc0?}, {0x6026b3, 0x4}, {0xc00013bbc0, 0x2, 0xc00013bbc0?})
        /usr/local/go/src/reflect/value.go:581 +0xca6
reflect.Value.Call({0x5d06c0?, 0xc00018f400?, 0x2?}, {0xc00013bbc0?, 0x2?, 0xc00001c600?})
        /usr/local/go/src/reflect/value.go:365 +0xb9
github.com/godbus/dbus/v5.exportedMethod.Call({{0x5d06c0?, 0xc00018f400?, 0xc00013b950?}}, {0xc000152d80, 0x2, 0x2?})
        /home/feliks/go/pkg/mod/github.com/godbus/dbus/v5@v5.1.0/default_handler.go:128 +0x1b2
github.com/godbus/dbus/v5.(*Conn).handleCall(0xc0000e4000, 0xc00013b950)
        /home/feliks/go/pkg/mod/github.com/godbus/dbus/v5@v5.1.0/export.go:193 +0x565
created by github.com/godbus/dbus/v5.(*Conn).inWorker in goroutine 18
        /home/feliks/go/pkg/mod/github.com/godbus/dbus/v5@v5.1.0/conn.go:435 +0x276
exit status 2


#### Probably due to race condition in sensor writing and data removal? But we added mutex. Dunno.


so we have a project which requires us to emulate some ultrahigh frequency piezo microphone data on our device (which is the current device Linux) and advertise that data over ultra low power BLE in set intervals, along with the battery level and the number of discrete events (you can spoof that). The current device is a peripheral, and it must be able to accept a connection request from a central device. Upon connecting, the services provided are

read sensor data
read and write system data/config (all peripherals of interest defined in the peripheral)
the system data / config is: battery level misc data (tbd) auto_disconnect bit - whether to automatically disconnect after having the sensor data read from the device, and disable the BLE core for power consumption. If 0 keep the connection logs - some logs from the device (in a fixed memory location)

The Go application we're making must mimic the peripheral device described, to which our BLE flutter app will connect to.

Application structure:
    [] Services {
        [] Characteristics
    }

Services:
    micData:
        operations:
            read
        action:
            return an octet byte of the saved sensor data

    deviceConfig:
        operations:
            read,
            write
        action:
            get or write to a configuration register of the device.

    getLogs:
        operations:
            read
        action:
            return the embedded device log from memory

DataStructures:
    sensorData:
        * timestamp: timestamp of event in microseconds
        * length: duration of the event in microseconds
        * [] components:
            frequency: a frequency bin of the event
            [] amplitudes: discrete amplitudes through bin time of the event, with dt determined by the sensor ODR
    configData:
        * batteryVoltage: current voltage of the battery
        batteryCharge: current charge of the battery, as reported by an external SoC
        * autoDisconnect: whether to automatically disconnect after sending the data to the central, and turn off the BLE core.
        * autoClear: whether to clear the data memory after confirming the data transfer, otherwise round FIFO buffer
        * advertisingPeriod: how often, in s, to exit deep sleep, turn on the BLE core, [bluez_can't] and advertise the device including some data later defined
        * responsePeriod: how long, in ms, to wait for a connection request from the central device after making an advertisement
        * minimalRSSI: the minimal acceptable RSSI of the connection for the data to be transmitted
        transmitPower: the output power BLE power of the peripheral device
        * dataLength: how much microphone sensor data there is in memory
        * memoryPercentage: the percentage of memory remaining on the device for sensor data
        * RTCCalibrationBits: bits used to calibrate the peripheral RTC by the central device
        * UUID: the peripheral UUID
        * displayName: the display name of the peripheral
    logFile:
        * timestamp: timestamp of the event in microseconds
        * errorMessage: a string of the error message

After the advertisement is done and no response, that is connection request is received, the device goes to deep sleep (spoof by calling a DeepSleep(bool) method).

Company ID is 0xFFFF for testing purposes.


Extra: automatic device location using user movement GPS and  triangulation

DONE:
    Characteristics:
        Battery
            Battery percentage
        Device information
            Device name
            Firwmare revision
            Log
            auto disconnect bit
        Industrial sensor
            ODR
            sensor data
            data clear bit

TODO:
    add responseTimeout handing


TODO: Fix sensor data handling during transfer. Probably easiest is to save it into a separate variable and overwrite it once transfer is done.