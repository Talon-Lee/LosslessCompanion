// setrate <uid> <rate>
import CoreAudio
var uid = CommandLine.arguments[1] as CFString
var id = AudioDeviceID(0), size = UInt32(4)
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
_ = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id) }
var rate = Float64(CommandLine.arguments[2])!
a.mSelector = kAudioDevicePropertyNominalSampleRate
print("set", AudioObjectSetPropertyData(id, &a, 0, nil, 8, &rate))
