import AVFoundation
import AVKit
import SwiftUI

let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

func isVideo(_ url: URL) -> Bool {
    videoExtensions.contains(url.pathExtension.lowercased())
}

struct VideoInfo {
    let frame: CGImage
    /// The picture's size in pixels, upright.
    let pixelSize: CGSize
    let duration: Double
}

/// A frame, the size and the length of a video. AVFoundation only answers
/// asynchronously now; the line asks synchronously, so this waits for it. It
/// never needs the main thread, so waiting there cannot deadlock.
func loadVideoInfo(_ url: URL, maxPixels: Int) -> VideoInfo? {
    final class Box: @unchecked Sendable { var info: VideoInfo? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return }
        let upright = natural.applying(transform)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        // A moment in, so the frame is not the black one some recordings start with.
        let at = CMTime(seconds: min(0.5, duration.seconds / 2), preferredTimescale: 600)
        guard let (frame, _) = try? await generator.image(at: at) else { return }
        box.info = VideoInfo(frame: frame, pixelSize: CGSize(width: abs(upright.width), height: abs(upright.height)),
                             duration: duration.seconds)
    }
    _ = done.wait(timeout: .now() + 5)
    return box.info
}

/// "0:07", "1:23", "1:02:03".
func formatDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600, m = total / 60 % 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// A muted video playing over and over, for the large view under the line.
@MainActor
final class LoopingPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL) {
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

/// Just the picture of a player, no controls.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
