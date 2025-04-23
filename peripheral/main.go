package main

import (
	"bufio"
	"encoding/binary"
	"math/rand"
	"os"
	"os/exec"
	"sync"
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
	deviceName  string = "TinyGo Sensor"
	totalMemory uint64 = 0x100000 // 1MB

	fwRevision     string = "0.1.0"
	fwRevisionUUID        = bluetooth.NewUUID(
		uuid.MustParse("cabacafe-f00d-4b1b-9b1b-1b1b1b1b1b1b"),
	)

	batteryPercentageHandle bluetooth.Characteristic
	batteryPercentageUUID   = bluetooth.NewUUID(
		uuid.MustParse("c0dec0fe-0bad-41c7-992f-a5d063dbfeee"),
	)
	batteryPercentage byte = 100

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
	sensorDataClearBit      byte = 1
	selfWritingDataClearBit bool = false

	// Whether to auto-disconnect after sending sensor data to central
	autoDisconnectBitHandle             bluetooth.Characteristic
	autoDisconnectBitCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("fadebabe-0bad-41c7-992f-a5d063dbfeee"),
	)
	autoDisconnectBit            byte = 0
	selfWritingAutoDisconnectBit bool = false
)

// Sensor configuration
var (
	sensorODRHandle             bluetooth.Characteristic
	sensorODRCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("4242c0de-f007-4d3c-a1ca-ae3e7e098a2b"),
	)
	sensorODR      uint16 = 2500 // 2500 for now, later on will be much higher
	selfWritingODR bool   = false

	// Sensor data buffer
	sensorDataHandle             bluetooth.Characteristic
	sensorDataCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("c0debabe-face-4f89-b07d-f9d9b20a76c8"),
	)
	serializedSensorData       []byte
	serializedSensorDataRange  []int
	serializedSensorDataMutex  sync.Mutex
	sensorDataInTransfer       bool = false
	sensorDataMaxTransferChunk      = 420

	// Total sensor data in memory, in bytes
	sensorDataTotalHandle             bluetooth.Characteristic
	sensorDataTotalCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("0badf00d-cafe-4b1b-9b1b-2c931b1b1b1b"),
	)
	sensorDataTotal               uint32 = 0
	sensorDataTotalAtBufferChange uint32 = 0
)

// BLE core configuration
var (
	transmitPowerHandle             bluetooth.Characteristic
	transmitPowerCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("b1eec10a-0007-4d3c-a1ca-ae3e7e098a2b"),
	)
	transmitPower            byte = 0 // 0 dBm
	selfWritingTransmitPower bool = false

	// How often to start advertising
	advIntervalGlobalHandle             bluetooth.Characteristic
	advIntervalGlobalCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("eeafbeef-cafe-4d3c-a1ca-ae3e7e098a2b"),
	)
	advIntervalGlobal            uint16 = 5 //in seconds
	selfWritingAdvIntervalGlobal bool   = false

	// How long a single advertising session lasts
	advDurationHandle             bluetooth.Characteristic
	advDurationCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("babebeef-cafe-4d3c-a1ca-ae3e7e098a2b"),
	)
	advDuration            uint16 = 999 //in ms
	selfWritingAdvDuration bool   = false

	// The interval at which the embedded BLE core will advertise
	advIntervalLocalHandle             bluetooth.Characteristic
	advIntervalLocalCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("c0ffee00-babe-4d3c-a1ca-ae3e7e098a2b"),
	)
	advIntervalLocal            uint16 = 1000 //in multiples of 0.625ms
	selfWritingAdvIntervalLocal bool   = false

	// How long to wait for a connect response after advertising before turning the core off.
	responseTimeoutHandle             bluetooth.Characteristic
	responseTimeoutCharacteristicUUID = bluetooth.NewUUID(
		uuid.MustParse("f007face-babe-47f5-b542-bbfd9b436872"),
	)
	responseTimeout            byte = 10 // In ms
	selfWritingResponseTimeout bool = false
)

var (
	confirmReadHandle bluetooth.Characteristic
	confirmReadUUID   = bluetooth.NewUUID(
		uuid.MustParse("aaaaaaaa-face-4f89-b07d-f9d9b20a76c8"),
	)
	confirmReadValue = []byte{0x00}
)

var stopAdvertisingDueToDisconnect bool = false

var GATTStack = []bluetooth.Service{
	{
		// Battery charge
		UUID: bluetooth.ServiceUUIDBattery, //0x180F
		Characteristics: []bluetooth.CharacteristicConfig{
			{
				Handle: &batteryPercentageHandle,
				UUID:   batteryPercentageUUID,
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
				UUID:   transmitPowerCharacteristicUUID,
				Value:  []byte{transmitPower},
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if selfWritingTransmitPower {
						return
					}

					selfWritingTransmitPower = true
					defer func() {
						selfWritingTransmitPower = false
					}()
					if offset != 0 || len(value) != 1 {
						println("Bad TransmitPower value: ", value)
						return
					}
					transmitPower = value[0]
					transmitPowerHandle.Write(ToByteArray(transmitPower))
					println("Transmit power set to:", transmitPower)
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
				UUID:  fwRevisionUUID,
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
					if selfWritingAutoDisconnectBit {
						return
					}

					selfWritingAutoDisconnectBit = true
					defer func() {
						selfWritingAutoDisconnectBit = false
					}()
					if offset != 0 || len(value) != 1 {
						println("Bad AutoDisconnectBit value: ", value)
						return
					}
					autoDisconnectBit = value[0]
					autoDisconnectBitHandle.Write(ToByteArray(autoDisconnectBit))
					println("Auto disconnect bit set to:", autoDisconnectBit)
				},
			},
			{
				Handle: &responseTimeoutHandle,
				UUID:   responseTimeoutCharacteristicUUID,
				Value:  []byte{responseTimeout},
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if selfWritingResponseTimeout {
						return
					}

					selfWritingResponseTimeout = true
					defer func() {
						selfWritingResponseTimeout = false
					}()
					if offset != 0 || len(value) != 1 {
						println("Bad ResponseTimeout value: ", value)
						return
					}
					responseTimeout = value[0]
					responseTimeoutHandle.Write(ToByteArray(responseTimeout))
					println("Response timeout set to:", responseTimeout)
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

					//FIXME: If new sensor data is written between the reading of the old one and confirmation of reading old one, it will be lost.
					//Instead we must count the data. If the data length is higher than the data length at the moment of the read, we remove all but the new data.
					// Each time 0x00 is received and data must be shuffled, we note the amount of data in the buffer.
					// If data length is larger at the moment 0x01 is received, a part of data hasn't been sent and must be stored.

					sensorDataInTransfer = true

					serializedSensorDataMutex.Lock()
					defer serializedSensorDataMutex.Unlock()

					if offset != 0 || len(value) != 1 {
						println("Bad ConfirmRead value: ", value)
						return
					}

					confirmReadValue = value

					if confirmReadValue[0] == 0x01 {
						println("Confirm read value set to:", confirmReadValue[0], "resetting all values...")

						clearTransfer := func() {
							sensorDataInTransfer = false
						}

						defer clearTransfer()

						serializedSensorData = serializedSensorData[serializedSensorDataRange[1]:]

						if len(serializedSensorData) <= sensorDataMaxTransferChunk {
							sensorDataHandle.Write(serializedSensorData)
						} else {
							sensorDataHandle.Write(serializedSensorData[:sensorDataMaxTransferChunk])
						}

						serializedDeviceLogData = []byte{}
						deviceLogHandle.Write(serializedDeviceLogData)

						println("Turning off adapter...")

						stopAdvertisingDueToDisconnect = true
					} else { // Written 0

						sensorDataTotalAtBufferChange = sensorDataTotal

						println("Confirm read value set to:", confirmReadValue[0], "changing sensor data buffer...")

						// Discard read sensor data
						serializedSensorData = serializedSensorData[serializedSensorDataRange[1]:]

						if len(serializedSensorData) <= sensorDataMaxTransferChunk {
							sensorDataHandle.Write(serializedSensorData)
							serializedSensorDataRange = []int{0, len(serializedSensorData)}
							return
						}

						serializedSensorDataRange = []int{0, sensorDataMaxTransferChunk}
						sensorDataHandle.Write(serializedSensorData[:sensorDataMaxTransferChunk])
						println("Sensor data buffer changed.")

					}

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
					if selfWritingODR {
						return
					}

					selfWritingODR = true
					defer func() {
						selfWritingODR = false
					}()

					if offset != 0 || len(value) > 2 {
						println("Bad ODR value: ", value)
						return
					}

					if len(value) == 1 {
						newValue := make([]byte, 2)
						newValue[0] = value[0]
						newValue[1] = 0x00
						value = newValue
					}

					sensorODR = binary.LittleEndian.Uint16(value)

					sensorODRHandle.Write(ToByteArray(sensorODR))
					println("Sensor ODR set to:", sensorODR)
				},
			},
			{
				Handle: &sensorDataHandle,
				UUID:   sensorDataCharacteristicUUID, // UUID: c0debabe-face-4f89-b07d-f9d9b20a76c8
				Value:  serializedSensorData,
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicNotifyPermission,
			},
			{
				Handle: &sensorDataClearBitHandle,
				UUID:   sensorDataClearBitCharacteristicUUID,
				Value:  []byte{sensorDataClearBit},

				// Notify simulates indications.
				Flags: bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if selfWritingDataClearBit {
						return
					}

					selfWritingDataClearBit = true
					defer func() {
						selfWritingDataClearBit = false
					}()

					if offset != 0 || len(value) != 1 {
						println("Bad DataClearBit value: ", value)
						return
					}

					sensorDataClearBit = value[0]

					sensorDataClearBitHandle.Write(ToByteArray(sensorDataClearBit))
					println("Sensor DataClearBit set to:", sensorDataClearBit)
				},
			},
			{
				Handle: &advIntervalGlobalHandle,
				UUID:   advIntervalGlobalCharacteristicUUID,
				Value:  ToByteArray(advIntervalGlobal),
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if selfWritingAdvIntervalGlobal {
						return
					}

					selfWritingAdvIntervalGlobal = true
					defer func() {
						selfWritingAdvIntervalGlobal = false
					}()
					if offset != 0 || len(value) > 2 {
						println("Bad AdvIntervalGlobal value: ", value)
						return
					}

					if len(value) == 1 {
						newValue := make([]byte, 2)
						newValue[0] = value[0]
						newValue[1] = 0x00
						value = newValue
					}

					advIntervalGlobal = binary.LittleEndian.Uint16(value)
					advIntervalGlobalHandle.Write(ToByteArray(advIntervalGlobal))
					println("Advertising interval (global) set to:", advIntervalGlobal)
				},
			},
			{
				Handle: &advDurationHandle,
				UUID:   advDurationCharacteristicUUID,
				Value:  ToByteArray(advDuration),
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if selfWritingAdvDuration {
						return
					}

					selfWritingAdvDuration = true
					defer func() {
						selfWritingAdvDuration = false
					}()
					if offset != 0 || len(value) > 2 {
						println("Bad AdvDuration value: ", value)
						return
					}

					if len(value) == 1 {
						newValue := make([]byte, 2)
						newValue[0] = value[0]
						newValue[1] = 0x00
						value = newValue
					}

					advDuration = binary.LittleEndian.Uint16(value)
					advDurationHandle.Write(ToByteArray(advDuration))
					println("Advertising duration set to:", advDuration)
				},
			},
			{
				Handle: &advIntervalLocalHandle,
				UUID:   advIntervalLocalCharacteristicUUID,
				Value:  ToByteArray(advIntervalLocal),
				Flags:  bluetooth.CharacteristicReadPermission | bluetooth.CharacteristicWritePermission,
				WriteEvent: func(client bluetooth.Connection, offset int, value []byte) {
					if selfWritingAdvIntervalLocal {
						return
					}

					selfWritingAdvIntervalLocal = true
					defer func() {
						selfWritingAdvIntervalLocal = false
					}()
					if offset != 0 || len(value) > 2 {
						println("Bad AdvIntervalLocal value: ", value)
						return
					}

					if len(value) == 1 {
						newValue := make([]byte, 2)
						newValue[0] = value[0]
						newValue[1] = 0x00
						value = newValue
					}

					advIntervalLocal = binary.LittleEndian.Uint16(value)
					advIntervalLocalHandle.Write(ToByteArray(advIntervalLocal))
					println("Advertising interval (local) set to:", advIntervalLocal)
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

	serializedSensorDataMutex.Lock()
	defer serializedSensorDataMutex.Unlock()

	dataStruct := sensorDataStruct{
		timestamp:  startTime,
		timeLength: timeLength,
		sensorODR:  sensorODR,
		dataLength: uint16(len(rawData)),
		sensorData: rawData,
	}

	SerializeSensorData(&serializedSensorData, dataStruct)

	if false {
		NewLogHandler(startTime+int64(timeLength), "New sensor data received")
	}

	if true {
		println("New sensor event:")
		println("Timestamp:", time.UnixMicro(dataStruct.timestamp).In(time.FixedZone("CEST", 7200)).Format("02.01.2006 15:04:05"))
		println("Event length:", dataStruct.timeLength, "us")
		println("Sensor ODR:", dataStruct.sensorODR, "Hz")
		println("Sensor Data:", dataStruct.sensorData)
		println("Data length:", dataStruct.dataLength, "raw bytes")
		println("total packet size:", len(serializedSensorData), "bytes")
		println("Memory consumption:", memoryAllocatedPercentage, "%")
		println("Battery percentage:", batteryPercentage, "%")
		println()
	}

	memoryAllocatedPercentage = uint8((float64(len(serializedSensorData)) / float64(totalMemory)) * 100 / 2) // Fixed calculation for accuracy
	memoryAllocatedPercentageHandle.Write([]byte{memoryAllocatedPercentage})

	sensorDataTotal = uint32(len(serializedSensorData))
	sensorDataTotalHandle.Write(ToByteArray(sensorDataTotal))

	if sensorDataInTransfer {
		println("New data written to serializedSensorData but ot sensorDataHandle due to ongoing transfer.")
		return
	}

	if len(serializedSensorData) <= sensorDataMaxTransferChunk {
		serializedSensorDataRange = []int{0, len(serializedSensorData)}
	} else {
		serializedSensorDataRange = []int{0, sensorDataMaxTransferChunk}
	}

	sensorDataHandle.Write(serializedSensorData[serializedSensorDataRange[0]:serializedSensorDataRange[1]])

	println("New data written to sensorDataHandle. Notifying...")

}

func sensorSimulator() {
	for {
		startTimestamp := time.Now().UnixMicro()

		// The length of the data is random - between 3 and 10
		randomDataLength := rand.Int()%7 + 3

		var dataBuffer []byte // 2 bytes per data point for a 8+ bit sensor

		for range randomDataLength {
			randomData := uint16(rand.Int() % 1024) // 10 bit sensor?

			time.Sleep(time.Duration(1_000_000/uint32(sensorODR)) * time.Microsecond)

			tempData := ToByteArray(randomData)

			if tempData[0] > 1 {
			}

			print(randomData, " ")
			print(ToByteArray(randomData), " ")
			println()

			dataBuffer = append(dataBuffer, ToByteArray(randomData)...)
		}
		println("dataBuffer: ", dataBuffer)

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

func userInputListener(adv *bluetooth.Advertisement) {
	for {
		input := bufio.NewScanner(os.Stdin)
		input.Scan()

		if input.Text() == "on" {
			setAdapterPowerState(true)

			time.Sleep(time.Second * 2) // Wait for the adapter to be ready

			adv.Start()
		} else if input.Text() == "off" {
			adv.Stop()
			setAdapterPowerState(false)
		}
	}
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
		LocalName: deviceName,
	}))
	println("Advertisement configured.")

	for _, service := range GATTStack {
		println("Adding service:", service.UUID.String())
		must("add service", BLEAdapter.AddService(&service))
	}

	go userInputListener(adv)
	go sensorSimulator()
	go stopAdvertisingRoutine(adv)
	go batteryLevelHandler()
	//go advertisingHandler(adv)

	println("Started advertising...")
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
