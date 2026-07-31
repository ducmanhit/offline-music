import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var playerBridge: OfflineMusicPlayerBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      playerBridge = OfflineMusicPlayerBridge(controller: controller)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

private final class OfflineMusicPlayerBridge {
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let equalizer = AVAudioUnitEQ(numberOfBands: 5)
  private var tracks: [[String: Any]] = []
  private var currentIndex = -1
  private var currentFile: AVAudioFile?
  private var sampleRate = 44_100.0
  private var startFrame: AVAudioFramePosition = 0
  private var duration = 0.0
  private var scheduleToken = 0
  private var controlsEnabled = true

  init(controller: FlutterViewController) {
    channel = FlutterMethodChannel(
      name: "cloud_music_offline/player",
      binaryMessenger: controller.binaryMessenger
    )

    configureAudioSession()
    configureEngine()
    configureRemoteCommands(enabled: true)

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    do {
      switch call.method {
      case "setQueue":
        tracks = args["tracks"] as? [[String: Any]] ?? []
        controlsEnabled = args["controlsEnabled"] as? Bool ?? true
        configureRemoteCommands(enabled: controlsEnabled)
        currentIndex = args["index"] as? Int ?? currentIndex
        result(nil)
      case "playIndex":
        let index = args["index"] as? Int ?? 0
        try play(index: index)
        result(nil)
      case "play":
        try ensureEngineStarted()
        player.play()
        updateNowPlaying()
        result(nil)
      case "pause":
        player.pause()
        updateNowPlaying()
        result(nil)
      case "seek":
        let seconds = args["seconds"] as? Double ?? 0
        try seek(to: seconds)
        result(nil)
      case "setEQ":
        let enabled = args["enabled"] as? Bool ?? true
        let bands = args["bands"] as? [Double] ?? [0, 0, 0, 0, 0]
        applyEQ(enabled: enabled, bands: bands)
        result(nil)
      case "setControlsEnabled":
        controlsEnabled = args["enabled"] as? Bool ?? true
        configureRemoteCommands(enabled: controlsEnabled)
        result(nil)
      case "getState":
        result([
          "isPlaying": player.isPlaying,
          "position": currentTime(),
          "duration": duration,
          "index": currentIndex
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "PLAYER_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  private func configureAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      NSLog("Audio session error: \(error.localizedDescription)")
    }
  }

  private func configureEngine() {
    engine.attach(player)
    engine.attach(equalizer)
    engine.connect(player, to: equalizer, format: nil)
    engine.connect(equalizer, to: engine.mainMixerNode, format: nil)

    let frequencies: [Float] = [60, 230, 910, 3_600, 14_000]
    for (index, band) in equalizer.bands.enumerated() {
      band.filterType = .parametric
      band.frequency = frequencies[index]
      band.bandwidth = 1
      band.gain = 0
      band.bypass = false
    }

    do {
      try ensureEngineStarted()
    } catch {
      NSLog("Audio engine error: \(error.localizedDescription)")
    }
  }

  private func ensureEngineStarted() throws {
    if !engine.isRunning {
      try engine.start()
    }
  }

  private func play(index: Int) throws {
    guard tracks.indices.contains(index) else { return }
    currentIndex = index
    startFrame = 0
    scheduleToken += 1
    player.stop()

    guard
      let path = tracks[index]["path"] as? String,
      FileManager.default.fileExists(atPath: path)
    else { return }

    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    currentFile = file
    sampleRate = file.processingFormat.sampleRate
    duration = Double(file.length) / sampleRate
    try ensureEngineStarted()
    scheduleCurrentFile()
    player.play()
    updateNowPlaying()
  }

  private func scheduleCurrentFile() {
    guard let file = currentFile else { return }
    scheduleToken += 1
    let token = scheduleToken
    let remainingFrames = max(0, file.length - startFrame)
    player.scheduleSegment(
      file,
      startingFrame: startFrame,
      frameCount: AVAudioFrameCount(remainingFrames),
      at: nil
    ) { [weak self] in
      DispatchQueue.main.async {
        guard let self, token == self.scheduleToken else { return }
        self.channel.invokeMethod("trackEnded", arguments: nil)
      }
    }
  }

  private func seek(to seconds: Double) throws {
    guard currentFile != nil else { return }
    let wasPlaying = player.isPlaying
    let clamped = min(max(seconds, 0), duration)
    startFrame = AVAudioFramePosition(clamped * sampleRate)
    scheduleToken += 1
    player.stop()
    scheduleCurrentFile()
    if wasPlaying {
      try ensureEngineStarted()
      player.play()
    }
    updateNowPlaying()
  }

  private func currentTime() -> Double {
    guard currentFile != nil else { return 0 }
    guard
      let nodeTime = player.lastRenderTime,
      let playerTime = player.playerTime(forNodeTime: nodeTime)
    else {
      return Double(startFrame) / sampleRate
    }
    let frame = startFrame + AVAudioFramePosition(playerTime.sampleTime)
    return min(max(Double(frame) / sampleRate, 0), duration)
  }

  private func applyEQ(enabled: Bool, bands: [Double]) {
    for (index, band) in equalizer.bands.enumerated() {
      let gain = index < bands.count ? bands[index] : 0
      band.gain = Float(min(max(gain, -12), 12))
      band.bypass = !enabled
    }
  }

  private func configureRemoteCommands(enabled: Bool) {
    UIApplication.shared.beginReceivingRemoteControlEvents()
    let commandCenter = MPRemoteCommandCenter.shared()

    commandCenter.playCommand.removeTarget(nil)
    commandCenter.pauseCommand.removeTarget(nil)
    commandCenter.togglePlayPauseCommand.removeTarget(nil)
    commandCenter.nextTrackCommand.removeTarget(nil)
    commandCenter.previousTrackCommand.removeTarget(nil)

    commandCenter.playCommand.isEnabled = enabled
    commandCenter.pauseCommand.isEnabled = enabled
    commandCenter.togglePlayPauseCommand.isEnabled = enabled
    commandCenter.nextTrackCommand.isEnabled = enabled
    commandCenter.previousTrackCommand.isEnabled = enabled

    guard enabled else { return }

    commandCenter.playCommand.addTarget { [weak self] _ in
      self?.player.play()
      self?.updateNowPlaying()
      return .success
    }
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      self?.player.pause()
      self?.updateNowPlaying()
      return .success
    }
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      self.player.isPlaying ? self.player.pause() : self.player.play()
      self.updateNowPlaying()
      return .success
    }
    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("remoteNext", arguments: nil)
      return .success
    }
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      self?.channel.invokeMethod("remotePrevious", arguments: nil)
      return .success
    }
  }

  private func updateNowPlaying() {
    guard tracks.indices.contains(currentIndex) else { return }
    let track = tracks[currentIndex]
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: track["title"] as? String ?? "Unknown title",
      MPMediaItemPropertyArtist: track["artist"] as? String ?? "Local file",
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime(),
      MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0
    ]
    if #available(iOS 10.0, *) {
      info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
}
