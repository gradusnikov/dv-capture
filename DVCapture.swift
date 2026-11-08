import SwiftUI
import AppKit
import AVFoundation
import Darwin
import ImageIO

final class PreviewSurface {
    weak var view: NSImageView?
    var image: NSImage? { didSet { view?.image = image } }
}
struct NativePreview: NSViewRepresentable {
    let surface: PreviewSurface
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = surface.image; surface.view = view
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {}
}

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

final class CaptureModel: ObservableObject {
    @Published var folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "captureFolder") ?? NSHomeDirectory() + "/Movies") {
        didSet { UserDefaults.standard.set(folder.path, forKey: "captureFolder") }
    }
    @Published var name = "VX1000"
    @Published var seconds = "0"
    @Published var controlTape = false
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
    private var captureHadWarnings = false
    private var process: Process?
    private var timer: Timer?
    private var began = Date()
    var onIdle: (() -> Void)?
    var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tapecap") }

    @Published var previewing = false
    @Published var liveReady = false
    let previewSurface = PreviewSurface()
    @Published var liveMessage = "Preview is off"
    private var liveProcess: Process?
    private var liveInput: FileHandle?
    private var lastFrame = Date.distantPast
    private var liveTimer: Timer?
    private var liveRecording = false
    private let previewLock = NSLock()
    private var pendingPreview: NSImage?
    private var displayTimer: Timer?
    private var previewActivity: NSObjectProtocol?
    private var rateReports = 0
    private var receivedFrames = 0
    private var displayedFrames = 0
    private var rateStarted = Date()
    @Published var previewRate = 0
    private let audioMonitor = LiveAudioMonitor()
    @Published var muted = false { didSet { updateMonitorVolume() } }
    @Published var monitorVolume = 0.5 { didSet { updateMonitorVolume() } }
    @Published var audioMessage = "Waiting for audio"
    private func updateMonitorVolume() { audioMonitor.setVolume(muted ? 0 : Float(monitorVolume)) }

    // The pipe reader replaces this one slot. Main-thread work cannot build a
    // backlog of old frames while a menu, sheet, or busy window blocks redraws.
    private func queuePreview(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        previewLock.lock(); pendingPreview = image; receivedFrames += 1; previewLock.unlock()
    }
    private func displayLatestPreview() {
        previewLock.lock(); let data = pendingPreview; pendingPreview = nil; previewLock.unlock()
        guard let image = data else { return }
        previewSurface.image = image; lastFrame = Date(); displayedFrames += 1
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

    func liveCommand(_ action: String, path: String? = nil) {
        var command = ["action": action]
        if let path = path { command["path"] = path }
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        do { try liveInput?.write(contentsOf: data + Data([10])) }
        catch { append("Live control failed: \(error.localizedDescription)\n") }
    }
    func startLive() {
        guard !busy, !previewing else { return }
        let p = Process(), input = Pipe(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/live_session.py").path, executable.path]
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        liveProcess = p; liveInput = input.fileHandleForWriting
        previewing = true; liveReady = false; previewSurface.image = nil
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
        previewLock.lock(); pendingPreview = nil; previewLock.unlock()
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
            var announcedAudio = false
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]; buffer.removeSubrange(...end)
                    if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        if obj["event"] as? String == "frame", let encoded = obj["data"] as? String,
                           let data = Data(base64Encoded: encoded) {
                            self.queuePreview(data)
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
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.audioMonitor.stop(); self.audioMessage = "Audio off"
                if let activity = self.previewActivity { ProcessInfo.processInfo.endActivity(activity) }
                self.previewActivity = nil
                self.displayTimer?.invalidate(); self.displayTimer = nil
                self.previewLock.lock(); self.pendingPreview = nil; self.previewLock.unlock()
                self.liveTimer?.invalidate(); self.liveTimer = nil
                self.liveProcess = nil; self.liveInput = nil
                self.previewing = false; self.liveReady = false
                self.liveMessage = "Preview disconnected"
                if self.liveRecording { self.finishLiveRecording() }
                self.notifyIdle()
            }
        }
    }
    func liveEvent(_ obj: [String: Any]) {
        switch obj["event"] as? String {
        case "ready": liveReady = true; camera = "DV · FireWire connected"; status = "Live preview connected"
        case "log": append((obj["message"] as? String ?? "") + "\n")
        case "error": status = obj["message"] as? String ?? "Live preview failed"; append(status + "\n")
        case "audio_error": audioMessage = obj["message"] as? String ?? "Live audio unavailable"; append(audioMessage + "\n")
        case "saved": finishLiveRecording()
        default: break
        }
    }
    func finishLiveRecording() {
        guard liveRecording else { return }
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
        guard !busy else { return }
        guard let duration = Int(seconds), duration >= 0, duration <= 86400 else {
            status = "Enter a duration from 0 to 86400 seconds."; return
        }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/"), !cleaned.contains(":"), !cleaned.contains("\0") else {
            status = "Enter a file name without slashes or colons."; return
        }
        lastMOV = nil; captureHadWarnings = false
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let file = folder.appendingPathComponent("\(cleaned)_\(date.string(from: Date()))_\(UUID().uuidString.prefix(6)).dv")
        if previewing {
            guard liveReady else { status = "Wait for preview to connect."; return }
            lastFile = file; bytes = 0; elapsed = 0; began = Date()
            busy = true; recording = true; liveRecording = true; stopping = false
            status = "Starting capture…"
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
        var args = ["capture", "--format", "dv"]
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
        if let file = lastFile, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) {
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
        panel.allowedFileTypes = ["dv"]
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
        if FileManager.default.fileExists(atPath: output.path) {
            output = file.deletingPathExtension().appendingPathExtension("audio-\(UUID().uuidString.prefix(6)).mov")
        }
        let destination = output
        let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/audio_export.py")
        var args = [script.path, file.path, output.path]
        if preview { args.append("preview") }
        launch(URL(fileURLWithPath: "/usr/bin/python3"), args) { code, report in
            self.busy = false
            if code == 0, FileManager.default.fileExists(atPath: output.path) {
                if !preview { self.lastMOV = destination }
                self.status = self.captureHadWarnings ? "MOV saved · capture warnings in details" :
                    (report.contains("Saved corrected DV:") ? "MOV + corrected DV saved" : (report.contains("Recovered") ? "MOV saved · audio corrected" : "MOV saved with audio"))
                if preview { NSWorkspace.shared.open(destination) }
                else if !automatic { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } else { self.status = "Original DV kept · automatic export failed · see details or retry Export MOV + Audio" }
            try? self.log.write(to: file.appendingPathExtension("log"), atomically: true, encoding: .utf8)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: CaptureModel?
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
    @ObservedObject var model: CaptureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "video.fill").font(.system(size: 34)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DV Capture").font(.system(size: 28, weight: .bold))
                    Text("Original footage. Straight from your camera.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("RAW DV").font(.caption.monospaced().bold()).padding(8).background(.teal.opacity(0.12), in: Capsule())
            }
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.status).font(.headline)
                        Text(model.camera).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Camera") { model.checkCamera() }.disabled(model.busy || model.previewing)
                }.padding(8)
            }
            HStack(alignment: .top, spacing: 24) {
                previewPanel.frame(width: 600)
                Divider()
                importPanel.frame(width: 370)
            }.fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Capture details") {
                ScrollView {
                    Text(model.log.isEmpty ? "Capture messages appear here." : model.log)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 150).background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Quit other capture apps first. After Stop & Save, wait for MOV saved. The original DV is kept as an archive; Export MOV + Audio can retry an export or repair an older recording.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 1080)
    }
    private var previewPanel: some View {
            VStack(spacing: 8) {
                ZStack {
                    Color.black
                    NativePreview(surface: model.previewSurface)
                    if !model.previewing { Text("Camera preview").foregroundColor(.gray) }
                }.frame(width: 600, height: 450).cornerRadius(8)
                HStack {
                    Text(model.liveMessage + (model.liveReady && model.previewRate > 0 ? " · \(model.previewRate) fps" : "")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.previewing ? "Disconnect Preview" : "Start Live Preview") {
                        if model.previewing { model.stopLive() } else { model.startLive() }
                    }.disabled(model.busy || (model.previewing && !model.liveReady))
                }
                HStack(spacing: 10) {
                    Button { model.liveCommand("rewind") } label: { Label("Rewind", systemImage: "backward.end.fill") }
                    Button { model.liveCommand("play") } label: { Label("Play", systemImage: "play.fill") }
                    Button { model.liveCommand("pause") } label: { Label("Pause", systemImage: "pause.fill") }
                    Button { model.liveCommand("stop") } label: { Label("Stop tape", systemImage: "stop.fill") }
                    Button { model.liveCommand("forward") } label: { Label("Forward", systemImage: "forward.end.fill") }
                }.disabled(!model.liveReady || model.recording)
                HStack {
                    Button { model.muted.toggle() } label: {
                        Label(model.muted ? "Unmute" : "Mute", systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    Slider(value: $model.monitorVolume, in: 0...1).frame(width: 140).accessibilityLabel("Preview volume")
                    Text(model.audioMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.disabled(!model.previewing)
                Text("VTR mode for tape controls. Winding may hold the last picture. Audio is saved in the recording.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
    }
    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Import footage").font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Save to").frame(width: 80, alignment: .leading)
                    Text(model.folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Folder…") { model.chooseFolder() }
                }
                HStack {
                    Text("File name").frame(width: 80, alignment: .leading)
                    TextField("VX1000", text: $model.name)
                }
                HStack {
                    Text("Duration").frame(width: 80, alignment: .leading)
                    TextField("0", text: $model.seconds).frame(width: 70)
                    Text("seconds · 0 = until stopped").foregroundStyle(.secondary)
                }
                Toggle("Start and stop tape playback automatically", isOn: $model.controlTape)
                Text(model.controlTape ? "Set the camera to VTR. Capture sends Play; stopping sends Stop." : "Press Play on the camera for tape capture, or use CAMERA mode for live video.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60)).font(.system(size: 32, weight: .medium, design: .monospaced))
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file) + " saved").foregroundStyle(.secondary)
                }
                Spacer()
                if model.recording {
                    Button { model.stop() } label: { Label(model.stopping ? "Saving…" : "Stop & Save", systemImage: "stop.fill").frame(width: 140) }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(model.stopping)
                } else {
                    Button { model.start() } label: { Label("Start Capture", systemImage: "record.circle").frame(width: 140) }
                        .buttonStyle(.borderedProminent).tint(.teal).disabled(model.busy)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Button("Open DV…") { model.openCapture() }.disabled(model.busy)
                Button(model.lastMOV == nil ? "Show File" : "Show MOV") { model.reveal() }.disabled(model.lastFile == nil || model.busy)
              }
              HStack {
                Button("Export MOV + Audio") { model.exportAudio() }.disabled(model.bytes == 0 || model.busy)
                Button("Play 15-second Preview") { model.preview() }.disabled(model.bytes == 0 || model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
              }
            }
            Text("Each capture saves a MOV and, when needed, a corrected DV copy. The original DV is kept. Video is never re-encoded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    }
}
