// Turns a screen recording into a looping GIF for the README.
// swift scripts/mov-to-gif.swift <in.mov> <out.gif> [width=1280] [fps=15]
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: mov-to-gif <in.mov> <out.gif> [width] [fps]"); exit(1) }
let width = args.count > 3 ? Double(args[3])! : 1280
let fps = args.count > 4 ? Double(args[4])! : 15

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let duration = CMTimeGetSeconds(try await asset.load(.duration))
guard duration > 0 else { print("can't read \(args[1])"); exit(1) }
let gen = AVAssetImageGenerator(asset: asset)
gen.maximumSize = CGSize(width: width, height: width * 4)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

let count = Int(duration * fps)
let url = URL(fileURLWithPath: args[2]) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, count, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
for i in 0..<count {
    let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
    guard let image = try? await gen.image(at: t).image else { continue }
    CGImageDestinationAddImage(dest, image, frame)
}
guard CGImageDestinationFinalize(dest) else { print("couldn't write \(args[2])"); exit(1) }
print("wrote \(args[2]) (\(count) frames)")
