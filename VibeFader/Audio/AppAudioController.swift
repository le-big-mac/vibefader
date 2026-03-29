import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

/// Manages a muting audio tap for a single application process.
///
/// Architecture (based on proven patterns from AudioCap/SoundPusher):
///   1. Muting CATap intercepts the process's audio
///   2. Tap-only aggregate device provides an input stream
///   3. IOProc on the aggregate device reads tap audio into a ring buffer
///   4. AVAudioEngine with AVAudioSourceNode reads from ring buffer and plays to speakers
///   5. Volume is applied in the source node's render block
@available(macOS 14.2, *)
final class AppAudioController: @unchecked Sendable {
    let pid: pid_t
    private(set) var isRunning = false

    // Core Audio objects
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    // Output engine
    private var engine: AVAudioEngine?

    // Per-channel ring buffers (SPSC: IOProc writes, SourceNode reads)
    private var ringChannels: [UnsafeMutablePointer<Float>] = []
    private var ringCapacity: Int = 0       // frames per channel
    var ringWritePos: Int = 0               // modified only by IOProc
    var ringReadPos: Int = 0                // modified only by SourceNode
    private var numChannels: Int = 2
    private let targetGap: Int = 2048       // target frames between write and read
    private let minGap: Int = 512           // resync if gap falls below this
    private let maxGap: Int = 8192          // resync if gap exceeds this

    // Volume (read from render thread, written from main thread)
    var volume: Float = 1.0

    // Fixed gain boost for system daemons whose tap signal is much quieter
    // than their native playback level
    var gain: Float = 1.0
    private var ioCallbackCount: Int = 0

    private let discovery = AudioProcessDiscovery()

    init(pid: pid_t) {
        self.pid = pid
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    func start(outputDeviceID: AudioObjectID) throws {
        guard !isRunning else { return }

        // 1. Get process object ID from PID
        guard let processObjectID = discovery.processObjectID(for: pid) else {
            NSLog("[VibeFader] No process object for PID \(pid)")
            throw AudioError.deviceNotFound
        }
        NSLog("[VibeFader] PID \(pid) → process object \(processObjectID)")

        // 2. Create per-process muting tap
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDesc.name = "VibeFader-\(pid)"
        tapDesc.muteBehavior = CATapMuteBehavior(rawValue: 2)! // CATapMutedWhenTapped
        tapDesc.isPrivate = true

        var tapObjectID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapObjectID)
        guard status == noErr else {
            NSLog("[VibeFader] Tap creation failed: \(status)")
            throw AudioError.tapCreationFailed(status)
        }
        self.tapID = tapObjectID
        NSLog("[VibeFader] Tap created: \(tapObjectID), UUID: \(tapDesc.uuid.uuidString)")

        // 3. Get tap audio format
        let tapFormat = getTapFormat(tapID: tapObjectID)
        let sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48000
        let channels = tapFormat.mChannelsPerFrame > 0 ? Int(tapFormat.mChannelsPerFrame) : 2
        NSLog("[VibeFader] Tap format: \(sampleRate)Hz, \(channels)ch, flags=\(tapFormat.mFormatFlags)")

        // 4. Create TAP-ONLY aggregate device (no hardware sub-device!)
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VibeFader-\(pid)",
            kAudioAggregateDeviceUIDKey: "com.chadon.vibefader.tap.\(pid).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    "drift": true,
                ]
            ],
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
        guard status == noErr else {
            NSLog("[VibeFader] Aggregate creation failed: \(status)")
            AudioHardwareDestroyProcessTap(tapObjectID)
            self.tapID = kAudioObjectUnknown
            throw AudioError.aggregateDeviceFailed(status)
        }
        self.aggregateDeviceID = aggID
        NSLog("[VibeFader] Aggregate device: \(aggID)")

        // 5. Allocate per-channel ring buffers (~340ms at 48kHz)
        numChannels = channels
        ringCapacity = 16384
        ringWritePos = 0
        ringReadPos = 0
        ringChannels = (0..<numChannels).map { _ in
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
            buf.initialize(repeating: 0, count: ringCapacity)
            return buf
        }

        // 6. Register IOProc on aggregate device to READ tap audio
        let controllerPtr = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) {
            inNow, inInputData, inInputTime, outOutputData, outOutputTime in

            let ctrl = Unmanaged<AppAudioController>.fromOpaque(controllerPtr).takeUnretainedValue()
            ctrl.ioCallbackCount += 1

            let numBufs = Int(inInputData.pointee.mNumberBuffers)
            guard numBufs > 0 else { return }

            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

            // Log format details on first callback
            if ctrl.ioCallbackCount == 1 {
                let b = abl[0]
                NSLog("[VibeFader] PID \(ctrl.pid) IOProc: bufs=\(numBufs) size=\(b.mDataByteSize) ch=\(b.mNumberChannels)")
            }

            let cap = ctrl.ringCapacity
            let wp = ctrl.ringWritePos
            let nch = ctrl.numChannels

            if numBufs == 1 && nch > 1 {
                // INTERLEAVED: single buffer with L0,R0,L1,R1,...
                let src = abl[0].mData!.assumingMemoryBound(to: Float.self)
                let totalSamples = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                let frameCount = totalSamples / nch

                for f in 0..<frameCount {
                    for ch in 0..<nch {
                        ctrl.ringChannels[ch][(wp + f) % cap] = src[f * nch + ch]
                    }
                }
                ctrl.ringWritePos = (wp + frameCount) % cap
            } else {
                // NON-INTERLEAVED: one buffer per channel
                let frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                for ch in 0..<min(nch, numBufs) {
                    let src = abl[ch].mData!.assumingMemoryBound(to: Float.self)
                    let dst = ctrl.ringChannels[ch]
                    for f in 0..<frameCount {
                        dst[(wp + f) % cap] = src[f]
                    }
                }
                ctrl.ringWritePos = (wp + frameCount) % cap
            }


        }

        guard status == noErr, let procID = procID else {
            NSLog("[VibeFader] IOProc creation failed: \(status)")
            cleanupRingBuffer()
            cleanup()
            throw AudioError.engineStartFailed(
                NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        self.ioProcID = procID
        NSLog("[VibeFader] IOProc registered")

        // 7. Create AVAudioEngine with AVAudioSourceNode (output only, no inputNode!)
        let avFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels))!

        let newEngine = AVAudioEngine()
        let sourceNode = AVAudioSourceNode(format: avFormat) {
            _, _, frameCount, outputData -> OSStatus in

            let ctrl = Unmanaged<AppAudioController>.fromOpaque(controllerPtr).takeUnretainedValue()
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            let vol = ctrl.volume
            let cap = ctrl.ringCapacity
            let chCount = min(ctrl.numChannels, abl.count)

            // Check read/write gap and resync if drifted
            var rp = ctrl.ringReadPos
            let wp = ctrl.ringWritePos
            let gap = (wp - rp + cap) % cap

            if gap < ctrl.minGap || gap > ctrl.maxGap {
                // Resync: place read position targetGap frames behind write
                rp = (wp - ctrl.targetGap + cap) % cap
            }

            let g = ctrl.gain

            for ch in 0..<chCount {
                let src = ctrl.ringChannels[ch]
                let dst = abl[ch].mData!.assumingMemoryBound(to: Float.self)
                for f in 0..<frames {
                    let sample = src[(rp + f) % cap] * vol * g
                    // Soft clip to prevent distortion from gain boost
                    dst[f] = sample > 1.0 ? 1.0 : (sample < -1.0 ? -1.0 : sample)
                }
            }

            ctrl.ringReadPos = (rp + frames) % cap
            return noErr
        }

        newEngine.attach(sourceNode)
        newEngine.connect(sourceNode, to: newEngine.mainMixerNode, format: avFormat)
        newEngine.prepare()

        // 8. Start the aggregate device IO FIRST (fills ring buffer before engine reads)
        status = AudioDeviceStart(aggID, procID)
        guard status == noErr else {
            NSLog("[VibeFader] AudioDeviceStart failed: \(status)")
            AudioDeviceDestroyIOProcID(aggID, procID)
            self.ioProcID = nil
            cleanupRingBuffer()
            cleanup()
            throw AudioError.engineStartFailed(
                NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }

        // 9. Let IOProc buffer some data, then start the engine
        //    Sleep ~50ms so the ring buffer has data before the source node reads
        Thread.sleep(forTimeInterval: 0.05)

        do {
            try newEngine.start()
            NSLog("[VibeFader] Engine started (after IOProc primed)")
        } catch {
            NSLog("[VibeFader] Engine start failed: \(error)")
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
            self.ioProcID = nil
            cleanupRingBuffer()
            cleanup()
            throw AudioError.engineStartFailed(error)
        }
        self.engine = newEngine

        self.isRunning = true
        NSLog("[VibeFader] Controller running for PID \(pid)")
    }

    func stop() {
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }

        engine?.stop()
        engine = nil

        cleanupRingBuffer()
        cleanup()
        isRunning = false
    }

    func setVolume(_ newVolume: Float) {
        volume = min(max(newVolume, 0), 1)
    }

    func updateOutputDevice(_ deviceID: AudioObjectID) throws {
        guard isRunning else { return }
        stop()
        try start(outputDeviceID: deviceID)
    }

    // MARK: - Private

    private func getTapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription {
        let kAudioTapPropertyFormat = AudioObjectPropertySelector(0x74666D74) // 'tfmt'
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        if status != noErr {
            NSLog("[VibeFader] kAudioTapPropertyFormat failed: \(status)")
        }
        return format
    }

    private func cleanupRingBuffer() {
        for buf in ringChannels {
            buf.deallocate()
        }
        ringChannels = []
    }

    private func cleanup() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}
