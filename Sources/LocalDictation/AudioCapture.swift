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
    /// When the last microphone buffer arrived, to notice an engine that stopped delivering audio.
    private var lastBufferAt = Date.distantPast

    /// RMS of the most recent audio buffer (0...1), for the level meter.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return latestLevel
    }

    private var configObserver: NSObjectProtocol?

    /// Screencast mode: launching with LOCALDICTATION_DEMO_AUDIO=/path/to/speech.wav replaces
    /// the microphone with that file, played in real time from the start of each take.
    private let demoAudio = ProcessInfo.processInfo.environment["LOCALDICTATION_DEMO_AUDIO"].flatMap(AudioCapture.load)
    private var demoTimer: DispatchSourceTimer?

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
        watchDevices()
        try startEngine()
    }

    private var pendingDeviceRestart: DispatchWorkItem?

    /// AVAudioEngine doesn't always post a configuration change when devices come and go
    /// (connecting AirPods left the pinned built-in mic delivering silence), so restart
    /// whenever the device list or system default devices change.
    private func watchDevices() {
        let selectors = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                self?.scheduleDeviceRestart()
            }
        }
    }

    /// Devices fire several notifications as they connect; restart once they settle.
    private func scheduleDeviceRestart() {
        pendingDeviceRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.info("audio: devices changed, restarting")
            self?.restart()
        }
        pendingDeviceRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
        guard let converter, demoAudio == nil else { return }
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
        lastBufferAt = Date()
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
        lock.lock()
        let stalled = demoAudio == nil && Date().timeIntervalSince(lastBufferAt) > 0.5
        lock.unlock()
        if stalled {
            Log.info("audio: no buffers for \(String(format: "%.1f", Date().timeIntervalSince(lastBufferAt))) s, restarting")
            restart()
        }
        lock.lock(); defer { lock.unlock() }
        let end = base + samples.count
        let start = max(base, end - Int(preRollSeconds * Self.sampleRate))
        takeStart = start
        if let demoAudio { playDemo(demoAudio) }
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
        demoTimer?.cancel()
        demoTimer = nil
        lock.lock(); defer { lock.unlock() }
        takeStart = nil
    }

    // MARK: - Demo audio

    private func playDemo(_ audio: [Float]) {
        let chunk = Int(Self.sampleRate / 50)  // 20 ms
        var position = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let end = min(position + chunk, audio.count)
            var samples = position < end ? Array(audio[position..<end]) : []
            samples += [Float](repeating: 0, count: chunk - samples.count)
            position += chunk
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(chunk)).squareRoot()
            self.lock.lock()
            self.samples.append(contentsOf: samples)
            self.latestLevel = rms
            self.lock.unlock()
        }
        demoTimer = timer
        timer.resume()
    }

    private static func load(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 1024)
        else { return nil }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        Log.info("audio: demo mode, playing \(path) instead of the microphone")
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
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
