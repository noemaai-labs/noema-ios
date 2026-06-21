import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

enum MediaAudioExtractorError: LocalizedError {
    case unsupportedAsset
    case exportFailed(String)
    case conversionFailed(String)
    case oversizedForFullBufferDecode

    var errorDescription: String? {
        switch self {
        case .unsupportedAsset:
            return String(localized: "The media file has no audio track.")
        case .exportFailed(let message):
            return String.localizedStringWithFormat(
                String(localized: "Failed to extract audio: %@"),
                message
            )
        case .conversionFailed(let message):
            return String.localizedStringWithFormat(
                String(localized: "Audio conversion failed: %@"),
                message
            )
        case .oversizedForFullBufferDecode:
            return String(localized: "This media is too long for whisper.cpp's memory-safe decoder. Trim it or use Apple Speech/WhisperKit, then retry.")
        }
    }
}

/// Utilities for preparing media for audio-only ASR backends.
enum MediaAudioExtractor {
    static let whisperCppFullBufferDecodeLimitBytes: Int64 = 384 * 1024 * 1024
    private static let whisperCppTargetSampleRate = 16_000.0

    /// Returns a URL that is safe to feed to audio-only backends. If the input
    /// is already audio, the original URL is returned unchanged. If it is a
    /// video, the audio track is exported to a temporary .m4a file — the
    /// caller is responsible for deleting it.
    @MainActor
    static func prepareAudioSource(from mediaURL: URL) async throws -> (url: URL, cleanup: (@Sendable () -> Void)?) {
        #if canImport(AVFoundation)
        guard let kind = TranscriptionMediaSupport.kind(for: mediaURL) else {
            return (mediaURL, nil)
        }
        if kind == .audio {
            return (mediaURL, nil)
        }

        let asset = AVURLAsset(url: mediaURL)
        let tracks = try await asset.load(.tracks)
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard !audioTracks.isEmpty else {
            throw MediaAudioExtractorError.unsupportedAsset
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-asr-\(UUID().uuidString).m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaAudioExtractorError.exportFailed("No export session available")
        }
        exportSession.outputFileType = .m4a
        exportSession.outputURL = outputURL

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            let cleanup: @Sendable () -> Void = {
                try? FileManager.default.removeItem(at: outputURL)
            }
            return (outputURL, cleanup)
        default:
            let message = exportSession.error?.localizedDescription
                ?? String(describing: exportSession.status.rawValue)
            throw MediaAudioExtractorError.exportFailed(message)
        }
        #else
        return (mediaURL, nil)
        #endif
    }

    /// Decodes an audio file to a 16 kHz mono Float32 sample array, which is
    /// what whisper.cpp expects as input. Raises on failure.
    static func decodeMonoPCM16k(from url: URL) throws -> [Float] {
        #if canImport(AVFoundation)
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        try enforceFullBufferDecodeBudget(sourceFrameCount: file.length, sourceFormat: sourceFormat)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: whisperCppTargetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MediaAudioExtractorError.conversionFailed("Target format init")
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw MediaAudioExtractorError.conversionFailed("Converter init")
        }

        let frameCapacity = AVAudioFrameCount(file.length)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: frameCapacity
        ) else {
            throw MediaAudioExtractorError.conversionFailed("Source buffer alloc")
        }
        try file.read(into: sourceBuffer)

        let ratio = 16_000.0 / sourceFormat.sampleRate
        let estimated = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimated) else {
            throw MediaAudioExtractorError.conversionFailed("Target buffer alloc")
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error, let error {
            throw MediaAudioExtractorError.conversionFailed(error.localizedDescription)
        }

        guard let channelData = targetBuffer.floatChannelData else {
            return []
        }

        let length = Int(targetBuffer.frameLength)
        let pointer = channelData[0]
        return Array(UnsafeBufferPointer(start: pointer, count: length))
        #else
        throw MediaAudioExtractorError.conversionFailed("AVFoundation unavailable")
        #endif
    }

    static func estimatedFullBufferDecodeBytes(
        sourceFrameCount: Int64,
        sourceSampleRate: Double,
        sourceBytesPerFrame: UInt32,
        targetSampleRate: Double = whisperCppTargetSampleRate
    ) -> Int64 {
        guard sourceFrameCount > 0, sourceSampleRate > 0, sourceBytesPerFrame > 0, targetSampleRate > 0 else {
            return 0
        }
        let sourceBytes = Double(sourceFrameCount) * Double(sourceBytesPerFrame)
        let targetFrames = ceil(Double(sourceFrameCount) * targetSampleRate / sourceSampleRate) + 1024
        let targetBytes = targetFrames * Double(MemoryLayout<Float>.stride)
        let totalBytes = sourceBytes + targetBytes
        guard totalBytes.isFinite else { return Int64.max }
        if totalBytes >= Double(Int64.max) { return Int64.max }
        return Int64(totalBytes.rounded(.up))
    }

    #if canImport(AVFoundation)
    private static func enforceFullBufferDecodeBudget(
        sourceFrameCount: AVAudioFramePosition,
        sourceFormat: AVAudioFormat
    ) throws {
        let streamDescription = sourceFormat.streamDescription.pointee
        let fallbackBytesPerFrame = max(UInt32(1), sourceFormat.channelCount) * UInt32(MemoryLayout<Float>.stride)
        let sourceBytesPerFrame = max(streamDescription.mBytesPerFrame, fallbackBytesPerFrame)
        let estimatedBytes = estimatedFullBufferDecodeBytes(
            sourceFrameCount: Int64(sourceFrameCount),
            sourceSampleRate: sourceFormat.sampleRate,
            sourceBytesPerFrame: sourceBytesPerFrame
        )
        guard estimatedBytes <= whisperCppFullBufferDecodeLimitBytes else {
            throw MediaAudioExtractorError.oversizedForFullBufferDecode
        }
    }
    #endif
}
