package main

import (
	"bufio"
	"encoding/binary"
	"math/rand"
	"os"
	"os/exec"
	"time"

	"github.com/google/uuid"
	"tinygo.org/x/bluetooth"
)

var BLEAdapter = bluetooth.DefaultAdapter

type sensorDataStruct struct {
	timestamp  int64
	timeLength uint32
	sensorODR  uint16
	dataLength uint16
	sensorData []byte
}

type logStruct struct {
	timestamp     int64
	messageLength uint16
	message       string
}

// Device configuration
var (
	fwRevision  string = "v1.0.0"
	deviceName  string = "TinyGo Sensor"
	totalMemory uint64 = 0x100000 // 1MB

	batteryPercentageHandle bluetooth.Characteristic
	batteryPercentage       byte = 100

	// Device log buffer
	deviceLogHandle             bluetooth.Characteristic
	deviceLogCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("beefc0de-f00d-4d3c-a1ca-ae3e7e098a2b"),
	)
	serializedDeviceLogData []byte

	// Memory allocated percentage
	memoryAllocatedPercentageHandle             bluetooth.Characteristic
	memoryAllocatedPercentageCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("deadc0de-beef-4b1b-9b1b-1b1b1b1b1b1b"),
	)
	memoryAllocatedPercentage byte = 0

	// Clear sensor data after sending it to central
	sensorDataClearBitHandle             bluetooth.Characteristic
	sensorDataClearBitCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("cabba6ee-c0de-4414-a6f6-46a397e18422"),
	)
	sensorDataClearBit byte = 1

	// Whether to auto-disconnect after sending sensor data to central
	autoDisconnectBitHandle             bluetooth.Characteristic
	autoDisconnectBitCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("fadebabe-0bad-41c7-992f-a5d063dbfeee"),
	)
	autoDisconnectBit byte = 0
)

// Sensor configuration
var (
	sensorODRHandle             bluetooth.Characteristic
	sensorODRCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("4242c0de-f007-4d3c-a1ca-ae3e7e098a2b"),
	)
	sensorODR uint16 = 1000 // 1000 for now, later on will be much higher

	// Sensor data buffer
	sensorDataHandle             bluetooth.Characteristic
	sensorDataCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("c0debabe-face-4f89-b07d-f9d9b20a76c8"),
	)
	serializedSensorData []byte

	// Total sensor data in memory, in bytes
	sensorDataTotalHandle             bluetooth.Characteristic
	sensorDataTotalCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("0badf00d-cafe-4b1b-9b1b-2c931b1b1b1b"),
	)
	sensorDataTotal uint32 = 0
)

// BLE core configuration
var (
	transmitPowerHandle             bluetooth.Characteristic
	transmitPowerCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("b1eec10a-0007-4d3c-a1ca-ae3e7e098a2b"),
	)
	transmitPower byte = 0 // 0 dBm

	// How often to start advertising
	advIntervalGlobalHandle             bluetooth.Characteristic
	advIntervalGlobalCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("eeafbeef-cafe-4d3c-a1ca-ae3e7e098a2b"),
	)
	advIntervalGlobal uint16 = 5 //in seconds

	// How long a single advertising session lasts
	advDurationHandle             bluetooth.Characteristic
	advDurationCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("babebeef-cafe-4d3c-a1ca-ae3e7e098a2b"),
	)
	advDuration uint16 = 5000 //in ms

	// The interval at which the embedded BLE core will advertise
	advIntervalLocalHandle             bluetooth.Characteristic
	advIntervalLocalCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("c0ffee00-babe-4d3c-a1ca-ae3e7e098a2b"),
	)
	advIntervalLocal uint16 = 1000 //in multiples of 0.625ms

	// How long to wait for a connect response after advertising before turning the core off.
	responseTimeoutHandle             bluetooth.Characteristic
	responseTimeoutCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("f007face-babe-47f5-b542-bbfd9b436872"),
	)
	responseTimeout byte = 10 // In ms
)

var (
	confirmReadHandle bluetooth.Characteristic
	confirmReadUUID   = bluetooth.NewUUID(
		uuid.MustParse("aaaaaaaa-face-4f89-b07d-f9d9b20a76c8"),
	)
	confirmReadValue = []byte{0x00}
)

var stopAdvertisingDueToDisconnect bool = false
var selfWritingODRValue bool = false

var GATTStack = []bluetooth.Service{
	{
		// Battery charge
		UUID: bluetooth.ServiceUUIDBattery, //0x180F
		Characteristics: []bluetooth.CharacteristicConfig{
			{
				Handle: &batteryPercentageHandle,
				UUID:   bluetooth.CharacteristicUUIDBatteryLevel,
				Value:  []byte{batteryPercentage},
				Flags:  bluetooth.CharacteristicReadPermission,
			},
		},
	},
	{
		UUID: bluetooth.ServiceUUIDTxPower, //0x1804
		Characteristics: []bluetooth.CharacteristicConfig{
			{
				Handle: &transmitPowerHandle,
				UUID:   bluetooth.CharacteristicUUIDTxPowerLevel,
				Value:  []byte{transmitPower},
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 1 {
						return
					}
					transmitPower = value[0]
				},
			},
		},
	},
	{
		// Device configuration
		UUID: bluetooth.New16BitUUID(0x1111), //0x1111
		Characteristics: []bluetooth.CharacteristicConfig{
			{
				UUID:  bluetooth.CharacteristicUUIDDeviceName,
				Value: []byte(deviceName),
				Flags: bluetooth.CharacteristicReadPermission,
			},
			{
				UUID:  bluetooth.CharacteristicUUIDFirmwareRevisionString,
				Value: []byte(fwRevision),
				Flags: bluetooth.CharacteristicReadPermission,
			},
			{
				Handle: &deviceLogHandle,
				UUID:   deviceLogCharacteristicUUID,
				Value:  serializedDeviceLogData,
				Flags:  bluetooth.CharacteristicReadPermission,
			},
			{
				Handle: &memoryAllocatedPercentageHandle,
				UUID:   memoryAllocatedPercentageCharacteristicUUID,
				Value:  []byte{memoryAllocatedPercentage},
				Flags:  bluetooth.CharacteristicReadPermission,
			},
			{
				Handle: &sensorDataTotalHandle,
				UUID:   sensorDataTotalCharacteristicUUID,
				Value:  ToByteArray(sensorDataTotal),
				Flags:  bluetooth.CharacteristicReadPermission,
			},
			{
				Handle: &autoDisconnectBitHandle,
				UUID:   autoDisconnectBitCharacteristicUUID,
				Value:  []byte{autoDisconnectBit},
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 1 {
						return
					}
					autoDisconnectBit = value[0]
				},
			},
			{
				Handle: &responseTimeoutHandle,
				UUID:   responseTimeoutCharacteristicUUID,
				Value:  []byte{responseTimeout},
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 1 {
						return
					}
					responseTimeout = value[0]
				},
			},
		},
	},
	{
		UUID: bluetooth.New16BitUUID(0x1999),
		Characteristics: []bluetooth.CharacteristicConfig{
			{
				Handle: &confirmReadHandle,
				UUID:   confirmReadUUID,
				Value:  confirmReadValue,
				Flags:  bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 1 {
						return
					}
					confirmReadValue = value

					println("Now we would disconnect if we could.")

					stopAdvertisingDueToDisconnect = true
				},
			},
		},
	},
	{
		// Config and misc info
		UUID: bluetooth.New16BitUUID(0x185A), // Industrial Measurement Device Service UUID
		Characteristics: []bluetooth.CharacteristicConfig{
			{
				Handle: &sensorODRHandle,
				UUID:   sensorODRCharacteristicUUID, // Corrected UUID
				Value:  ToByteArray(sensorODR),
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if selfWritingODRValue {
						return
					}

					selfWritingODRValue = true
					defer func() {
						selfWritingODRValue = false
					}()

					if offset != 0 || len(value) != 2 {
						return
					}

					sensorODR = binary.LittleEndian.Uint16(value)

					println("setting value...")
					sensorODRHandle.Write(ToByteArray(sensorODR))
					println("Sensor ODR set to:", sensorODR)
				},
			},
			{
				Handle: &sensorDataHandle,
				UUID:   sensorDataCharacteristicUUID, // UUID: c0debabe-face-4f89-b07d-f9d9b20a76c8
				Value:  serializedSensorData,
				Flags:  bluetooth.CharacteristicReadPermission, // Added WritePermission
				// WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
				// 	if offset != 0 || len(value) != 0 { // Corrected WriteEvent for sensorDataHandle
				// 		return
				// 	}
				// 	println("Written 0 to sensor data!")
				// 	serializedSensorData = nil // Clear on write
				// },
			},
			{
				Handle: &sensorDataClearBitHandle,
				UUID:   sensorDataClearBitCharacteristicUUID,
				Value:  []byte{sensorDataClearBit},

				// Notify simulates indications.
				Flags: bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 1 {
						return
					}
					sensorDataClearBit = value[0]
				},
			},
			{
				Handle: &advIntervalGlobalHandle,
				UUID:   advIntervalGlobalCharacteristicUUID,
				Value:  ToByteArray(advIntervalGlobal),
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 2 {
						return
					}
					advIntervalGlobal = binary.LittleEndian.Uint16(value)
				},
			},
			{
				Handle: &advDurationHandle,
				UUID:   advDurationCharacteristicUUID,
				Value:  ToByteArray(advDuration),
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 2 {
						return
					}
					advDuration = binary.LittleEndian.Uint16(value)
				},
			},
			{
				Handle: &advIntervalLocalHandle,
				UUID:   advIntervalLocalCharacteristicUUID,
				Value:  ToByteArray(advIntervalLocal),
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if offset != 0 || len(value) != 2 {
						return
					}
					advIntervalLocal = binary.LittleEndian.Uint16(value)
				},
			},
		},
	},
}

func SerializeLogs(result *[]byte, log logStruct) {

	var buffer [10]byte
	binary.LittleEndian.PutUint64(buffer[:8], uint64(log.timestamp))
	binary.LittleEndian.PutUint16(buffer[8:10], log.messageLength)

	*result = append(*result, buffer[:]...)
	*result = append(*result, log.message...)
}

func NewLogHandler(timestamp int64, log string) {
	logStructInstance := logStruct{
		timestamp:     timestamp,
		messageLength: uint16(len(log)),
		message:       log,
	}
	SerializeLogs(&serializedDeviceLogData, logStructInstance)
	deviceLogHandle.Write(serializedDeviceLogData)
}

func SerializeSensorData(result *[]byte, dataStruct sensorDataStruct) {

	var buffer [16]byte
	binary.LittleEndian.PutUint64(buffer[:8], uint64(dataStruct.timestamp))
	binary.LittleEndian.PutUint32(buffer[8:12], dataStruct.timeLength)
	binary.LittleEndian.PutUint16(buffer[12:14], dataStruct.sensorODR)
	binary.LittleEndian.PutUint16(buffer[14:16], dataStruct.dataLength)

	*result = append(*result, buffer[:]...)
	*result = append(*result, dataStruct.sensorData...)
}

func NewSensorDataHandler(startTime int64, timeLength uint32, rawData []byte) {
	dataStruct := sensorDataStruct{
		timestamp:  startTime,
		timeLength: timeLength,
		sensorODR:  sensorODR,
		dataLength: uint16(len(rawData)),
		sensorData: rawData,
	}

	if true {
		NewLogHandler(startTime+int64(timeLength), "New sensor data received")
	}

	if false {
		println("Sensor data received")
		println("Timestamp:", dataStruct.timestamp)
		println("Time Length:", dataStruct.timeLength)
		println("Sensor ODR:", dataStruct.sensorODR)
		println("Data Length:", dataStruct.dataLength)
		println("Sensor Data:", dataStruct.sensorData)
		println("total data length:", len(serializedSensorData))
		println("Memory Percentage:", memoryAllocatedPercentage)
		println("Battery Percentage:", batteryPercentage)
		println()
	}

	println("Sensor ODR:", dataStruct.sensorODR)

	SerializeSensorData(&serializedSensorData, dataStruct)
	memoryAllocatedPercentage = uint8((float64(len(serializedSensorData)) / float64(totalMemory)) * 100 / 2) // Fixed calculation for accuracy

	sensorDataTotal = uint32(len(serializedSensorData))
	sensorDataTotalHandle.Write(ToByteArray(sensorDataTotal))

	memoryAllocatedPercentageHandle.Write([]byte{memoryAllocatedPercentage})

	sensorDataHandle.Write(serializedSensorData)
	//Let's test some random bits instead...

	//randomTempData := make([]byte, 50)
	//rand.Read(randomTempData)

	//sensorDataHandle.Write(randomTempData)
	//println("Sending value: ", randomTempData)

	println("New data written to sensorDataHandle. Notifying...")

}

func sensorSimulator(ODR uint16) {
	for {
		startTimestamp := time.Now().UnixMicro()

		// The length of the data is random - between 3 and 10
		randomDataLength := rand.Int()%7 + 3

		dataBuffer := make([]byte, randomDataLength*2) // 2 bytes per data point for a 8+ bit sensor

		for range randomDataLength {
			randomData := uint16(rand.Int() % 1024) // 10 bit sensor?

			time.Sleep(time.Duration(1_000_000/uint32(ODR)) * time.Microsecond)

			dataBuffer = append(dataBuffer, ToByteArray(randomData)...)
		}

		timeLength := time.Now().UnixMicro() - startTimestamp

		NewSensorDataHandler(startTimestamp, uint32(timeLength), dataBuffer)

		var secondsSleep = rand.Int()%10 + 10 // One reading every 10-20 seconds
		println("Sleeping for", secondsSleep, "seconds.")

		time.Sleep(time.Duration(secondsSleep) * time.Second)
	}
}

// Convert the variables to bytes in Little Endian (Linux default)
func ToByteArray(value interface{}) []byte {
	var buf []byte

	switch v := value.(type) {
	case int:
		buf = make([]byte, 8)
		binary.LittleEndian.PutUint64(buf, uint64(v))
	case int8:
		buf = []byte{byte(v)}
	case int16:
		buf = make([]byte, 2)
		binary.LittleEndian.PutUint16(buf, uint16(v))
	case int32:
		buf = make([]byte, 4)
		binary.LittleEndian.PutUint32(buf, uint32(v))
	case int64:
		buf = make([]byte, 8)
		binary.LittleEndian.PutUint64(buf, uint64(v))
	case uint:
		buf = make([]byte, 8)
		binary.LittleEndian.PutUint64(buf, uint64(v))
	case uint8:
		buf = []byte{v}
	case uint16:
		buf = make([]byte, 2)
		binary.LittleEndian.PutUint16(buf, v)
	case uint32:
		buf = make([]byte, 4)
		binary.LittleEndian.PutUint32(buf, v)
	case uint64:
		buf = make([]byte, 8)
		binary.LittleEndian.PutUint64(buf, v)
	default:
		return nil
	}

	return buf
}

func setAdapterPowerState(state bool) error {
	var powerState string = "off"

	if state {
		powerState = "on"
	}

	cmd := exec.Command("bluetoothctl", "power", powerState)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	println("Running bluetoothctl power " + powerState)
	return cmd.Run()
}

func stopAdvertisingRoutine(adv *bluetooth.Advertisement) {
	for {
		if stopAdvertisingDueToDisconnect {
			println("Stopping advertising due to disconnect...")
			adv.Stop()
			setAdapterPowerState(false)
			stopAdvertisingDueToDisconnect = false

			println("Stopped advertising. Waiting for user input to continue...")
			input := bufio.NewScanner(os.Stdin)
			input.Scan()
			println("User input received. Restarting advertising...")
			setAdapterPowerState(true)

			time.Sleep(time.Second * 2) // Wait for the adapter to be ready

			adv.Start()
		}
		time.Sleep(time.Microsecond * 100)
	}
}

func main() {
	println("Starting BLE application...")

	println("Enabling BLE stack...")
	setAdapterPowerState(true)
	must("enable BLE stack", BLEAdapter.Enable())
	println("BLE stack enabled.")

	println("Configuring advertisement...")
	adv := BLEAdapter.DefaultAdvertisement()
	must("config adv", adv.Configure(bluetooth.AdvertisementOptions{
		LocalName:    deviceName,
		ServiceUUIDs: []bluetooth.UUID{bluetooth.ServiceUUIDBattery},
	}))
	println("Advertisement configured.")

	for _, service := range GATTStack {
		println("Adding service:", service.UUID.String())
		must("add service", BLEAdapter.AddService(&service))
	}

	//go sensorSimulator(sensorODR)
	go stopAdvertisingRoutine(adv)
	//go batteryLevelHandler()
	//go advertisingHandler(adv)

	//println("Started advertising...")
	adv.Start()

	for {
		time.Sleep(time.Second)
	}
}

func advertisingHandler(adv *bluetooth.Advertisement) {
	for {
		println("Starting advertising....")
		adv.Start()
		startTime := time.Now().UnixMilli()

		for (time.Now().UnixMilli() - startTime) < int64(advDuration) {

			//Placeholder for operation during advertising
			time.Sleep(time.Duration(advDuration) * time.Millisecond / 100)
		}
		println("Stopping advertising....")
		adv.Stop()

		time.Sleep(time.Duration(advIntervalGlobal) * time.Second)
	}
}

func batteryLevelHandler() {
	for {
		time.Sleep(time.Duration(15000+rand.Int()%10000) * time.Millisecond) // Randomized battery drain between 15 and 25 seconds per percent
		batteryPercentage = batteryPercentage - 1
		batteryPercentageHandle.Write([]byte{batteryPercentage})
	}
}

func must(action string, err error) {
	if err != nil {
		panic(action + ": " + err.Error())
	}
}
