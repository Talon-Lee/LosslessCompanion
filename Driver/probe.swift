// 確認 coreaudiod 有沒有載入 LosslessCompanionBridge：裝置、格式、取樣率、音量控制、預設輸出
import CoreAudio
import Foundation

let bridgeUID = "LosslessCompanionBridge_UID"

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ empty: T) -> [T] {
    var a = address(selector, scope), size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == 0, size > 0 else { return [] }
    var values = [T](repeating: empty, count: Int(size) / MemoryLayout<T>.stride)
    AudioObjectGetPropertyData(object, &a, 0, nil, &size, &values)
    return values
}
func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = address(selector), size = UInt32(MemoryLayout<CFString?>.size), value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == 0, let value else { return "?" }
    return value.takeRetainedValue() as String
}
func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T {
    var a = address(selector), value = initial, size = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
    return value
}

let system = AudioObjectID(kAudioObjectSystemObject)
let devices = array(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
let plugins = array(system, kAudioHardwarePropertyPlugInList, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
print("plug-ins:", plugins.map { string($0, kAudioPlugInPropertyBundleID) }.joined(separator: ", "))
guard let bridge = devices.first(where: { string($0, kAudioDevicePropertyDeviceUID) == bridgeUID }) else {
    print("NOT LOADED: no device with UID \(bridgeUID)")
    print("check: log show --last 5m --predicate 'process == \"coreaudiod\"' | grep -i -E 'LosslessCompanionBridge|plug-?in'")
    exit(1)
}
print("LOADED: device \(bridge) \"\(string(bridge, kAudioObjectPropertyName))\" by \(string(bridge, kAudioObjectPropertyManufacturer))")
print("nominal rate:", scalar(bridge, kAudioDevicePropertyNominalSampleRate, Float64(0)))
let rates = array(bridge, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, AudioValueRange())
print("rates:", rates.map { Int($0.mMinimum) })
for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
    let name = scope == kAudioObjectPropertyScopeOutput ? "output" : "input"
    for stream in array(bridge, kAudioDevicePropertyStreams, scope, AudioStreamID(0)) {
        let format = scalar(stream, kAudioStreamPropertyPhysicalFormat, AudioStreamBasicDescription())
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        print("\(name) stream \(stream): \(Int(format.mSampleRate)) Hz \(format.mChannelsPerFrame)ch \(format.mBitsPerChannel)-bit \(isFloat ? "float" : "int") flags 0x\(String(format.mFormatFlags, radix: 16))")
    }
}
let controls = array(bridge, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
print("controls:", controls.map { string($0, kAudioObjectPropertyName) })
var volume = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
print("output volume control:", AudioObjectHasProperty(bridge, &volume) ? "present (system slider can scale samples)" : "none")
let defaultOut = scalar(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
let alertOut = scalar(system, kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
print("default output: \(string(defaultOut, kAudioObjectPropertyName)), alerts: \(string(alertOut, kAudioObjectPropertyName))")
print("can be default system device:", scalar(bridge, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, UInt32(9)))
