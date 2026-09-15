import Foundation
import CoreAudio
import AudioToolbox

/// Captures everything the Mac is playing with a Core Audio process tap (macOS 14.2+) and hands out small PCM
/// chunks: a 12-byte little-endian header (seq u32, sampleRate u32, frames u16, channels u8, flags u8) followed by
/// interleaved 16-bit samples. First use asks for the "System Audio Recording" permission.
final class AudioTap {
    struct TapError: Error, CustomStringConvertible {
        let what: String; let status: OSStatus
        var description: String { status == 0 ? what : "\(what) (error \(status))" }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var seq: UInt32 = 0
    private let queue = DispatchQueue(label: "remote-mouse.audio")
    private let onChunk: (Data) -> Void
    private(set) var running = false

    init(onChunk: @escaping (Data) -> Void) { self.onChunk = onChunk }

    func start(muteMac: Bool) throws {
        guard !running else { return }
        guard #available(macOS 14.2, *) else { throw TapError(what: "audio streaming needs macOS 14.2 or newer", status: 0) }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Remote Mouse"
        desc.isPrivate = true
        desc.muteBehavior = muteMac ? .mutedWhenTapped : .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else {
            throw TapError(what: "could not tap the Mac's audio. Allow System Audio Recording for Remote Mouse in Privacy & Security", status: err)
        }
        tapID = tap

        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        guard err == noErr else { cleanup(); throw TapError(what: "could not read the tap format", status: err) }

        // an aggregate device made of the default output device plus the tap: its IO proc receives the tapped audio
        var outDev = AudioObjectID(kAudioObjectUnknown)
        addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &outDev)
        guard err == noErr, outDev != kAudioObjectUnknown else { cleanup(); throw TapError(what: "no default output device", status: err) }
        var outUID: CFString = "" as CFString
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &outUID) { AudioObjectGetPropertyData(outDev, &addr, 0, nil, &size, $0) }
        guard err == noErr else { cleanup(); throw TapError(what: "could not read the output device id", status: err) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Remote Mouse Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard err == noErr, agg != kAudioObjectUnknown else { cleanup(); throw TapError(what: "could not create the capture device", status: err) }
        aggID = agg

        var frames: UInt32 = 480                                        // 10 ms at 48 kHz keeps the latency low
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(aggID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard err == noErr, procID != nil else { cleanup(); throw TapError(what: "could not attach to the capture device", status: err) }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { cleanup(); throw TapError(what: "could not start the capture device", status: err) }
        running = true
        NSLog("audio: tap running at %.0f Hz, %d ch, %@", format.mSampleRate, Int(format.mChannelsPerFrame),
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "non-interleaved" : "interleaved")
    }

    func stop() { cleanup(); running = false }

    private func cleanup() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Runs on the audio IO thread: converts the tapped buffers to interleaved Int16 and hands the chunk on.
    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard abl.count > 0, let first = abl.first, first.mDataByteSize > 0 else { return }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
        let channels = min(2, nonInterleaved ? abl.count : Int(first.mNumberChannels))
        let srcChannels = nonInterleaved ? 1 : Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (bytesPerSample * srcChannels)
        guard frames > 0, channels > 0, frames < 65536, isFloat || bytesPerSample == 2 else { return }

        var out = Data(count: 12 + frames * channels * 2)
        out.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress else { return }
            p.storeBytes(of: seq.littleEndian, as: UInt32.self)
            p.storeBytes(of: UInt32(format.mSampleRate).littleEndian, toByteOffset: 4, as: UInt32.self)
            p.storeBytes(of: UInt16(frames).littleEndian, toByteOffset: 8, as: UInt16.self)
            p.storeBytes(of: UInt8(channels), toByteOffset: 10, as: UInt8.self)
            p.storeBytes(of: UInt8(0), toByteOffset: 11, as: UInt8.self)
            let dst = (p + 12).assumingMemoryBound(to: Int16.self)
            for c in 0..<channels {
                let buf = nonInterleaved ? abl[c] : first
                guard let data = buf.mData else { continue }
                let stride = nonInterleaved ? 1 : srcChannels, offset = nonInterleaved ? 0 : c
                if isFloat {
                    let src = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { dst[i * channels + c] = Int16(max(-1, min(1, src[i * stride + offset])) * 32767) }
                } else {
                    let src = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<frames { dst[i * channels + c] = src[i * stride + offset] }
                }
            }
        }
        seq &+= 1
        onChunk(out)
    }
}
