import CoreAudio
import Foundation

/// 本机可用的音频输入（麦克风）设备。
struct RecordingAudioInputDevice: Equatable, Identifiable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

/// 通过 CoreAudio 枚举输入设备；供 HUD 设备菜单与麦克风采集解析 UID。
enum RecordingAudioInputDevices {
    /// 至少有一个输入通道的设备，按名称排序。
    static func available() -> [RecordingAudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else { return [] }

        return ids.compactMap { id -> RecordingAudioInputDevice? in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: id, selector: kAudioObjectPropertyName)
            else { return nil }
            return RecordingAudioInputDevice(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 将持久化 UID 解析为当前 `AudioObjectID`；设备拔出时返回 `nil`。
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        available().first(where: { $0.uid == uid })?.id
    }

    /// 显示名；未知 UID 返回 `nil`。
    static func displayName(forUID uid: String?) -> String? {
        guard let uid else { return nil }
        return available().first(where: { $0.uid == uid })?.name
    }

    private static func inputChannelCount(of deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr
        else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        of deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let cfString = value?.takeUnretainedValue() else { return nil }
        return cfString as String
    }
}
