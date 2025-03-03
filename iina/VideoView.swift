//
//  VideoView.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa


class VideoView: NSView {

  weak var player: PlayerCore!
  var link: CVDisplayLink?

  lazy var videoLayer: ViewLayer = {
    let layer = ViewLayer(self)
    return layer
  }()

  @Atomic var isUninited = false

  var draggingTimer: Timer?

  // whether auto show playlist is triggered
  var playlistShown: Bool = false

  // variable for tracing mouse position when dragging in the view
  var lastMousePosition: NSPoint?

  var hasPlayableFiles: Bool = false

  // cached indicator to prevent unnecessary updates of DisplayLink
  var currentDisplay: UInt32?

  private var displayIdleTimer: Timer?

  private lazy var hdrSubsystem = Logger.makeSubsystem("hdr\(player.playerNumber)")

  lazy var subsystem = Logger.makeSubsystem("video\(player.playerNumber)")

  static let SRGB = CGColorSpaceCreateDeviceRGB()

  // MARK: - Attributes

  override var mouseDownCanMoveWindow: Bool {
    return true
  }

  override var isOpaque: Bool {
    return true
  }

  // MARK: - Init

  init(frame: CGRect, player: PlayerCore) {
    self.player = player
    super.init(frame: frame)

    // set up layer
    layer = videoLayer
    videoLayer.colorspace = VideoView.SRGB
    videoLayer.contentsScale = NSScreen.main!.backingScaleFactor
    wantsLayer = true

    // other settings
    autoresizingMask = [.width, .height]
    wantsBestResolutionOpenGLSurface = true
    wantsExtendedDynamicRangeOpenGLSurface = true

    // dragging init
    registerForDraggedTypes([.nsFilenames, .nsURL, .string])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Uninitialize this view.
  ///
  /// This method will stop drawing and free the mpv render context. This is done before sending a quit command to mpv.
  /// - Important: Once mpv has been instructed to quit accessing the mpv core can result in a crash, therefore locks must be
  ///     used to coordinate uninitializing the view so that other threads do not attempt to use the mpv core while it is shutting down.
  func uninit() {
    player.mpv.lockAndSetOpenGLContext()
    defer { player.mpv.unlockOpenGLContext() }
    $isUninited.withLock() { isUninited in
      guard !isUninited else { return }
      isUninited = true

      stopDisplayLink()
      player.mpv.mpvUninitRendering()
    }
  }

  deinit {
    uninit()
  }

  override func draw(_ dirtyRect: NSRect) {
    // do nothing
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  /// Workaround for issue #4183, Cursor remains visible after resuming playback with the touchpad using secondary click
  ///
  /// See `MainWindowController.workaroundCursorDefect` and the issue for details on this workaround.
  override func rightMouseDown(with event: NSEvent) {
    player.mainWindow.rightMouseDown(with: event)
    super.rightMouseDown(with: event)
  }

  /// Workaround for issue #3211, Legacy fullscreen is broken (11.0.1)
  ///
  /// Changes in Big Sur broke the legacy full screen feature. The `MainWindowController` method `legacyAnimateToWindowed`
  /// had to be changed to get this feature working again. Under Big Sur that method now calls the AppKit method
  /// `window.styleMask.insert(.titled)`. This is a part of restoring the window's style mask to the way it was before entering
  /// full screen mode. A side effect of restoring the window's title is that AppKit stops calling `MainWindowController.mouseUp`.
  /// This appears to be a defect in the Cocoa framework. See the issue for details. As a workaround the mouse up event is caught in
  /// the view which then calls the window controller's method.
  override func mouseUp(with event: NSEvent) {
    // Only check for Big Sur or greater, not if the preference use legacy full screen is enabled as
    // that can be changed while running and once the window title has been removed and added back
    // AppKit malfunctions from then on. The check for running under Big Sur or later isn't really
    // needed as it would be fine to always call the controller. The check merely makes it clear
    // that this is only needed due to macOS changes starting with Big Sur.
    if #available(macOS 11, *) {
      player.mainWindow.mouseUp(with: event)
    } else {
      super.mouseUp(with: event)
    }
  }

  // MARK: Drag and drop

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    hasPlayableFiles = (player.acceptFromPasteboard(sender, isPlaylist: true) == .copy)
    return player.acceptFromPasteboard(sender)
  }

  @objc func showPlaylist() {
    player.mainWindow.menuShowPlaylistPanel(.dummy)
    playlistShown = true
  }

  private func createTimer() {
    draggingTimer = Timer.scheduledTimer(timeInterval: TimeInterval(0.3), target: self,
                                         selector: #selector(showPlaylist), userInfo: nil, repeats: false)
  }

  private func destroyTimer() {
    if let draggingTimer = draggingTimer {
      draggingTimer.invalidate()
    }
    draggingTimer = nil
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {

    guard !player.isInMiniPlayer && !playlistShown && hasPlayableFiles else { return super.draggingUpdated(sender) }

    func inTriggerArea(_ point: NSPoint?) -> Bool {
      guard let point = point, let frame = player.mainWindow.window?.frame else { return false }
      return point.x > (frame.maxX - frame.width * 0.2)
    }

    let position = NSEvent.mouseLocation

    if position != lastMousePosition {
      if inTriggerArea(lastMousePosition) {
        destroyTimer()
      }
      if inTriggerArea(position) {
        createTimer()
      }
      lastMousePosition = position
    }

    return super.draggingUpdated(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    destroyTimer()
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    if playlistShown {
      player.mainWindow.hideSideBar()
    }
    playlistShown = false
    lastMousePosition = nil
  }

  // MARK: Display link

  /// Returns a [Core Video](https://developer.apple.com/documentation/corevideo) display link.
  ///
  /// If a display link has already been created then that link will be returned, otherwise a display link will be created and returned.
  ///
  /// - Note: Issue [#4520](https://github.com/iina/iina/issues/4520) reports a case where it appears the call to
  ///[CVDisplayLinkCreateWithActiveCGDisplays](https://developer.apple.com/documentation/corevideo/1456863-cvdisplaylinkcreatewithactivecgd) is failing. In case that failure is
  ///encountered again this method is careful to log any failure and include the [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes) in the alert displayed
  /// by `Logger.fatal`.
  /// - Returns: A [CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k).
  private func obtainDisplayLink() -> CVDisplayLink {
    if let link = link { return link }
    let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)
    checkResult(result, "CVDisplayLinkCreateWithActiveCGDisplays")
    guard let link = link else {
      Logger.fatal("Cannot create display link: \(codeToString(result)) (\(result))")
    }
    return link
  }

  func startDisplayLink() {
    let link = obtainDisplayLink()
    guard !CVDisplayLinkIsRunning(link) else { return }
    updateDisplayLink()
    checkResult(CVDisplayLinkSetOutputCallback(link, displayLinkCallback, mutableRawPointerOf(obj: self)),
                "CVDisplayLinkSetOutputCallback")
    checkResult(CVDisplayLinkStart(link), "CVDisplayLinkStart")
    log("Display link started", level: .verbose)
  }

  @objc func stopDisplayLink() {
    guard let link = link, CVDisplayLinkIsRunning(link) else { return }
    checkResult(CVDisplayLinkStop(link), "CVDisplayLinkStop")
    log("Display link stopped", level: .verbose)
  }

  // This should only be called if the window has changed displays
  func updateDisplayLink() {
    guard let window = window, let link = link, let screen = window.screen else { return }
    let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32

    // Do nothing if on the same display
    if (currentDisplay == displayId) { return }
    currentDisplay = displayId

    checkResult(CVDisplayLinkSetCurrentCGDisplay(link, displayId), "CVDisplayLinkSetCurrentCGDisplay")
    let actualData = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
    let nominalData = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
    var actualFps: Double = 0

    if (nominalData.flags & Int32(CVTimeFlags.isIndefinite.rawValue)) < 1 {
      let nominalFps = Double(nominalData.timeScale) / Double(nominalData.timeValue)

      if actualData > 0 {
        actualFps = 1/actualData
      }

      if abs(actualFps - nominalFps) > 1 {
        log("Falling back to nominal display refresh rate: \(nominalFps) from \(actualFps)")
        actualFps = nominalFps
      }
    } else {
      log("Falling back to standard display refresh rate: 60 from \(actualFps)")
      actualFps = 60
    }
    player.mpv.setDouble(MPVOption.Video.displayFpsOverride, actualFps)

    refreshEdrMode()
  }

  // MARK: - Reducing Energy Use

  /// Starts the display link if it has been stopped in order to save energy.
  func displayActive() {
    displayIdleTimer?.invalidate()
    startDisplayLink()
  }

  /// Reduces energy consumption when the display link does not need to be running.
  ///
  /// Adherence to energy efficiency best practices requires that IINA be absolutely idle when there is no reason to be performing any
  /// processing, such as when playback is paused. The [CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k)
  /// is a high-priority thread that runs at the refresh rate of a display. If the display is not being updated it is desirable to stop the
  /// display link in order to not waste energy on needless processing.
  ///
  /// However, IINA will pause playback for short intervals when performing certain operations. In such cases it does not make sense to
  /// shutdown the display link only to have to immediately start it again. To avoid this a `Timer` is used to delay shutting down the
  /// display link. If playback becomes active again before the timer has fired then the `Timer` will be invalidated and the display link
  /// will not be shutdown.
  ///
  /// - Note: In addition to playback the display link must be running for operations such seeking, stepping and entering and leaving
  ///         full screen mode.
  func displayIdle() {
    displayIdleTimer?.invalidate()
    // The time of 6 seconds was picked to match up with the time QuickTime delays once playback is
    // paused before stopping audio. As mpv does not provide an event indicating a frame step has
    // completed the time used must not be too short or will catch mpv still drawing when stepping.
    displayIdleTimer = Timer(timeInterval: 6.0, target: self, selector: #selector(stopDisplayLink), userInfo: nil, repeats: false)
    RunLoop.current.add(displayIdleTimer!, forMode: .default)
  }

  private func setICCProfile() {
    let screenColorSpace = player.mainWindow.window?.screen?.colorSpace
    if !Preference.bool(for: .loadIccProfile) {
      logHDR("Not using ICC profile due to user preference")
      player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
    } else if let screenColorSpace {
      let name = screenColorSpace.localizedName ?? "unnamed"
      logHDR("Using the ICC profile of the color space \(name)")
      player.mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, true)
      videoLayer.setRenderICCProfile(screenColorSpace)
    }

    let sdrColorSpace = screenColorSpace?.cgColorSpace ?? VideoView.SRGB
    if videoLayer.colorspace != sdrColorSpace {
      let name: String = {
        if let name = sdrColorSpace.name { return name as String }
        if let screenColorSpace, let name = screenColorSpace.localizedName { return name }
        return "Unspecified"
      }()
      log("Setting layer color space to \(name)")
      videoLayer.colorspace = sdrColorSpace
      videoLayer.wantsExtendedDynamicRangeContent = false
      player.mpv.setString(MPVOption.GPURendererOptions.targetTrc, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.targetPrim, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.targetPeak, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.toneMapping, "auto")
      player.mpv.setString(MPVOption.GPURendererOptions.toneMappingParam, "default")
      player.mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, false)
    }
  }

  // MARK: - Error Logging

  /// Check the result of calling a [Core Video](https://developer.apple.com/documentation/corevideo) method.
  ///
  /// If the result code is not [kCVReturnSuccess](https://developer.apple.com/documentation/corevideo/kcvreturnsuccess)
  /// then a warning message will be logged. Failures are only logged because previously the result was not checked. We want to see if
  /// calls have been failing before taking any action other than logging.
  /// - Note: Error checking was added in response to issue [#4520](https://github.com/iina/iina/issues/4520)
  ///         where a core video method unexpectedly failed.
  /// - Parameters:
  ///   - result: The [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes)
  ///           returned by the core video method.
  ///   - method: The core video method that returned the result code.
  private func checkResult(_ result: CVReturn, _ method: String) {
    guard result != kCVReturnSuccess else { return }
    log("Core video method \(method) returned: \(codeToString(result)) (\(result))", level: .warning)
  }

  /// Return a string describing the given [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes).
  ///
  /// What is needed is an API similar to `strerr` for a `CVReturn` code. A search of Apple documentation did not find such a
  /// method.
  /// - Parameter code: The [CVReturn](https://developer.apple.com/documentation/corevideo/cvreturn)
  ///           [result code](https://developer.apple.com/documentation/corevideo/1572713-result_codes)
  ///           returned by a core video method.
  /// - Returns: A description of what the code indicates.
  private func codeToString(_ code: CVReturn) -> String {
    switch code {
    case kCVReturnSuccess:
      return "Function executed successfully without errors"
    case kCVReturnInvalidArgument:
      return "At least one of the arguments passed in is not valid. Either out of range or the wrong type"
    case kCVReturnAllocationFailed:
      return "The allocation for a buffer or buffer pool failed. Most likely because of lack of resources"
    case kCVReturnInvalidDisplay:
      return "A CVDisplayLink cannot be created for the given DisplayRef"
    case kCVReturnDisplayLinkAlreadyRunning:
      return "The CVDisplayLink is already started and running"
    case kCVReturnDisplayLinkNotRunning:
      return "The CVDisplayLink has not been started"
    case kCVReturnDisplayLinkCallbacksNotSet:
      return "The output callback is not set"
    case kCVReturnInvalidPixelFormat:
      return "The requested pixelformat is not supported for the CVBuffer type"
    case kCVReturnInvalidSize:
      return "The requested size (most likely too big) is not supported for the CVBuffer type"
    case kCVReturnInvalidPixelBufferAttributes:
      return "A CVBuffer cannot be created with the given attributes"
    case kCVReturnPixelBufferNotOpenGLCompatible:
      return "The Buffer cannot be used with OpenGL as either its size, pixelformat or attributes are not supported by OpenGL"
    case kCVReturnPixelBufferNotMetalCompatible:
      return "The Buffer cannot be used with Metal as either its size, pixelformat or attributes are not supported by Metal"
    case kCVReturnWouldExceedAllocationThreshold:
      return """
        The allocation request failed because it would have exceeded a specified allocation threshold \
        (see kCVPixelBufferPoolAllocationThresholdKey)
        """
    case kCVReturnPoolAllocationFailed:
      return "The allocation for the buffer pool failed. Most likely because of lack of resources. Check if your parameters are in range"
    case kCVReturnInvalidPoolAttributes:
      return "A CVBufferPool cannot be created with the given attributes"
    case kCVReturnRetry:
      return "a scan hasn't completely traversed the CVBufferPool due to a concurrent operation. The client can retry the scan"
    default:
      return "Unrecognized core video return code"
    }
  }
}

// MARK: - HDR

extension VideoView {
  func refreshEdrMode() {
    guard player.mainWindow.loaded, player.info.state.loaded, let displayId = currentDisplay else { return }
    if let screen = self.window?.screen {
      NSScreen.log("Refreshing HDR for \(player.subsystem.rawValue) @ display\(displayId)", screen,
                   subsystem: hdrSubsystem)
    }
    let edrEnabled = requestEdrMode()
    let edrAvailable = edrEnabled != false
    if player.info.hdrAvailable != edrAvailable {
      player.mainWindow.quickSettingView.setHdrAvailability(to: edrAvailable)
    }
    if edrEnabled != true { setICCProfile() }
  }

  func requestEdrMode() -> Bool? {
    guard let mpv = player.mpv else { return false }

    guard let primaries = mpv.getString(MPVProperty.videoParamsPrimaries), let gamma = mpv.getString(MPVProperty.videoParamsGamma) else {
      logHDR("Video gamma and primaries not available")
      return false
    }
  
    let peak = mpv.getDouble(MPVProperty.videoParamsSigPeak)
    logHDR("Video gamma=\(gamma), primaries=\(primaries), sig_peak=\(peak)")

    // HDR videos use a Hybrid Log Gamma (HLG) or a Perceptual Quantization (PQ) transfer function.
    guard gamma == "hlg" || gamma == "pq" else { return false }

    var name: CFString? = nil
    switch primaries {
    case "display-p3":
      if #available(macOS 10.15.4, *) {
        name = CGColorSpace.displayP3_PQ
      } else {
        name = CGColorSpace.displayP3_PQ_EOTF
      }

    case "bt.2020":
      if #available(macOS 11.0, *) {
        name = CGColorSpace.itur_2100_PQ
      } else if #available(macOS 10.15.4, *) {
        name = CGColorSpace.itur_2020_PQ
      } else {
        name = CGColorSpace.itur_2020_PQ_EOTF
      }

    case "bt.709":
      return false // SDR

    default:
      logHDR("Unsupported color space: gamma=\(gamma) primaries=\(primaries)", level: .warning)
      return false
    }

    guard (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0 else {
      logHDR("HDR video was found but the display does not support EDR mode")
      return false
    }

    guard player.info.hdrEnabled else { return nil }

    logHDR("Using HDR color space instead of ICC profile")

    videoLayer.wantsExtendedDynamicRangeContent = true
    videoLayer.colorspace = CGColorSpace(name: name!)
    mpv.setFlag(MPVOption.GPURendererOptions.iccProfileAuto, false)
    mpv.setString(MPVOption.GPURendererOptions.targetPrim, primaries)
    // PQ videos will be display as it was, HLG videos will be converted to PQ
    mpv.setString(MPVOption.GPURendererOptions.targetTrc, "pq")
    mpv.setFlag(MPVOption.Screenshot.screenshotTagColorspace, true)

    if Preference.bool(for: .enableToneMapping) {
      var targetPeak = Preference.integer(for: .toneMappingTargetPeak)
      // If the target peak is set to zero then IINA attempts to determine peak brightness of the
      // display.
      if targetPeak == 0 {
        if let displayInfo = CoreDisplay_DisplayCreateInfoDictionary(currentDisplay!)?.takeRetainedValue() as? [String: AnyObject] {
          logHDR("Successfully obtained information about the display")
          // Apple Silicon Macs use the key NonReferencePeakHDRLuminance.
          if let hdrLuminance = displayInfo["NonReferencePeakHDRLuminance"] as? Int {
            logHDR("Found NonReferencePeakHDRLuminance: \(hdrLuminance)")
            targetPeak = hdrLuminance
          } else if let hdrLuminance = displayInfo["DisplayBacklight"] as? Int {
            // Intel Macs use the key DisplayBacklight.
            logHDR("Found DisplayBacklight: \(hdrLuminance)")
            targetPeak = hdrLuminance
          } else {
            logHDR("Didn't find NonReferencePeakHDRLuminance or DisplayBacklight, assuming HDR400")
            logHDR("Display info dictionary: \(displayInfo)")
            targetPeak = 400
          }
        } else {
          logHDR("Unable to obtain display information, assuming HDR400", level: .warning)
          targetPeak = 400
        }
      }
      let algorithm = Preference.ToneMappingAlgorithmOption(rawValue: Preference.integer(for: .toneMappingAlgorithm))?.mpvString
        ?? Preference.ToneMappingAlgorithmOption.defaultValue.mpvString

      logHDR("Will enable tone mapping: target-peak=\(targetPeak) algorithm=\(algorithm)")
      mpv.setInt(MPVOption.GPURendererOptions.targetPeak, targetPeak)
      mpv.setString(MPVOption.GPURendererOptions.toneMapping, algorithm)
    } else {
      mpv.setString(MPVOption.GPURendererOptions.targetPeak, "auto")
      mpv.setString(MPVOption.GPURendererOptions.toneMapping, "")
    }
    return true
  }

  // MARK: - Utils

  func logHDR(_ message: String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: hdrSubsystem)
  }

  func log(_ message: String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }
}

fileprivate func displayLinkCallback(
  _ displayLink: CVDisplayLink, _ inNow: UnsafePointer<CVTimeStamp>,
  _ inOutputTime: UnsafePointer<CVTimeStamp>,
  _ flagsIn: CVOptionFlags,
  _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
  _ context: UnsafeMutableRawPointer?) -> CVReturn {
  let videoView = unsafeBitCast(context, to: VideoView.self)
  videoView.$isUninited.withLock() { isUninited in
    guard !isUninited else { return }
    videoView.player.mpv.mpvReportSwap()
  }
  return kCVReturnSuccess
}
