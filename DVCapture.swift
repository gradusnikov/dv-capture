import SwiftUI
import AppKit
import AVFoundation
import Darwin

// All engine and player operations are serialized off the UI thread.
final class LiveAudioMonitor {
    private let queue = DispatchQueue(label: "DV.audio", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var enabled = false
    private var queuedBuffers = 0
    private var generation = 0
    var report: ((String) -> Void)?
    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }
    func start(volume: Float) {
        queue.async {
            self.generation += 1; self.queuedBuffers = 0
            self.player.volume = volume
            do {
                self.engine.prepare(); try self.engine.start()
                self.player.play(); self.enabled = true
            } catch { self.report?("Audio output unavailable: \(error.localizedDescription)") }
        }
    }
    func discardBufferedAudio() {
        queue.async {
            guard self.enabled else { return }
            self.generation += 1; self.queuedBuffers = 0
            self.player.stop(); self.player.play()
        }
    }
    func setVolume(_ volume: Float) { queue.async { self.player.volume = volume } }
    func stop() {
        queue.async {
            self.enabled = false; self.generation += 1; self.queuedBuffers = 0
            self.player.stop(); self.engine.stop()
        }
    }
    func receive(_ data: Data) {
        queue.async {
            guard self.enabled, data.count >= 4, data.count % 4 == 0 else { return }
            // Recover from a stalled output without playing an ever-growing backlog.
            if self.queuedBuffers >= 5 {
                self.generation += 1; self.player.stop(); self.queuedBuffers = 0; self.player.play()
            }
            let count = AVAudioFrameCount(data.count / 4)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: count),
                  let channels = buffer.floatChannelData else { return }
            buffer.frameLength = count
            data.withUnsafeBytes { raw in
                for i in 0..<Int(count) {
                    channels[0][i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))) / 32768
                    channels[1][i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))) / 32768
                }
            }
            let generation = self.generation
            self.queuedBuffers += 1
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                self.queue.async {
                    if self.generation == generation { self.queuedBuffers = max(0, self.queuedBuffers - 1) }
                }
            }
        }
    }
}

enum MOVQuality: String {
    case full, streaming
}

final class CaptureModel: ObservableObject {
    @Published var movQuality = MOVQuality(rawValue: UserDefaults.standard.string(forKey: "movQuality") ?? "") ?? .full {
        didSet { UserDefaults.standard.set(movQuality.rawValue, forKey: "movQuality") }
    }
    @Published var folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "captureFolder") ?? NSHomeDirectory() + "/Movies") {
        didSet { UserDefaults.standard.set(folder.path, forKey: "captureFolder") }
    }
    @Published var name = UserDefaults.standard.string(forKey: "captureName") ?? "VX1000" {
        didSet { if let validName { UserDefaults.standard.set(validName, forKey: "captureName") } }
    }
    private var validName: String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/"), !cleaned.contains(":"), !cleaned.contains("\0") else { return nil }
        return cleaned
    }
    @Published var seconds = String(UserDefaults.standard.integer(forKey: "captureSeconds")) {
        didSet { if let validDuration { UserDefaults.standard.set(validDuration, forKey: "captureSeconds") } }
    }
    private var validDuration: Int? {
        guard let duration = Int(seconds), (0...86400).contains(duration) else { return nil }
        return duration
    }
    @Published var stopAtEnd = UserDefaults.standard.object(forKey: "stopAtEnd") as? Bool ?? true {
        didSet { UserDefaults.standard.set(stopAtEnd, forKey: "stopAtEnd") }
    }
    private var endToken: String?
    @Published var controlTape = UserDefaults.standard.bool(forKey: "controlTape") {
        didSet { UserDefaults.standard.set(controlTape, forKey: "controlTape") }
    }
    @Published var busy = false
    @Published var recording = false
    @Published var stopping = false
    @Published var status = "Ready to connect"
    @Published var camera = "Connect your camera over FireWire, then check the connection."
    @Published var log = ""
    @Published var elapsed = 0
    @Published var bytes: Int64 = 0
    @Published var lastFile: URL?
    @Published var lastMOV: URL?
    private var endedWithFootage = false
    private var captureHadWarnings = false
    private var process: Process?
    private var timer: Timer?
    private var began = Date()
    var onIdle: (() -> Void)?
    var mediaHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dv-media") }
    var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tapecap") }

    @Published var previewing = false
    @Published var liveReady = false
    let pixelDisplay = AVSampleBufferDisplayLayer()
    private var pendingSample: CMSampleBuffer?
    @Published var liveMessage = "Preview is off"
    private var liveProcess: Process?
    private var liveInput: FileHandle?
    private var lastFrame = Date.distantPast
    private var liveTimer: Timer?
    private var liveRecording = false
    private let previewLock = NSLock()
    private var displayTimer: Timer?
    private var previewActivity: NSObjectProtocol?
    private var rateReports = 0
    private var receivedFrames = 0
    private var displayedFrames = 0
    private var rateStarted = Date()
    @Published var previewRate = 0
    private let audioMonitor = LiveAudioMonitor()
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet {
            UserDefaults.standard.set(muted, forKey: "muted")
            updateMonitorVolume()
        }
    }
    @Published var monitorVolume = UserDefaults.standard.object(forKey: "monitorVolume") as? Double ?? 0.5 {
        didSet {
            UserDefaults.standard.set(monitorVolume, forKey: "monitorVolume")
            updateMonitorVolume()
        }
    }
    @Published var audioMessage = "Waiting for audio"
    private func updateMonitorVolume() { audioMonitor.setVolume(muted ? 0 : Float(monitorVolume)) }

    // The pipe reader replaces this one slot. Main-thread work cannot build a
    // backlog of old frames while a menu, sheet, or busy window blocks redraws.
    private func displayLatestPreview() {
        previewLock.lock()
        let sample = pendingSample
        pendingSample = nil
        previewLock.unlock()
        guard let sample else { return }
        if pixelDisplay.status == .failed { pixelDisplay.flush() }
        guard pixelDisplay.isReadyForMoreMediaData else { return }
        pixelDisplay.enqueue(sample)
        lastFrame = Date(); displayedFrames += 1
        if liveMessage != "Live preview" { liveMessage = "Live preview" }
        let interval = Date().timeIntervalSince(rateStarted)
        if interval >= 1 {
            previewLock.lock(); let received = receivedFrames; receivedFrames = 0; previewLock.unlock()
            previewRate = Int((Double(displayedFrames) / interval).rounded())
            rateReports += 1
            if rateReports % 5 == 0 { append("Preview: \(Int((Double(received) / interval).rounded())) fps decoded, \(previewRate) fps displayed\n") }
            displayedFrames = 0; rateStarted = Date()
        }
    }

    @Published var tapeTimecode = "—"
    @Published var recordedAt = "—"
    @Published var seekTarget = ""
    @Published var seeking = false
    var targetSeconds: Int? {
        let parts = seekTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ (1...2).contains($0.count) && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
              h < 24, m < 60, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }
    func seek() {
        guard liveReady, !busy, !seeking, let target = targetSeconds else { return }
        seeking = true
        status = "Seeking to " + seekTarget + "…"
        NSApp.keyWindow?.makeFirstResponder(nil)
        liveCommand("seek", seconds: target)
    }

    func liveCommand(_ action: String, path: String? = nil, seconds: Int? = nil) {
        var command = ["action": action]
        if let seconds { command["seconds"] = String(seconds) }
        if let path = path { command["path"] = path }
        if action == "record", let endToken { command["end_token"] = endToken }
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        do { try liveInput?.write(contentsOf: data + Data([10])) }
        catch { if action == "seek" { seeking = false; status = "Seek command failed" }; append("Live control failed: \(error.localizedDescription)\n") }
    }
    func startLive() {
        guard !busy, !previewing else { return }
        let p = Process(), input = Pipe(), output = Pipe()
        p.executableURL = mediaHelper
        p.arguments = ["live", executable.path]
        pixelDisplay.flushAndRemoveImage()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        liveProcess = p; liveInput = input.fileHandleForWriting
        previewing = true; liveReady = false
        liveMessage = "Connecting…"; log = ""
        do { try p.run() } catch {
            previewing = false; liveProcess = nil; liveInput = nil
            status = error.localizedDescription; return
        }
        previewActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Live FireWire video preview and capture")
        audioMessage = "Waiting for audio"
        audioMonitor.report = { [weak self] message in
            DispatchQueue.main.async { self?.audioMessage = message; self?.append(message + "\n") }
        }
        audioMonitor.start(volume: muted ? 0 : Float(monitorVolume))
        lastFrame = .distantPast
        previewLock.lock(); pendingSample = nil; previewLock.unlock()
        displayedFrames = 0; previewRate = 0; rateStarted = Date()
        let display = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in self.displayLatestPreview() }
        displayTimer = display
        RunLoop.main.add(display, forMode: .common)
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if self.liveReady && Date().timeIntervalSince(self.lastFrame) > 2 {
                self.liveMessage = "Waiting for video · press Play in VTR mode"
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            let decoder = DVPreviewDecoder()
            var frameLength = 0
            var decodeErrorReported = false
            var announcedAudio = false
            // The reader lives for the whole tape. Release temporary decoded images
            // and Foundation objects after each pipe read, including partial lines.
            var reading = true
            while reading {
                reading = autoreleasepool {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { return false }
                    buffer.append(data)
                    while true {
                        if frameLength > 0 {
                            guard buffer.count >= frameLength else { break }
                            let frame = Data(buffer.prefix(frameLength))
                            buffer.removeFirst(frameLength); frameLength = 0
                            do {
                                try decoder.decode(frame) { sample in
                                    self.previewLock.lock(); self.pendingSample = sample
                                    self.receivedFrames += 1; self.previewLock.unlock()
                                }
                            } catch {
                                if !decodeErrorReported {
                                    decodeErrorReported = true
                                    DispatchQueue.main.async {
                                        self.status = "Video preview decoding failed. See Capture details."
                                        self.append("Native DV decoder: " + error.localizedDescription + "\n")
                                    }
                                }
                            }
                            continue
                        }
                        guard let end = buffer.firstIndex(of: 10) else { break }
                        let line = buffer[..<end]; buffer.removeSubrange(...end)
                        if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                            if obj["event"] as? String == "dv", let length = obj["bytes"] as? Int,
                               length == 144000 || length == 120000 {
                                frameLength = length
                            } else if obj["event"] as? String == "monitor_pause", let paused = obj["paused"] as? Bool {
                                announcedAudio = false
                                if paused { self.audioMonitor.discardBufferedAudio() }
                                DispatchQueue.main.async { self.audioMessage = paused ? "Tape paused" : "Waiting for audio" }
                            } else if obj["event"] as? String == "audio", let encoded = obj["data"] as? String,
                                      let data = Data(base64Encoded: encoded) {
                                self.audioMonitor.receive(data)
                                if !announcedAudio {
                                    announcedAudio = true
                                    DispatchQueue.main.async { self.audioMessage = "Live audio · stereo 1/2" }
                                }
                            } else {
                                DispatchQueue.main.async { self.liveEvent(obj) }
                            }
                        }
                    }
                    return true
                }
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.audioMonitor.stop(); self.audioMessage = "Audio off"
                if let activity = self.previewActivity { ProcessInfo.processInfo.endActivity(activity) }
                self.previewActivity = nil
                self.displayTimer?.invalidate(); self.displayTimer = nil
                self.pixelDisplay.flushAndRemoveImage()
                self.previewLock.lock(); self.pendingSample = nil; self.previewLock.unlock()
                self.liveTimer?.invalidate(); self.liveTimer = nil
                self.liveProcess = nil; self.liveInput = nil
                self.tapeTimecode = "—"; self.recordedAt = "—"; self.seeking = false
                self.previewing = false; self.liveReady = false
                self.liveMessage = "Preview disconnected"
                if self.liveRecording { self.finishLiveRecording() }
                self.notifyIdle()
            }
        }
    }
    func liveEvent(_ obj: [String: Any]) {
        switch obj["event"] as? String {
        case "metadata":
            tapeTimecode = (obj["timecode"] as? String).flatMap { $0 == "-" ? nil : $0 } ?? "—"
            recordedAt = (obj["recorded"] as? String).flatMap { $0 == "-" ? nil : $0 } ?? "—"
        case "seek_result":
            seeking = false
            switch obj["result"] as? String {
            case "reached": status = "Tape positioned near " + seekTarget
            case "approximate": status = "Tape stopped at an estimated position"
            case "cancelled": status = "Seek cancelled"
            default: status = "Could not reach the requested timecode"
            }
        case "ready": liveReady = true; camera = "DV · FireWire connected"; status = "Live preview connected"
        case "log": append((obj["message"] as? String ?? "") + "\n")
        case "error": status = obj["message"] as? String ?? "Live preview failed"; append(status + "\n")
        case "audio_error": audioMessage = obj["message"] as? String ?? "Live audio unavailable"; append(audioMessage + "\n")
        case "tape_end":
            if liveRecording, !stopping, let token = obj["token"] as? String, token == endToken {
                endedWithFootage = true
                append("End of recorded footage detected. Saving capture.\n")
                stop()
            }
        case "saved": finishLiveRecording()
        default: break
        }
    }
    func finishLiveRecording() {
        guard liveRecording else { return }
        endToken = nil
        timer?.invalidate(); timer = nil; refreshSize()
        liveRecording = false; busy = false; recording = false; stopping = false
        status = bytes > 0 ? "Capture saved · preview continues" : "No video captured"
        if let file = lastFile { try? log.write(to: file.appendingPathExtension("log"), atomically: true, encoding: .utf8) }
        if bytes > 0 { exportAudio(automatic: true) }
    }
    func stopLive() {
        audioMonitor.stop()
        liveReady = false; liveMessage = "Disconnecting…"
        liveCommand("quit")
    }

    private func notifyIdle() {
        // Quit only after both the camera session and any chained MOV export finish.
        if !busy && process == nil && liveProcess == nil { onIdle?() }
    }

    func append(_ text: String) {
        log += text.replacingOccurrences(of: "\r", with: "\n")
        if log.count > 24000 { log = String(log.suffix(24000)) }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
    func launch(_ executable: URL, _ args: [String], done: @escaping (Int32, String) -> Void) {
        let p = Process(), pipe = Pipe()
        p.executableURL = executable; p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        process = p
        do { try p.run() }
        catch { process = nil; done(-1, error.localizedDescription); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var output = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                output += text
                if output.count > 40000 { output = String(output.suffix(40000)) }
                DispatchQueue.main.async { self.append(text) }
            }
            p.waitUntilExit()
            let result = output
            DispatchQueue.main.async {
                self.process = nil
                done(p.terminationStatus, result)
                self.notifyIdle()
            }
        }
    }
    func checkCamera() {
        guard !busy else { return }
        busy = true; log = ""; status = "Checking camera…"
        launch(executable, ["info", "--json"]) { code, output in
            self.busy = false
            guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
                  let data = String(output[start...end]).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.status = "Camera not available"
                self.camera = "Check power and FireWire. See details below."
                return
            }
            if obj["open"] as? Bool != true {
                self.status = "Camera is unavailable"
                self.camera = obj["open_error"] as? String == "0xE00002C5"
                  ? "Camera is in use. Quit Final Cut Pro, iMovie and QuickTime, then try again."
                  : "The camera could not be opened. Check power and connection."
            } else {
                let format = obj["format"] as? String ?? "DV"
                self.status = format == "DV" ? "Camera connected" : "This app captures DV only"
                let mode = obj["dv_mode"] as? Int
                let standard = mode == 128 ? "PAL · 25 fps" : mode == 0 ? "NTSC · 29.97 fps" : "DV"
                self.camera = "\(format) · \(standard) · FireWire connected"
            }
        }
    }
    func start() {
        guard !busy, !seeking else { return }
        guard let duration = validDuration else {
            status = "Enter a duration from 0 to 86400 seconds."; return
        }
        guard let cleaned = validName else {
            status = "Enter a file name without slashes or colons."; return
        }
        lastMOV = nil; captureHadWarnings = false; endedWithFootage = false
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let file = folder.appendingPathComponent("\(cleaned)_\(date.string(from: Date()))_\(UUID().uuidString.prefix(6)).dv")
        if previewing {
            guard liveReady else { status = "Wait for preview to connect."; return }
            lastFile = file; bytes = 0; elapsed = 0; began = Date()
            busy = true; recording = true; liveRecording = true; stopping = false
            status = "Starting capture…"
            endToken = stopAtEnd ? UUID().uuidString : nil
            liveCommand("record", path: file.path)
            if controlTape { liveCommand("play") }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                self.elapsed = Int(Date().timeIntervalSince(self.began)); self.refreshSize()
                if duration > 0 && self.elapsed >= duration { self.stop() }
                else if !self.stopping { self.status = self.bytes > 0 ? "Capturing DV · live preview" : "Waiting for video…" }
            }
            return
        }
        // Reserve a unique path before handing it to the capture engine.
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { status = "Cannot write to this folder. Choose another folder."; return }
        Darwin.close(fd)
        lastFile = file; bytes = 0; elapsed = 0; began = Date()
        busy = true; recording = true; stopping = false; log = ""
        status = "Starting capture…"
        var args = ["capture", "--format", "dv", "--eot-timeout", "0"]
        if stopAtEnd { args.append("--detect-dv-end") }
        if !controlTape { args += ["--no-control"] }
        if duration > 0 { args += ["--duration", String(duration)] }
        args.append(file.path)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.elapsed = Int(Date().timeIntervalSince(self.began))
            self.refreshSize()
            if !self.stopping { self.status = self.bytes > 0 ? "Capturing DV" : "Waiting for video…" }
        }
        launch(executable, args) { code, output in
            self.timer?.invalidate(); self.timer = nil; self.refreshSize()
            self.busy = false; self.recording = false; self.stopping = false
            self.endedWithFootage = output.contains("Done (end of recorded footage)")
            if self.bytes == 0 {
                self.status = "No video captured"
                self.append("\nCheck camera mode and playback. Quit other capture apps if the camera is in use.\n")
            } else if code != 0 || output.lowercased().contains("corrupted") || output.lowercased().contains("different dv mode") {
                self.captureHadWarnings = true
                self.status = "Saved with warnings — check details"
            } else {
                self.status = "Capture saved"
            }
            try? self.log.write(to: file.appendingPathExtension("log"), atomically: true, encoding: .utf8)
            if self.bytes > 0 { self.exportAudio(automatic: true) }
        }
    }
    func refreshSize() {
        if let file = lastFile, let attrs = try? Foundation.FileManager.default.attributesOfItem(atPath: file.path) {
            bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
    func stop() {
        if liveRecording && !stopping {
            stopping = true; status = "Stopping and saving…"
            liveCommand("save")
            if controlTape { liveCommand("stop") }
            return
        }
        guard let p = process, p.isRunning, recording, !stopping else { return }
        stopping = true; status = "Stopping and saving…"
        p.interrupt()
    }
    func reveal() {
        if let file = lastMOV ?? lastFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
    func openCapture() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["dv", "mov"]
        panel.directoryURL = folder
        if panel.runModal() == .OK, let file = panel.url {
            lastFile = file; lastMOV = nil; captureHadWarnings = false; refreshSize(); status = "Recording selected · ready to export"
        }
    }
    func preview() { exportAudio(preview: true) }
    func exportAudio(preview: Bool = false, automatic: Bool = false) {
        guard !busy, let file = lastFile, bytes > 0 else { return }
        busy = true; status = automatic ? "DV saved · correcting audio and exporting MOV…" : "Preparing video with audio…"
        let kind = preview ? "preview" : "audio"
        var output = automatic ? file.deletingPathExtension().appendingPathExtension("mov")
            : file.deletingPathExtension().appendingPathExtension("\(kind)-\(UUID().uuidString.prefix(6)).mov")
        if Foundation.FileManager.default.fileExists(atPath: output.path) {
            output = file.deletingPathExtension().appendingPathExtension("audio-\(UUID().uuidString.prefix(6)).mov")
        }
        let destination = output
        let args = ["export", file.path, output.path, preview ? "preview" : movQuality.rawValue]
        launch(mediaHelper, args) { code, report in
            self.busy = false
            if code == 0, Foundation.FileManager.default.fileExists(atPath: output.path) {
                if !preview { self.lastMOV = destination }
                self.status = self.captureHadWarnings ? "MOV saved · capture warnings in details" :
                    (report.contains("Saved corrected DV:") ? "MOV + corrected DV saved" : (report.contains("Recovered") ? "MOV saved · audio corrected" : "MOV saved with audio"))
                if automatic && self.endedWithFootage { self.status += " · End of footage" }
                if preview { NSWorkspace.shared.open(destination) }
                else if !automatic { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } else { self.status = "MOV export failed · original DV saved. See capture details." }
            try? self.log.write(to: file.appendingPathExtension("log"), atomically: true, encoding: .utf8)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: CaptureModel?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let model = self?.model, let window = event.window,
                  window.isKeyWindow, window.isMainWindow, !(window is NSPanel),
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return event }

            let key = event.charactersIgnoringModifiers?.lowercased()
            if let editor = window.firstResponder as? NSTextView {
                guard editor.isFieldEditor, !editor.hasMarkedText(),
                      key == "\u{1b}" || key == "\r" || key == "\u{3}"
                else { return event }
                window.makeFirstResponder(nil)
                return nil
            }
            if key == "r" {
                guard !model.busy else { return event }
                if !event.isARepeat { model.start() }
                return nil
            }
            guard model.liveReady, !model.recording, !model.seeking else { return event }
            let action: String
            switch key {
            case "\u{F702}", "j": action = "navigate-back"
            case "\u{F703}", "l": action = "navigate-forward"
            case "k": action = "pause"
            case " ", "\u{F730}": action = "toggle-play"
            default: return event
            }
            if !event.isARepeat { model.liveCommand(action) }
            return nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = model else { return .terminateNow }
        if !m.busy {
            if m.previewing {
                m.onIdle = { NSApp.reply(toApplicationShouldTerminate: true) }
                m.stopLive(); return .terminateLater
            }
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = m.recording ? "Stop capture and quit?" : "An operation is still running"
        alert.informativeText = m.recording ? "The DV and corrected-audio MOV will be saved before the app closes." : "Wait for the current operation to finish before quitting."
        alert.addButton(withTitle: m.recording ? "Stop and Quit" : "Keep Open")
        if !m.recording { alert.runModal(); return .terminateCancel }
        alert.addButton(withTitle: "Keep Capturing")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        m.onIdle = { NSApp.reply(toApplicationShouldTerminate: true) }
        if m.previewing { m.stopLive() } else { m.stop() }
        return .terminateLater
    }
}

struct CaptureView: View {
    @AppStorage("showCaptureDetails") private var showCaptureDetails = false
    @ObservedObject var model: CaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                previewPanel.frame(width: 560)
                Divider()
                settingsPanel.frame(width: 265)
            }
            .fixedSize(horizontal: false, vertical: true)

            if !model.log.isEmpty {
                Divider()
                DisclosureGroup("Capture details", isExpanded: $showCaptureDetails) {
                    ScrollView {
                        Text(model.log).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 100)
                }
            }
        }.frame(width: 866).padding(20)
    }

    private var previewPanel: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.black.overlay {
                    PixelPreview(display: model.pixelDisplay).aspectRatio(4.0/3.0, contentMode: .fit)
                }
                if !model.previewing {
                    Button("Start Live Preview") { model.startLive() }
                        .disabled(model.busy)
                }
            }
            .frame(height: 420).cornerRadius(6).contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) })

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Tape timecode").font(.caption).foregroundStyle(.secondary)
                    Text(model.tapeTimecode).monospacedDigit()
                }
                VStack(alignment: .leading) {
                    Text("Recorded").font(.caption).foregroundStyle(.secondary)
                    Text(model.recordedAt).monospacedDigit()
                }
                Spacer()
                TextField("HH:MM:SS", text: $model.seekTarget)
                    .frame(width: 85).accessibilityLabel("Go to tape timecode")
                    .disabled(!model.liveReady || model.busy || model.seeking)
                if model.seeking {
                    Button("Cancel") { model.liveCommand("cancel-seek") }
                } else {
                    Button("Go to timecode") { model.seek() }
                        .disabled(!model.liveReady || model.busy || model.targetSeconds == nil)
                        .help("Position the tape near the specified hour, minute and second.")
                }
            }
            HStack(spacing: 6) {
                Group {
                    Button { model.liveCommand("navigate-back") } label: { Label("Rewind", systemImage: "backward.fill") }.help("Rewind (← or J)")
                    Button { model.liveCommand("play") } label: { Label("Play", systemImage: "play.fill") }.help("Play")
                    Button { model.liveCommand("pause") } label: { Label("Pause", systemImage: "pause.fill") }.help("Pause (K)")
                    Button { model.liveCommand("stop") } label: { Label("Stop tape", systemImage: "stop.fill") }.help("Stop tape")
                    Button { model.liveCommand("navigate-forward") } label: { Label("Forward", systemImage: "forward.fill") }.help("Forward (→ or L)")
                }.disabled(!model.liveReady || model.recording || model.seeking)
                Spacer()
                Button { model.muted.toggle() } label: {
                    Label(model.muted ? "Unmute" : "Mute", systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }.disabled(!model.previewing).help(model.audioMessage)
                Slider(value: $model.monitorVolume, in: 0...1)
                    .frame(width: 82).accessibilityLabel("Preview volume").disabled(!model.previewing)
            }.labelStyle(.iconOnly)
            if model.previewing {
                HStack {
                    Text(model.liveMessage + (model.liveReady && model.previewRate > 0 ? " · \(model.previewRate) fps" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect") { model.stopLive() }.disabled(model.busy || !model.liveReady)
                }
            }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture").font(.title2.weight(.semibold))
            Group {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Save to")
                    Button { model.chooseFolder() } label: {
                        HStack {
                            Label(model.folder.lastPathComponent, systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Image(systemName: "ellipsis")
                        }
                    }.help(model.folder.path).accessibilityLabel("Choose destination folder, " + model.folder.path)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("File name prefix")
                    TextField("VX1000", text: $model.name).labelsHidden().accessibilityLabel("File name prefix")
                }
                HStack {
                    Text("Duration")
                    Spacer()
                    TextField("0", text: $model.seconds).frame(width: 55).accessibilityLabel("Duration in seconds")
                    Text(model.seconds == "0" ? "No limit" : "seconds").foregroundStyle(.secondary)
                }.help("Enter 0 to record until stopped.")
                Picker("MOV quality", selection: $model.movQuality) {
                    Text("Full quality").tag(MOVQuality.full)
                    Text("For streaming").tag(MOVQuality.streaming)
                }.pickerStyle(.menu)
                Toggle("Stop at end of footage", isOn: $model.stopAtEnd)
                    .help("Save after 15 seconds without recorded DV progress. Turn off to capture across long blank gaps.")
                Toggle("Control tape during capture", isOn: $model.controlTape)
                    .help("Play the tape when capture starts and stop it when capture ends.")
            }.disabled(model.busy)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60))
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                Spacer()
                if model.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
            if model.recording {
                Button { model.stop() } label: {
                    Label(model.stopping ? "Saving…" : "Stop & Save", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red).disabled(model.stopping)
            } else {
                Button { model.start() } label: {
                    Label("Start Capture", systemImage: "record.circle").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.seeking || (model.previewing && !model.liveReady)).help("Start capture (R)")
            }
            HStack(alignment: .top) {
                if model.busy && !model.recording { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.help(model.camera)
            if !model.busy && model.lastFile != nil {
                Button("Show in Finder") { model.reveal() }
            }
        }
    }
}

@main struct DVCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = CaptureModel()
    var body: some Scene {
        Window("DV Capture", id: "capture") {
            CaptureView(model: model).onAppear { delegate.model = model }
        }.windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open DV or MOV…") { model.openCapture() }.disabled(model.busy)
                Button("Export MOV with Audio…") { model.exportAudio() }.disabled(model.busy || model.bytes == 0)
                Button("Play 15-second Preview") { model.preview() }.disabled(model.busy || model.bytes == 0)
                Divider()
                Button("Check Camera") { model.checkCamera() }.disabled(model.busy || model.previewing)
            }
        }
    }
}
