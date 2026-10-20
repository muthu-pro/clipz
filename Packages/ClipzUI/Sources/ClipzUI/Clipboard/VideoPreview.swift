// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit
import AppKit

/// Inline player for video clips. Wraps AppKit's `AVPlayerView` (native
/// transport controls: play/pause, scrubber, volume, full screen) sized
/// to fit the card width — so a captured screen recording is watchable in
/// place instead of being a static thumbnail.
///
/// We deliberately use `AVPlayerView` via `NSViewRepresentable` rather
/// than SwiftUI's `VideoPlayer`: the latter aborts inside `_AVKit_SwiftUI`
/// generic-metadata instantiation when it's churned through a fast-
/// scrolling `LazyVStack`, which crashed the app the moment scrolling
/// reached a video. `AVPlayerView` has no such issue.
/// A seek request from a search hit: `token` makes two clicks on the same
/// timestamp distinct so SwiftUI's `onChange` fires each time.
struct VideoSeek: Equatable {
    var time: Double
    var token: Int
}

struct VideoPreview: View {
    let url: URL
    let maxHeight: CGFloat
    let fallbackTint: Color
    /// Seek here once the player is ready (used when a video search hit has
    /// a single matching frame — jump straight to it).
    var initialSeek: Double? = nil
    /// Seek on demand (used when there are multiple matches and the user
    /// clicks a specific one).
    var seek: VideoSeek? = nil

    @State private var player: AVPlayer?
    /// Natural aspect (w/h), resolved from the asset's video track so the
    /// player fits the card like the image previews. 16:9 until known.
    @State private var aspect: CGFloat = 16.0 / 9.0
    @State private var failed = false
    /// A seek requested before the player finished loading; applied once
    /// `prepare()` creates the player.
    @State private var pendingSeek: Double?

    var body: some View {
        Group {
            if let player, !failed {
                PlayerView(player: player)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: maxHeight)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                fallback
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
        .task(id: url) { await prepare() }
        .onChange(of: seek) { _, newValue in
            if let newValue { requestSeek(newValue.time) }
        }
        .onDisappear { teardown() }
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(fallbackTint.opacity(0.12))
            Image(systemName: failed ? "film.stack" : "film")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(fallbackTint)
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(maxHeight, 200))
    }

    private func prepare() async {
        // Reset for a reused row (LazyVStack recycles this view for a
        // different clip while scrolling).
        teardown()
        failed = false

        guard FileManager.default.fileExists(atPath: url.path) else {
            failed = true
            return
        }

        let asset = AVURLAsset(url: url)
        // Resolve display aspect from the first video track, honoring any
        // rotation baked into the preferred transform.
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let oriented = size.applying(transform)
            let w = abs(oriented.width)
            let h = abs(oriented.height)
            if w > 0, h > 0 { aspect = w / h }
        }

        // The task can be cancelled mid-load if the row scrolled away.
        if Task.isCancelled { return }
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = newPlayer

        // Apply any seek requested while we were loading, or the one-shot
        // initial seek (single-match search hit).
        if let t = pendingSeek ?? initialSeek {
            seek(newPlayer, to: t)
            pendingSeek = nil
        }
    }

    /// Seek the live player if it exists, else stash the request until
    /// `prepare()` finishes building it.
    private func requestSeek(_ seconds: Double) {
        if let player {
            seek(player, to: seconds)
        } else {
            pendingSeek = seconds
        }
    }

    /// Jump to `seconds` exactly and pause on that frame — the user is
    /// inspecting where their search term appeared, not playing yet.
    private func seek(_ player: AVPlayer, to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.pause()
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func teardown() {
        player?.pause()
        player = nil
    }
}

/// Minimal AppKit player-view bridge. Keeps the `AVPlayerView` alive and
/// just swaps its `player` when the SwiftUI state changes.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
