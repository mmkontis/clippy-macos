import Foundation
import AVFoundation
import AppKit

// #region agent log helper
func writeAudioDebugLog(_ message: String, data: [String: Any]? = nil) {
    // No persistent microphone diagnostics or user-specific development paths.
}
// #endregion

class AudioService: ObservableObject {
    static let shared = AudioService()
    
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private let outputNode = AVAudioPlayerNode()
    
    private let geminiInputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private let geminiOutputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
    
    // Use a known-good mono Float32 format for the player node to avoid stereo mismatch issues
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    
    var onAudioCaptured: ((Data) -> Void)?
    var onAudioPlaybackStateChanged: ((Bool) -> Void)?
    
    @Published var isRecording = false
    private var engineRunning = false
    
    private var playbackStopTimer: DispatchWorkItem?
    
    private var isPlaying = false {
        didSet {
            DispatchQueue.main.async {
                self.onAudioPlaybackStateChanged?(self.isPlaying)
            }
        }
    }
    
    private init() {
        inputNode = audioEngine.inputNode
        audioEngine.attach(outputNode)
        audioEngine.connect(outputNode, to: audioEngine.mainMixerNode, format: playbackFormat)
    }
    
    /// Start the audio engine for playback only (no mic tap). Called regardless of mic permission.
    func startEngineForPlayback() {
        guard !engineRunning else { return }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            engineRunning = true
            outputNode.play()
            // #region agent log
            writeAudioDebugLog("Engine started for PLAYBACK", data: ["hypothesisId": "A", "engineRunning": true])
            // #endregion
        } catch {
            // #region agent log
            writeAudioDebugLog("Failed to start engine for playback", data: ["hypothesisId": "A", "error": error.localizedDescription])
            // #endregion
        }
    }
    
    func checkPermissionsAndStart() {
        // Always start the engine for playback first, regardless of mic
        startEngineForPlayback()
        
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        // #region agent log
        writeAudioDebugLog("Checking Mic Permissions", data: ["hypothesisId": "A", "status": status.rawValue])
        // #endregion
        switch status {
        case .authorized:
            DispatchQueue.main.async { [weak self] in
                self?.installMicTap()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                // #region agent log
                writeAudioDebugLog("Mic Request Result", data: ["hypothesisId": "A", "granted": granted])
                // #endregion
                if granted {
                    DispatchQueue.main.async {
                        self?.restartEngineWithMic()
                    }
                }
            }
        case .denied, .restricted:
            // #region agent log
            writeAudioDebugLog("Mic access denied - playback still works", data: ["hypothesisId": "A"])
            // #endregion
            break
        @unknown default:
            break
        }
    }
    
    func restartEngineWithMic() {
        if engineRunning {
            audioEngine.stop()
            outputNode.stop()
            engineRunning = false
        }
        installMicTap()
        do {
            audioEngine.prepare()
            try audioEngine.start()
            engineRunning = true
            isRecording = true
            outputNode.play()
            // #region agent log
            writeAudioDebugLog("Engine restarted with mic tap", data: ["hypothesisId": "C"])
            // #endregion
        } catch {
            // #region agent log
            writeAudioDebugLog("Failed to restart engine with mic", data: ["hypothesisId": "C", "error": error.localizedDescription])
            // #endregion
        }
    }
    
    private var micTapLogCounter = 0
    
    private func installMicTap() {
        // #region agent log
        writeAudioDebugLog("installMicTap called", data: ["hypothesisId": "A", "isRecording": isRecording])
        // #endregion
        guard !isRecording else {
            // #region agent log
            writeAudioDebugLog("installMicTap SKIPPED - already recording", data: ["hypothesisId": "A"])
            // #endregion
            return
        }
        
        let inputFormat = inputNode.inputFormat(forBus: 0)
        // #region agent log
        writeAudioDebugLog("Mic input format", data: ["hypothesisId": "A", "sampleRate": inputFormat.sampleRate, "channels": inputFormat.channelCount])
        // #endregion
        guard let converter = AVAudioConverter(from: inputFormat, to: geminiInputFormat) else {
            // #region agent log
            writeAudioDebugLog("Failed to create mic converter", data: ["hypothesisId": "A", "inputFormat": inputFormat.description])
            // #endregion
            return
        }
        
        micTapLogCounter = 0
        let targetSampleRate = geminiInputFormat.sampleRate
        let sourceSampleRate = inputFormat.sampleRate

        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            
            self.micTapLogCounter += 1
            // #region agent log
            if self.micTapLogCounter <= 3 || self.micTapLogCounter % 100 == 0 {
                writeAudioDebugLog("Mic tap fired", data: [
                    "hypothesisId": "A",
                    "count": self.micTapLogCounter,
                    "frames": buffer.frameLength,
                    "hasCallback": self.onAudioCaptured != nil
                ])
            }
            // #endregion
            
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * targetSampleRate / sourceSampleRate)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.geminiInputFormat, frameCapacity: capacity) else { return }
            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil,
                  converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
            let data = Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)

            self.onAudioCaptured?(data)
        }
        
        if engineRunning {
            isRecording = true
            // #region agent log
            writeAudioDebugLog("Mic tap installed on running engine", data: ["hypothesisId": "C"])
            // #endregion
        }
    }
    
    func stopRecording() {
        if isRecording {
            inputNode.removeTap(onBus: 0)
            isRecording = false
        }
        audioEngine.stop()
        outputNode.stop()
        engineRunning = false
        isPlaying = false
    }
    
    func playIncomingAudio(data: Data) {
        guard data.count >= 2 else { return }
        
        if !engineRunning {
            startEngineForPlayback()
        }
        
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: geminiOutputFormat, frameCapacity: frameCount) else {
            // #region agent log
            writeAudioDebugLog("Failed to create pcmBuffer", data: ["hypothesisId": "B"])
            // #endregion
            return
        }
        pcmBuffer.frameLength = frameCount
        
        let audioBuffer = pcmBuffer.audioBufferList.pointee.mBuffers
        data.copyBytes(to: audioBuffer.mData!.assumingMemoryBound(to: UInt8.self), count: data.count)
        
        // Convert Int16 -> Float32 (same sample rate, just format change)
        guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount) else {
            // #region agent log
            writeAudioDebugLog("Failed to create floatBuffer", data: ["hypothesisId": "B"])
            // #endregion
            return
        }
        floatBuffer.frameLength = frameCount
        
        // Manual Int16 -> Float32 conversion (avoids AVAudioConverter issues)
        let int16Ptr = pcmBuffer.int16ChannelData![0]
        let float32Ptr = floatBuffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            float32Ptr[i] = Float(int16Ptr[i]) / 32768.0
        }
        
        playbackStopTimer?.cancel()
        self.isPlaying = true
        
        // #region agent log
        writeAudioDebugLog("Scheduling buffer", data: [
            "hypothesisId": "B",
            "frames": frameCount,
            "engineRunning": engineRunning,
            "outputNodePlaying": outputNode.isPlaying
        ])
        // #endregion
        
        outputNode.scheduleBuffer(floatBuffer) { [weak self] in
            let stopItem = DispatchWorkItem { [weak self] in
                self?.isPlaying = false
            }
            self?.playbackStopTimer = stopItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: stopItem)
        }
        
        if !outputNode.isPlaying {
            outputNode.play()
            // #region agent log
            writeAudioDebugLog("Called outputNode.play()", data: ["hypothesisId": "B"])
            // #endregion
        }
    }
}