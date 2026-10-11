import AVFoundation
import CoreAudio
import Foundation

/// Keeps the built-in microphone open and buffers 16 kHz mono audio, so a
/// dictation can start without waiting for any audio device to spin up.
///
/// While idle only the last `preRollSeconds` are kept. `beginTake()` returns the
/// sample index where the take starts (including pre-roll); samples are then
/// retained until `endTake()`.
final class AudioCapture {
    static let sampleRate: Double = 16_000
    private let preRollSeconds = 0.3

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let lock = NSLock()
    /// Buffered samples; `base` is the absolute index of `samples[0]`.
    private var samples: [Float] = []
    private var base = 0
    private var takeStart: Int?
    private var latestLevel: Float = 0

    /// RMS of the most recent audio buffer (0...1), for the level meter.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return latestLevel
    }

    private var configObserver: NSObjectProtocol?

    /// UID of the input device to use; nil means the built-in microphone.
    var preferredDeviceUID: String? {
        didSet { if oldValue != preferredDeviceUID { restart() } }
    }

    func start() throws {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Log.info("audio: engine configuration changed, restarting")
            self?.restart()
        }
        try startEngine()
    }

    func restart() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do { try startEngine() } catch { Log.info("audio: restart failed: \(error)") }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let devices = Self.inputDevices()
        let chosen = devices.first { $0.uid == preferredDeviceUID } ?? devices.first { $0.isBuiltIn }
        if let device = chosen, let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.info("audio: input pinned to \(device.name) (status \(status))")
        } else {
            Log.info("audio: preferred mic not found, using system default input")
        }

        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
        Log.info("audio: engine running, input \(inFormat.sampleRate) Hz x\(inFormat.channelCount)")
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()

        lock.lock()
        latestLevel = rms
        samples.append(contentsOf: chunk)
        if takeStart == nil {
            let keep = Int(preRollSeconds * Self.sampleRate)
            if samples.count > keep * 4 {
                let drop = samples.count - keep
                samples.removeFirst(drop)
                base += drop
            }
        }
        lock.unlock()
    }

    /// Marks the start of a take, including pre-roll. Returns the absolute start index.
    func beginTake() -> Int {
        lock.lock(); defer { lock.unlock() }
        let end = base + samples.count
        let start = max(base, end - Int(preRollSeconds * Self.sampleRate))
        takeStart = start
        return start
    }

    /// Absolute index one past the newest buffered sample.
    var currentIndex: Int {
        lock.lock(); defer { lock.unlock() }
        return base + samples.count
    }

    /// Copies samples in the absolute range [from, to).
    func slice(from: Int, to: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let lo = max(from - base, 0), hi = min(to - base, samples.count)
        guard hi > lo else { return [] }
        return Array(samples[lo..<hi])
    }

    func endTake() {
        lock.lock(); defer { lock.unlock() }
        takeStart = nil
    }

    // MARK: - Device lookup

    struct InputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isBuiltIn: Bool
        let isBluetooth: Bool
    }

    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var sAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { return nil }
            let transport: UInt32 = property(id, kAudioDevicePropertyTransportType) ?? 0
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(
                id: id, uid: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? "Unknown",
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func property<T>(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}
