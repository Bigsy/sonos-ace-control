import AVFoundation

// Opens only the selected headphones' microphone. Samples are discarded; there
// is no recording, playback, network connection, or telephony call signalling.
final class CallAudioTest: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "ace.call-audio")
    private var session: AVCaptureSession? // Access only on queue.
    private var firstBuffer: (() -> Void)? // Access only on queue.
    private var generation = UUID() // Access only on main.
    private var timer: Timer?
    private(set) var isActive = false // Includes permission / startup.
    var changed: ((Bool, String) -> Void)?

    func start(headphoneName: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isActive else { return }
        isActive = true
        let request = UUID()
        generation = request
        changed?(true, "Allow microphone access to test call audio. Nothing is recorded.")
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            self?.stop(message: "Call audio test finished (90 seconds).")
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.generation == request, self.isActive else { return }
                guard allowed else {
                    self.stop(message: "Microphone access denied. Enable Ace Control in System Settings → Privacy & Security → Microphone.")
                    return
                }
                self.changed?(true, "Opening the Sonos microphone…")
                self.queue.async { self.open(headphoneName: headphoneName, request: request) }
            }
        }
    }

    private func open(headphoneName: String, request: UUID) {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { deviceTypes = [.microphone, .external] }
        else { deviceTypes = [.builtInMicrophone, .externalUnknown] }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified)
        let matches = discovery.devices.filter {
            $0.localizedName.caseInsensitiveCompare(headphoneName) == .orderedSame ||
            $0.localizedName.caseInsensitiveCompare(headphoneName + " (USB)") == .orderedSame
        }
        guard matches.count == 1, let device = matches.first else {
            finish(request, "Cannot uniquely identify the selected Sonos microphone. Connect it through Bluetooth audio or USB, then try again.")
            return
        }
        do {
            let capture = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddInput(input) else {
                finish(request, "The Sonos microphone is unavailable.")
                return
            }
            capture.addInput(input)
            guard capture.canAddOutput(output) else {
                finish(request, "Cannot open the Sonos audio stream.")
                return
            }
            capture.addOutput(output)
            session = capture
            firstBuffer = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == request, self.isActive else { return }
                    self.changed?(true, "\(device.localizedName) microphone active. With ANC on, compare Sidetone off/on. Stops after 90 seconds.\(device.localizedName.hasSuffix("(USB)") ? " USB sidetone is experimental." : "")")
                }
            }
            capture.startRunning()
            queue.asyncAfter(deadline: .now() + 10) { [weak self, weak capture] in
                guard let self, let capture, self.session === capture, self.firstBuffer != nil else { return }
                self.finish(request, "No microphone audio arrived. Check the Sonos Bluetooth audio connection and try again.")
            }
        } catch {
            finish(request, "Could not open Sonos microphone: \(error.localizedDescription)")
        }
    }

    private func finish(_ request: UUID, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == request else { return }
            self.stop(message: message)
        }
    }

    func stop(message: String = "Call audio test stopped.") {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive else { return }
        generation = UUID()
        isActive = false
        timer?.invalidate(); timer = nil
        queue.async {
            self.firstBuffer = nil
            self.session?.stopRunning()
            self.session = nil
        }
        changed?(false, message)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let callback = firstBuffer
        firstBuffer = nil
        callback?()
        // Deliberately discard the buffer without inspecting its audio data.
    }
}
