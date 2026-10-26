import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct Probe: Codable {
    let file: String
    let width: Int
    let height: Int
    let fps: Float
    let frames: Int
    let containsAlpha: Bool
    let alphaMin: Int
    let alphaMax: Int
    let transparentPixels: Int
    let translucentPixels: Int
}

func saveFrame(asset: AVAsset, time: Double, output: URL) throws {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "VideoProbe", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "VideoProbe", code: 2) }
}

func probe(_ path: String, outputDirectory: URL?, allFrames: Bool) throws -> Probe {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
        throw NSError(domain: "MissingVideoTrack", code: 1)
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    var frames = 0, minimum = 255, maximum = 0, transparent = 0, translucent = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            if frames == 0 {
                for y in 0..<height {
                    for x in 0..<width {
                        let a = Int(bytes[y * rowBytes + x * 4 + 3])
                        minimum = min(minimum, a); maximum = max(maximum, a)
                        if a == 0 { transparent += 1 }
                        else if a < 255 { translucent += 1 }
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        frames += 1
        if !allFrames { reader.cancelReading(); break }
    }
    if reader.status == .failed { throw reader.error! }
    if let directory = outputDirectory {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for t in [0.0, 2.5, 5.0, 7.5] where t < asset.duration.seconds {
            try saveFrame(asset: asset, time: t, output: directory.appendingPathComponent(String(format: "frame-%.1f.png", t)))
        }
    }
    return Probe(file: path, width: Int(track.naturalSize.width), height: Int(track.naturalSize.height),
                 fps: track.nominalFrameRate, frames: frames,
                 containsAlpha: track.hasMediaCharacteristic(.containsAlphaChannel),
                 alphaMin: minimum, alphaMax: maximum,
                 transparentPixels: transparent, translucentPixels: translucent)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    fputs("usage: video-probe report.json video.mov... [--export directory] [--first-only]\n", stderr)
    exit(2)
}
let report = URL(fileURLWithPath: args[0])
var inputs = Array(args.dropFirst()), export: URL?
let allFrames = !inputs.contains("--first-only")
inputs.removeAll { $0 == "--first-only" }
if let index = inputs.firstIndex(of: "--export"), inputs.count > index + 1 {
    export = URL(fileURLWithPath: inputs[index + 1])
    inputs.removeSubrange(index...index + 1)
}
var probes: [Probe] = []
for path in inputs {
    do {
        let result = try probe(path, outputDirectory: export, allFrames: allFrames)
        probes.append(result)
        print("PROBED \(URL(fileURLWithPath: path).lastPathComponent) \(result.width)x\(result.height) frames=\(result.frames) alpha=\(result.containsAlpha) range=\(result.alphaMin)...\(result.alphaMax)")
    } catch {
        fputs("FAILED \(path): \(error)\n", stderr)
        exit(1)
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(probes).write(to: report)
