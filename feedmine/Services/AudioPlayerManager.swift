import AVFoundation
import MediaPlayer
import Observation

@MainActor
@Observable
final class AudioPlayerManager {
    static let shared = AudioPlayerManager()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var lastSavedAt: TimeInterval = 0
    private var timeControlObserver: NSKeyValueObservation?
    private var lastNowPlayingUpdate: TimeInterval = 0
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    /// Only the AVPlayer end event marks an episode as completed. This guard
    /// prevents queued time callbacks and stop() from recreating a position
    /// after completion without guessing that "near the end" means finished.
    private var completedItemID: String?
    /// Invalidates callbacks captured by a player/item that has since been
    /// replaced or stopped.
    private var playbackGeneration: UInt64 = 0

    private(set) var currentItem: FeedItem?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var scrubTime: TimeInterval = 0   // drag target; committed on release (#32)
    private(set) var lastPlaybackError: String?

    private let defaults = UserDefaults.standard
    private static let savedItemIDKey = "lastPodcastItemID"
    private static let savedPositionKey = "lastPodcastPosition"

    private init() {
        setupAudioSession()
        setupRemoteCommandCenter()
        observeAudioNotifications()
    }

    // MARK: - Audio Session (background playback)

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            Log.feed.error("AudioSession category failed: \(error)")
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.feed.error("AudioSession activate failed: \(error)")
        }
    }

    // MARK: - Remote Command Center (lock screen / Control Center)

    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isPlaying == true { self?.togglePlayPause() }
            }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        cc.skipForwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seekForward(15) }
            return .success
        }
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seekBackward(15) }
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: e.positionTime) }
            return .success
        }
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
    }

    // MARK: - Audio Notifications (interruption / route change)

    private func observeAudioNotifications() {
        let session = AVAudioSession.sharedInstance()

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw, optionRaw: optionRaw) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reasonRaw: reasonRaw) }
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionRaw: UInt?) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            player?.pause()
            isPlaying = false
            updateNowPlaying(force: true)
        case .ended:
            if let optionRaw,
               AVAudioSession.InterruptionOptions(rawValue: optionRaw).contains(.shouldResume) {
                activateSession()
                player?.play()
                isPlaying = true
                updateNowPlaying(force: true)
            }
        @unknown default: break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        if reason == .oldDeviceUnavailable {
            player?.pause()
            isPlaying = false
            updateNowPlaying()
        }
    }

    // MARK: - Now Playing Info

    private func updateNowPlaying(force: Bool = false) {
        // Throttle: skip rapid updates from 0.5s time observer (#29)
        if !force {
            let now = Date().timeIntervalSince1970
            guard now - lastNowPlayingUpdate >= 1.0 else { return }
            lastNowPlayingUpdate = now
        }

        guard let item = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let episodeTitle = item.title
        let showTitle = item.sourceTitle
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episodeTitle,
            MPMediaItemPropertyArtist: showTitle,
            MPMediaItemPropertyAlbumTitle: "Feedmine",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: max(duration, 1),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyAssetURL: item.audioPlaybackURL?.absoluteString ?? "",
            "feedmineItemID": item.id,  // guards against stale artwork from rapid skips
        ]
        // Add excerpt as description for richer lock screen info
        if !item.excerpt.isEmpty {
            info[MPMediaItemPropertyComments] = item.excerpt
        }

        // Pre-load artwork data on MainActor, then dispatch the
        // MPMediaItemArtwork creation off MainActor so the requestHandler
        // closure doesn't inherit @MainActor isolation.
        if let urlString = item.bestImageURL ?? item.imageURL,
           let url = URL(string: urlString),
           let data = ImageCache.shared.cachedImageData(for: url) {
            let capturedID = item.id  // guard against rapid episode switches
            Task.detached { [info] in
                let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in
                    UIImage(data: data) ?? UIImage()
                }
                var updated = info
                updated[MPMediaItemPropertyArtwork] = artwork
                // Only publish if the now-playing item hasn't changed since
                // we captured the ID. Otherwise a fast skip leaves stale
                // artwork on the lock screen for the new episode.
                if let nowPlayingID = MPNowPlayingInfoCenter.default().nowPlayingInfo?["feedmineItemID"] as? String,
                   nowPlayingID == capturedID {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    // MARK: - Position Persistence

    func savePosition() {
        guard let id = currentItem?.id,
              currentTime > 0,
              completedItemID != id else { return }
        defaults.set(id, forKey: Self.savedItemIDKey)
        // Per-episode position (#30): keyed by item ID so switching between
        // podcasts preserves position for each independently.
        defaults.set(currentTime, forKey: "\(Self.savedPositionKey).\(id)")
    }

    private func clearSavedPosition(for itemID: String) {
        defaults.removeObject(forKey: "\(Self.savedPositionKey).\(itemID)")
        if defaults.string(forKey: Self.savedItemIDKey) == itemID {
            defaults.removeObject(forKey: Self.savedItemIDKey)
        }
    }

    private func restorePositionIfNeeded(for item: FeedItem) {
        guard completedItemID != item.id else { return }
        let savedTime = defaults.double(forKey: "\(Self.savedPositionKey).\(item.id)")
        guard savedTime > 5 else { return }

        let generation = playbackGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  self.playbackGeneration == generation,
                  self.currentItem?.id == item.id,
                  self.completedItemID != item.id else { return }
            self.seek(to: savedTime)
        }
    }

    private func prepareCompletedItemForReplay() {
        guard let id = currentItem?.id, completedItemID == id else { return }
        completedItemID = nil
        clearSavedPosition(for: id)
        lastSavedAt = 0
        currentTime = 0
        scrubTime = 0
        player?.seek(to: .zero)
    }

    // MARK: - Playback

    @discardableResult
    func play(item: FeedItem) -> Bool {
        lastPlaybackError = nil

        guard let url = item.audioPlaybackURL else {
            lastPlaybackError = "Audio unavailable"
            return false
        }

        if currentItem?.id == item.id {
            prepareCompletedItemForReplay()
            activateSession()
            player?.play()
            isPlaying = true
            updateNowPlaying(force: true)
            return true
        }

        stop()
        playbackGeneration &+= 1
        let generation = playbackGeneration
        completedItemID = nil
        lastSavedAt = 0
        activateSession()
        currentItem = item
        duration = item.duration ?? 0

        let playerItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: playerItem)
        player = p

        // Observe timeControlStatus as primary playing-state source (#28)
        timeControlObserver = p.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentItem?.id == item.id else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                case .paused:
                    self.isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
                }
            }
        }
        p.play()
        updateNowPlaying()

        // Restore saved position for this item
        restorePositionIfNeeded(for: item)

        // Surface load failures instead of sitting silently "playing".
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            let failed = playerItem.status == .failed
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentItem?.id == item.id else { return }
                if failed {
                    self.isPlaying = false
                    self.lastPlaybackError = "Playback failed"
                    self.updateNowPlaying()
                }
            }
        }

        // Completion is event-driven. Never infer completion from elapsed time:
        // pausing in the final seconds must keep the real resume position.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentItem?.id == item.id else { return }
                self.completedItemID = item.id
                self.isPlaying = false
                if self.duration > 0 {
                    self.currentTime = self.duration
                    self.scrubTime = self.duration
                }
                self.lastSavedAt = self.currentTime
                self.clearSavedPosition(for: item.id)
                self.updateNowPlaying(force: true)
            }
        }

        // Periodic time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == generation,
                      self.currentItem?.id == item.id,
                      self.completedItemID != item.id else { return }
                // AVPlayerItem.time is indefinite (NaN) before the item is ready and
                // around seeks; storing it would reach Int(_:) in formatTime and trap.
                if time.seconds.isFinite {
                    self.currentTime = time.seconds
                }
                if self.duration == 0,
                   let dur = self.player?.currentItem?.duration.seconds,
                   dur.isFinite {
                    self.duration = dur
                }
                self.updateNowPlaying()
                // Persist position every ~5 seconds using elapsed check (#31)
                if self.currentTime - self.lastSavedAt >= 5, self.currentTime > 0 {
                    self.savePosition()
                    self.lastSavedAt = self.currentTime
                }
            }
        }

        return true
    }

    func togglePlayPause() {
        guard player != nil else { return }
        activateSession()
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            prepareCompletedItemForReplay()
            player?.play()
            isPlaying = true
        }
        updateNowPlaying(force: true)
    }

    func seek(to time: TimeInterval) {
        if let id = currentItem?.id,
           completedItemID == id,
           (duration <= 0 || time < max(0, duration - 0.5)) {
            completedItemID = nil
            clearSavedPosition(for: id)
            lastSavedAt = 0
        }
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
        scrubTime = time
        updateNowPlaying()
    }

    /// Commit scrubber drag position — seek only on release (#32)
    func commitScrub() {
        guard abs(scrubTime - currentTime) > 0.5 else { return }
        seek(to: scrubTime)
    }

    func seekForward(_ seconds: Double = 15) {
        let new = min(currentTime + seconds, duration)
        seek(to: new)
    }

    func seekBackward(_ seconds: Double = 15) {
        let new = max(currentTime - seconds, 0)
        seek(to: new)
    }

    func stop() {
        // savePosition() is deliberately a no-op for an item that emitted the
        // completion event, so stopping/switching cannot resurrect progress.
        savePosition()
        playbackGeneration &+= 1
        player?.pause()
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()
        timeControlObserver?.invalidate()
        player = nil
        timeObserver = nil
        endObserver = nil
        statusObserver = nil
        timeControlObserver = nil
        currentItem = nil
        completedItemID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        scrubTime = 0
        lastSavedAt = 0
        updateNowPlaying(force: true)
    }

    func clearPlaybackError() {
        lastPlaybackError = nil
    }

    // MARK: - Helpers

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var currentTimeFormatted: String { formatTime(currentTime) }
    var durationFormatted: String { formatTime(duration) }

    private func formatTime(_ t: TimeInterval) -> String {
        // Int(_:) traps on NaN/inf, and both duration and position come from
        // player metadata (AVPlayerItem, feed-supplied episode duration).
        guard t.isFinite else { return "0:00" }
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
