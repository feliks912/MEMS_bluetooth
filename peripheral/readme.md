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