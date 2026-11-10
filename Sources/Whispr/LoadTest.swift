import Foundation
import CoreML
import WhisperKit

/// `--load-test [--model m] [--no-prewarm]`: times WhisperKit model load twice in one process
/// (first = whatever the Core ML/ANE cache gives us, second = guaranteed warm), samples
/// ANECompilerService CPU during each, and counts e5 bundle cache entries before/after, so
/// "did the compile run?" is answered by evidence instead of by wall clock alone.
enum LoadTest {
    /// Core ML keeps the ANE-specialised model here, keyed by OS build. Outside the app bundle.
    static var e5Cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.openwispr.app")
            .appendingPathComponent("com.apple.e5rt.e5bundlecache")
    }

    static func e5Bundles() -> Int {
        let e = FileManager.default.enumerator(at: e5Cache, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL])?.filter { $0.pathExtension == "bundle" }.count ?? 0
    }

    /// Peak ANECompilerService %CPU seen by `ps`. Polled once a second until cancelled.
    final class CompilerSampler: @unchecked Sendable {
        private(set) var peak = 0.0
        private var task: Task<Void, Never>?
        func start() {
            task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/ps")
                    p.arguments = ["-A", "-o", "%cpu=,comm="]
                    let out = Pipe(); p.standardOutput = out
                    try? p.run(); p.waitUntilExit()
                    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    for line in text.split(separator: "\n") where line.contains("ANECompilerService") {
                        let cpu = Double(line.split(separator: " ").first ?? "") ?? 0
                        if let self, cpu > self.peak { self.peak = cpu }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        func stop() -> Double { task?.cancel(); return peak }
    }

    static func run(model: String, prewarm: Bool) {
        Task { @MainActor in
            setvbuf(stdout, nil, _IONBF, 0)
            let folder = ModelManager.localFolder(model)
            let c = ModelComputeOptions()
            func name(_ u: MLComputeUnits) -> String {
                switch u {
                case .cpuOnly: "cpu"
                case .cpuAndGPU: "cpu+gpu"
                case .cpuAndNeuralEngine: "cpu+ane"
                case .all: "all"
                @unknown default: "?"
                }
            }
            print("load-test: model=\(model) prewarm=\(prewarm) path=\(folder.path)")
            print("load-test: computeUnits mel=\(name(c.melCompute)) encoder=\(name(c.audioEncoderCompute)) decoder=\(name(c.textDecoderCompute))")
            print("load-test: e5 cache=\(e5Cache.path)")
            for pass in ["first", "second"] {
                let before = e5Bundles()
                let sampler = CompilerSampler(); sampler.start()
                let t0 = Date()
                do {
                    _ = try await WhisperKit(modelFolder: folder.path, verbose: false, prewarm: prewarm, load: true, download: false)
                } catch {
                    print("load-test FAIL: \(error)"); exit(1)
                }
                let secs = Date().timeIntervalSince(t0)
                let peak = sampler.stop()
                let after = e5Bundles()
                let compiled = after > before || peak >= 50
                print(String(format: "load-test: %@ load=%.1fs aneCompilerPeakCPU=%.0f%% e5bundles=%d->%d compile=%@",
                             pass, secs, peak, before, after, compiled ? "yes" : "no"))
            }
            exit(0)
        }
        dispatchMain()
    }
}
