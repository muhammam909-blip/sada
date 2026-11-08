import Accelerate
import AVFoundation
import MediaToolbox
import Observation
import SwiftUI

// MARK: - Settings shared with the audio thread

final class EQParameters: @unchecked Sendable {
    static let shared = EQParameters()
    private let lock = NSLock()
    private var gains: [Float] = Array(repeating: 0, count: 10)
    private var enabled = false
    private var version = 0

    func snapshot() -> (gains: [Float], enabled: Bool, version: Int) {
        lock.lock(); defer { lock.unlock() }
        return (gains, enabled, version)
    }

    func update(gains: [Float], enabled: Bool) {
        lock.lock()
        self.gains = gains
        self.enabled = enabled
        version &+= 1
        lock.unlock()
    }
}

// MARK: - Per-item DSP state (10-band peaking EQ with vDSP biquads)

final class EQTapContext {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    var sampleRate: Double = 44100
    var isFloat = true
    private var setup: vDSP_biquad_Setup?
    private var delays: [[Float]] = []
    private var appliedVersion = -1
    private var active = false
    private var preGain: Float = 1

    func reset() { appliedVersion = -1 }

    private func rebuildIfNeeded() {
        let snap = EQParameters.shared.snapshot()
        guard snap.version != appliedVersion else { return }
        appliedVersion = snap.version
        active = snap.enabled && isFloat && snap.gains.contains { abs($0) > 0.05 }
        if let s = setup { vDSP_biquad_DestroySetup(s); setup = nil }
        guard active else { return }
        var coeffs: [Double] = []
        for (i, f) in Self.frequencies.enumerated() {
            coeffs += peaking(min(f, sampleRate * 0.45), gainDB: Double(snap.gains[i]), q: 1.41)
        }
        setup = vDSP_biquad_CreateSetup(coeffs, vDSP_Length(Self.frequencies.count))
        let maxBoost = max(0, snap.gains.max() ?? 0)
        preGain = powf(10, -maxBoost * 0.7 / 20) // headroom so boosts don't clip
    }

    private func peaking(_ f: Double, gainDB: Double, q: Double) -> [Double] {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let b0 = 1 + alpha * a, b1 = -2 * cosw, b2 = 1 - alpha * a
        let a0 = 1 + alpha / a, a1 = -2 * cosw, a2 = 1 - alpha / a
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        rebuildIfNeeded()
        guard active, let setup else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let delayCount = 2 * Self.frequencies.count + 2
        for (ch, buffer) in buffers.enumerated() {
            guard let raw = buffer.mData else { continue }
            let data = raw.assumingMemoryBound(to: Float.self)
            let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frames * Int(max(buffer.mNumberChannels, 1)))
            guard count > 0 else { continue }
            while delays.count <= ch { delays.append(Array(repeating: 0, count: delayCount)) }
            var gain = preGain
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(count))
            delays[ch].withUnsafeMutableBufferPointer { d in
                if let base = d.baseAddress {
                    vDSP_biquad(setup, base, data, 1, data, 1, vDSP_Length(count))
                }
            }
        }
    }

    deinit {
        if let s = setup { vDSP_biquad_DestroySetup(s) }
    }
}

// MARK: - Attaching the tap to AVPlayerItems

enum EQTap {
    static func attach(to item: AVPlayerItem) {
        let asset = item.asset
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let mix = makeMix(for: track) else { return }
            await MainActor.run { item.audioMix = mix }
        }
    }

    private static func makeMix(for track: AVAssetTrack) -> AVAudioMix? {
        let context = EQTapContext()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let ctx = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.sampleRate = format.pointee.mSampleRate
                ctx.isFloat = (format.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                ctx.reset()
            },
            unprepare: { _ in },
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let ctx = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.process(bufferList, frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - UI model

struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Reducer", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EQPreset(name: "Vocal", gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        EQPreset(name: "Tarab / Oud", gains: [1, 2, 2, 1, 2, 3, 2, 1, 1, 0]),
        EQPreset(name: "Pop", gains: [-1, 0, 2, 3, 4, 3, 1, 0, -1, -1]),
        EQPreset(name: "Rock", gains: [4, 3, 1, -1, -2, 0, 2, 3, 4, 4]),
        EQPreset(name: "Hip-Hop", gains: [5, 4, 2, 3, -1, -1, 1, 0, 2, 3]),
        EQPreset(name: "Electronic", gains: [4, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        EQPreset(name: "Classical", gains: [3, 2, 1, 0, -1, -1, 0, 2, 3, 3]),
        EQPreset(name: "Loudness", gains: [5, 3, 0, 0, -1, 0, -1, 0, 3, 4]),
        EQPreset(name: "Late Night", gains: [3, 2, 1, 0, 0, 0, -1, -2, -3, -4]),
    ]
}

@MainActor
@Observable
final class EqualizerSettings {
    static let shared = EqualizerSettings()

    var enabled: Bool { didSet { apply() } }
    var gains: [Float] { didSet { apply() } }
    var presetName: String { didSet { UserDefaults.standard.set(presetName, forKey: "eq.preset") } }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "eq.enabled")
        let stored = d.array(forKey: "eq.gains") as? [Double] ?? []
        gains = stored.count == 10 ? stored.map(Float.init) : Array(repeating: 0, count: 10)
        presetName = d.string(forKey: "eq.preset") ?? "Flat"
        EQParameters.shared.update(gains: gains, enabled: enabled)
    }

    func choose(_ preset: EQPreset) {
        presetName = preset.name
        gains = preset.gains
        if !enabled { enabled = true }
    }

    private func apply() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "eq.enabled")
        d.set(gains.map(Double.init), forKey: "eq.gains")
        EQParameters.shared.update(gains: gains, enabled: enabled)
    }
}

struct EqualizerView: View {
    @State private var eq = EqualizerSettings.shared
    private let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    var body: some View {
        Form {
            Section {
                Toggle("Equalizer", isOn: $eq.enabled)
            }
            Section("Presets") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EQPreset.all) { preset in
                            Button(preset.name) { eq.choose(preset) }
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(eq.presetName == preset.name ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                                .foregroundStyle(eq.presetName == preset.name ? .white : .primary)
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            Section {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 6) {
                            Text(String(format: "%+.0f", eq.gains[i]))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { Double(eq.gains[i]) },
                                set: { eq.gains[i] = Float($0.rounded()); eq.presetName = "Custom" }
                            ), in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 180, height: 30)
                            .frame(width: 30, height: 180)
                            Text(labels[i]).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
                .disabled(!eq.enabled)
                .opacity(eq.enabled ? 1 : 0.4)
            } footer: {
                Text("Works on downloaded and streamed songs. Changes apply instantly.")
            }
        }
        .navigationTitle("Equalizer")
    }
}
