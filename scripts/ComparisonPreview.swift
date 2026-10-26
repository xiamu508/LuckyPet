import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreText

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3 else {
    fputs("usage: comparison-preview before.mov after.mov output.mp4\n", stderr)
    exit(2)
}
let before = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: args[0])))
let after = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: args[1])))
for generator in [before, after] {
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
}
let width = 1024, height = 640
let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
ffmpeg.arguments = ["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "1024x640",
                   "-r", "24", "-i", "-", "-c:v", "libx264", "-crf", "17", "-preset", "fast",
                   "-pix_fmt", "yuv420p", "-movflags", "+faststart", args[2]]
let pipe = Pipe()
ffmpeg.standardInput = pipe
try ffmpeg.run()
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
func label(_ text: String, at point: CGPoint, context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 21, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.93, green: 0.96, blue: 1, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = point
    CTLineDraw(line, context)
}
for index in 0..<120 {
    try autoreleasepool {
        let time = CMTime(value: Int64(index), timescale: 24)
        let images = [try before.copyCGImage(at: time, actualTime: nil),
                      try after.copyCGImage(at: time, actualTime: nil)]
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width*4, space: colorSpace,
                                          bitmapInfo: bitmapInfo) else { throw NSError(domain: "Bitmap", code: 1) }
            context.setFillColor(CGColor(red: 0.09, green: 0.13, blue: 0.18, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            for (side, image) in images.enumerated() {
                let density = CGFloat(image.width) / 1280
                let crop = CGRect(x: 384*density, y: 90*density, width: 512*density, height: 600*density)
                guard let clipped = image.cropping(to: crop) else { throw NSError(domain: "Crop", code: 2) }
                let x = CGFloat(side * 512 + 16)
                context.setFillColor(CGColor(red: 0.204, green: 0.259, blue: 0.322, alpha: 1))
                let panel = CGRect(x: x, y: 16, width: 480, height: 562.5)
                context.fill(panel)
                context.draw(clipped, in: panel)
            }
            label("BEFORE - original app", at: CGPoint(x: 16, y: 605), context: context)
            label("AFTER - repaired HD app", at: CGPoint(x: 528, y: 605), context: context)
        }
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }
}
try pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
guard ffmpeg.terminationStatus == 0 else { exit(ffmpeg.terminationStatus) }
print("Saved 5-second comparison at 24 fps: \(args[2])")
