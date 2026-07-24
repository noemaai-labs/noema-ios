import Foundation
import SwiftUI

/// Remote transcription backend targeting OpenAI-compatible
/// `/v1/audio/transcriptions` endpoints. Suitable for self-hosted Qwen2-Audio
/// servers, whisper.cpp `server` mode, or any OpenAI-API-compatible gateway.
struct AudioLMRemoteBackend: TranscriptionBackend {
    let engineID: TranscriptionEngineID = .audioLanguageModel
    let endpointURL: URL
    let apiKey: String?
    let modelID: String

    static let keychainService = "com.noema.audioLMRemote"

    static var storedEndpointString: String {
        UserDefaults.standard.string(forKey: TranscriptionSettings.audioLMEndpointURLKey) ?? ""
    }

    static var storedModelID: String {
        let value = UserDefaults.standard.string(forKey: TranscriptionSettings.audioLMModelIDKey) ?? ""
        return value.isEmpty ? "whisper-1" : value
    }

    static var storedAPIKey: String? {
        guard let data = try? KeychainStore.read(
            service: keychainService,
            account: TranscriptionSettings.audioLMKeychainKey
        ), let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return nil
        }
        return key
    }

    static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try KeychainStore.delete(
                service: keychainService,
                account: TranscriptionSettings.audioLMKeychainKey
            )
        } else if let data = trimmed.data(using: .utf8) {
            try KeychainStore.write(
                service: keychainService,
                account: TranscriptionSettings.audioLMKeychainKey,
                data: data
            )
        }
    }

    static var isConfigured: Bool {
        guard let url = URL(string: storedEndpointString), !storedEndpointString.isEmpty else {
            return false
        }
        return url.scheme?.lowercased().hasPrefix("http") == true
    }

    static func makeIfConfigured() -> AudioLMRemoteBackend? {
        guard let url = URL(string: storedEndpointString), isConfigured else { return nil }
        return AudioLMRemoteBackend(
            endpointURL: url,
            apiKey: storedAPIKey,
            modelID: storedModelID
        )
    }

    func supportsOnDeviceRecognition(localeIdentifier: String) -> Bool { false }

    func transcribe(
        mediaURL: URL,
        originalFilename: String,
        options: TranscriptionRequestOptions,
        onEvent: @escaping @Sendable (TranscriptionEvent) -> Void
    ) async throws -> TranscriptArtifact {
        if options.requiresOnDeviceRecognition {
            throw TranscriptionError.onDeviceRecognitionUnavailable(options.localeIdentifier)
        }

        let data = try await performUpload(mediaURL: mediaURL, options: options)
        let decoded = try parseResponse(data: data)

        let segments: [TranscriptSegment] = decoded.segments?.map { seg in
            TranscriptSegment(
                text: seg.text,
                startTime: seg.start ?? 0,
                duration: max(0, (seg.end ?? 0) - (seg.start ?? 0)),
                confidence: seg.avg_logprob
            )
        } ?? []

        let artifact = TranscriptArtifact(
            engineID: .audioLanguageModel,
            localeIdentifier: decoded.language ?? options.localeIdentifier,
            originalFilename: originalFilename,
            sourceMediaPath: mediaURL.path,
            transcriptText: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments
        )
        guard !artifact.transcriptText.isEmpty else {
            throw TranscriptionError.emptyTranscript
        }
        onEvent(.completed(artifact))
        return artifact
    }

    private func performUpload(mediaURL: URL, options: TranscriptionRequestOptions) async throws -> Data {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "noema-audio-" + UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: mediaURL)
        let mimeType = MIMEType.guess(for: mediaURL)
        let filename = mediaURL.lastPathComponent

        var body = Data()
        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(modelID)\r\n")

        let trimmedLocale = options.localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocale.isEmpty {
            let languageTag = String(trimmedLocale.split(separator: "-").first ?? Substring(trimmedLocale))
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(languageTag)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("verbose_json\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n")

        append("--\(boundary)--\r\n")

        request.httpBody = body
        request.timeoutInterval = 600

        guard !NetworkKillSwitch.shouldBlock(request: request) else {
            throw URLError(.notConnectedToInternet)
        }
        NetworkKillSwitch.track(session: URLSession.shared)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw NSError(domain: "AudioLMRemoteBackend", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Remote transcription failed (\(http.statusCode)): \(snippet)"
            ])
        }
        return data
    }

    private func parseResponse(data: Data) throws -> VerboseJSONResponse {
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(VerboseJSONResponse.self, from: data) {
            return decoded
        }
        struct MinimalResponse: Decodable { let text: String }
        if let minimal = try? decoder.decode(MinimalResponse.self, from: data) {
            return VerboseJSONResponse(text: minimal.text, language: nil, segments: nil)
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return VerboseJSONResponse(text: text, language: nil, segments: nil)
        }
        throw TranscriptionError.emptyTranscript
    }

    private struct VerboseJSONResponse: Decodable {
        let text: String
        let language: String?
        let segments: [Segment]?

        struct Segment: Decodable {
            let text: String
            let start: Double?
            let end: Double?
            let avg_logprob: Double?
        }
    }
}

private enum MIMEType {
    static func guess(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/mp4"
        case "aif", "aiff": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Settings UI

struct AudioLMRemoteEndpointView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpointString: String = AudioLMRemoteBackend.storedEndpointString
    @State private var modelID: String = AudioLMRemoteBackend.storedModelID
    @State private var apiKey: String = AudioLMRemoteBackend.storedAPIKey ?? ""
    @State private var useRemoteASR: Bool = TranscriptionSettings.selectedEngineID == .audioLanguageModel
    @State private var testMessage: String?
    @State private var testIsError = false

    var body: some View {
#if os(macOS)
        macBody
#else
        iosBody
#endif
    }

#if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(LocalizedStringKey("Remote Audio Endpoint"))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel(LocalizedStringKey("Close"))
            }
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 28)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 22) {
                    macFieldRow(title: "Base URL") {
                        TextField(
                            "",
                            text: $endpointString,
                            prompt: Text("https://host/v1/audio/transcriptions")
                        )
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .disableAutocorrection(true)
                    }

                    macFieldRow(title: "Model ID") {
                        TextField("", text: $modelID, prompt: Text("whisper-1"))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .disableAutocorrection(true)
                    }

                    macFieldRow(title: "API Key (optional)") {
                        SecureField("", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                    }
                }
                .padding(.top, 34)

                Divider()
                    .padding(.vertical, 28)

                Toggle(isOn: $useRemoteASR) {
                    Text(LocalizedStringKey("Use Remote ASR"))
                        .font(.system(size: 17))
                }
                .toggleStyle(.switch)

                Divider()
                    .padding(.vertical, 28)

                Button(LocalizedStringKey("Send Test Request")) {
                    Task { await runTest() }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!draftIsConfigured)

                if let testMessage {
                    Text(testMessage)
                        .font(.callout)
                        .foregroundStyle(testIsError ? .red : .green)
                        .padding(.top, 14)
                }

                Text(LocalizedStringKey("Noema posts the media file to this endpoint using the OpenAI /v1/audio/transcriptions schema. The server must accept multipart/form-data with model, language, response_format, and file fields."))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)

                Spacer(minLength: 28)

                HStack(spacing: 14) {
                    Spacer()
                    Button(LocalizedStringKey("Cancel")) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(LocalizedStringKey("Save")) {
                        saveDraft()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 30)
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .frame(width: 720, height: 640)
    }

    private func macFieldRow<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .frame(width: 145, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
    }
#endif

    private var iosBody: some View {
        Form {
            Section(LocalizedStringKey("Endpoint")) {
                TextField(
                    LocalizedStringKey("Base URL"),
                    text: $endpointString,
                    prompt: Text("https://host/v1/audio/transcriptions")
                )
#if !os(macOS)
                .autocapitalization(.none)
                .keyboardType(.URL)
#endif
                .disableAutocorrection(true)
                .onChange(of: endpointString) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: TranscriptionSettings.audioLMEndpointURLKey)
                }

                TextField(
                    LocalizedStringKey("Model ID"),
                    text: $modelID,
                    prompt: Text("whisper-1")
                )
#if !os(macOS)
                .autocapitalization(.none)
#endif
                .disableAutocorrection(true)
                .onChange(of: modelID) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: TranscriptionSettings.audioLMModelIDKey)
                }

                SecureField(LocalizedStringKey("API Key (optional)"), text: $apiKey)
                    .onChange(of: apiKey) { _, newValue in
                        try? AudioLMRemoteBackend.saveAPIKey(newValue)
                    }
            }

            Section {
                Button(LocalizedStringKey("Use Remote ASR")) {
                    UserDefaults.standard.set(TranscriptionEngineID.audioLanguageModel.rawValue, forKey: TranscriptionSettings.engineIDKey)
                }
                .disabled(!AudioLMRemoteBackend.isConfigured)

                Button(LocalizedStringKey("Send Test Request")) {
                    Task { await runTest() }
                }

                if let testMessage {
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(testIsError ? .red : .green)
                }
            }

            Section {
                Text(LocalizedStringKey("Noema posts the media file to this endpoint using the OpenAI /v1/audio/transcriptions schema. The server must accept multipart/form-data with model, language, response_format, and file fields."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(LocalizedStringKey("Remote Audio Endpoint"))
#if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
#endif
    }

    private var draftIsConfigured: Bool {
        let trimmed = endpointString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            return false
        }
        return url.scheme?.lowercased().hasPrefix("http") == true
    }

    private func saveDraft() {
        UserDefaults.standard.set(endpointString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: TranscriptionSettings.audioLMEndpointURLKey)
        UserDefaults.standard.set(modelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: TranscriptionSettings.audioLMModelIDKey)
        try? AudioLMRemoteBackend.saveAPIKey(apiKey)

        if useRemoteASR, draftIsConfigured {
            UserDefaults.standard.set(TranscriptionEngineID.audioLanguageModel.rawValue, forKey: TranscriptionSettings.engineIDKey)
        } else if TranscriptionSettings.selectedEngineID == .audioLanguageModel {
            UserDefaults.standard.set(TranscriptionBackendFactory.preferredLocalWhisperEngineID().rawValue, forKey: TranscriptionSettings.engineIDKey)
        }
    }

    private func draftBackendIfConfigured() -> AudioLMRemoteBackend? {
        let trimmed = endpointString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), draftIsConfigured else { return nil }
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return AudioLMRemoteBackend(
            endpointURL: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID: trimmedModelID.isEmpty ? "whisper-1" : trimmedModelID
        )
    }

    @MainActor
    private func runTest() async {
        testMessage = String(localized: "Sending test request…")
        testIsError = false
        guard let backend = draftBackendIfConfigured() else {
            testMessage = String(localized: "Enter a valid URL first.")
            testIsError = true
            return
        }

        do {
            let tempURL = try makeSilentSampleAudio()
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let artifact = try await backend.transcribe(
                mediaURL: tempURL,
                originalFilename: "test.wav",
                options: TranscriptionRequestOptions(
                    localeIdentifier: "en-US",
                    requiresOnDeviceRecognition: false,
                    reportsPartialResults: false
                ),
                onEvent: { _ in }
            )
            testMessage = String.localizedStringWithFormat(
                String(localized: "Endpoint responded. Returned %d characters."),
                artifact.transcriptText.count
            )
            testIsError = false
        } catch TranscriptionError.emptyTranscript {
            testMessage = String(localized: "Endpoint returned no transcript (expected for silent sample).")
            testIsError = false
        } catch {
            testMessage = error.localizedDescription
            testIsError = true
        }
    }

    private func makeSilentSampleAudio() throws -> URL {
        // 0.2s silent 16 kHz mono WAV for connectivity testing.
        let sampleRate: UInt32 = 16_000
        let frameCount: UInt32 = sampleRate / 5
        let byteRate = sampleRate * 2
        let dataSize = frameCount * 2
        let totalSize = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(totalSize).littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        header.append(Data(count: Int(dataSize)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noema-audiolm-test-\(UUID().uuidString).wav")
        try header.write(to: url)
        return url
    }
}
