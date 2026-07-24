import SwiftUI

struct BenchmarkingCenterView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var chatVM: ChatVM

    @State private var stored: [ModelBenchmarkResultStore.StoredResult] = []
    @State private var selectedModelPath: String?
    @State private var justFinished: ModelBenchmarkResult?

    @State private var benchmarking = false
    @State private var benchmarkProgress: Double = 0
    @State private var benchmarkDetail = ""
    @State private var benchmarkError: String?
    @State private var benchmarkTask: Task<Void, Never>?
    @State private var benchmarkTaskID: UUID?
    @State private var showRAMSafetyWarning = false
    @State private var exportURL: URL?

    // MARK: Derived

    private var benchmarkableModels: [LocalModel] {
        modelManager.downloadedModels.filter { $0.format != .ane }
    }

    private var selectedModel: LocalModel? {
        if let path = selectedModelPath,
           let match = benchmarkableModels.first(where: { $0.url.path == path }) {
            return match
        }
        return modelManager.loadedModel ?? benchmarkableModels.first
    }

    private var leaderboard: [ModelBenchmarkResultStore.StoredResult] {
        stored.sorted { $0.result.generationRate > $1.result.generationRate }
    }

    private var bestGenerationRate: Double {
        leaderboard.map(\.result.generationRate).max() ?? 0
    }

    /// The result to spotlight in the "Result" tiles for the selected model.
    private var resultForSelected: ModelBenchmarkResult? {
        guard let model = selectedModel else { return nil }
        if let justFinished, benchmarkTaskCompletedPath == model.url.path {
            return justFinished
        }
        return stored.first(where: { $0.modelPath == model.url.path })?.result
    }
    @State private var benchmarkTaskCompletedPath: String?

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                runSection
                resultSection
                leaderboardSection
            }
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(pageBackground.ignoresSafeArea())
        .navigationTitle(LocalizedStringKey("Benchmarking Center"))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let exportURL, !leaderboard.isEmpty {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .alert(LocalizedStringKey("RAM Safety Checks"), isPresented: $showRAMSafetyWarning) {
            Button(LocalizedStringKey("Continue"), role: .destructive) {
                runBenchmark(bypassRAMCheck: true)
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("Model likely exceeds memory budget. Lower context size or use a smaller quant/model."))
        }
        .onAppear(perform: reload)
        .onDisappear { benchmarkTask?.cancel() }
    }

    // MARK: Run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Run"))

            if benchmarkableModels.isEmpty {
                emptyModelsNotice
            } else {
                modelPicker

                HStack(spacing: 10) {
                    Button {
                        runBenchmark()
                    } label: {
                        Label(LocalizedStringKey("Run Benchmark"), systemImage: "speedometer")
                            .industrialCTAWidth()
                    }
                    .buttonStyle(.industrial(.prominent, tint: .orange))
                    .disabled(benchmarking || selectedModel == nil)

                    if benchmarking {
                        Button(role: .cancel) {
                            cancelBenchmark()
                        } label: {
                            Text(LocalizedStringKey("Cancel"))
                        }
                        .buttonStyle(.industrial(.quiet))
                    }
                }

                if benchmarking {
                    VStack(alignment: .leading, spacing: 6) {
                        IndustrialProgressBar(value: benchmarkProgress, tint: .orange)
                        Text(benchmarkDetail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                if let benchmarkError {
                    Text(benchmarkError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                deviceRAMLine
            }
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(benchmarkableModels) { model in
                Button {
                    selectedModelPath = model.url.path
                } label: {
                    if model.url.path == selectedModel?.url.path {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if let model = selectedModel {
                    formatBadge(model.format)
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(String(format: "%.1f GB", model.sizeGB))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(LocalizedStringKey("Select a model"))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .benchCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deviceRAMLine: some View {
        let deviceGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return HStack(spacing: 6) {
            Image(systemName: "memorychip")
                .font(.system(size: 10, weight: .medium))
            if let model = selectedModel {
                Text(String(format: String(localized: "Weights %.1f GB · Device %.0f GB RAM"),
                            model.sizeGB, deviceGB))
            } else {
                Text(String(format: String(localized: "Device %.0f GB RAM"), deviceGB))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var emptyModelsNotice: some View {
        Text(LocalizedStringKey("Install a model in Stored to benchmark it here."))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .benchCard()
    }

    // MARK: Result tiles

    @ViewBuilder
    private var resultSection: some View {
        if let model = selectedModel {
            VStack(alignment: .leading, spacing: 12) {
                IndustrialSectionHeader(LocalizedStringKey("Result"), detail: model.displayName)

                if let result = resultForSelected {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        tile("Generation", value: String(format: "%.1f", result.generationRate), unit: "tok/s", systemImage: "speedometer")
                        tile("Prefill", value: String(format: "%.0f", result.promptRate), unit: "tok/s", systemImage: "bolt")
                        tile("First token", value: String(format: "%.2f", result.timeToFirstToken), unit: "s", systemImage: "timer")
                        tile("Total time", value: String(format: "%.1f", result.totalDuration), unit: "s", systemImage: "clock")
                        tile("Peak memory", value: String(format: "%.1f", gb(result.peakMemoryBytes)), unit: "GB", systemImage: "memorychip")
                        tile("Added memory", value: String(format: "%.1f", gb(result.memoryDeltaBytes)), unit: "GB", systemImage: "arrow.up.right")
                    }
                    Text(String(format: String(localized: "Measured %@"),
                                result.completedAt.formatted(.relative(presentation: .named))))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if !benchmarking {
                    Text(LocalizedStringKey("Not benchmarked yet — run it above."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .benchCard()
                }
            }
        }
    }

    private func tile(_ label: LocalizedStringKey, value: String, unit: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .medium))
                Text(label)
                    .textCase(.uppercase)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
            }
            .foregroundStyle(Color.primary.opacity(0.45))

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .benchCard()
    }

    // MARK: Leaderboard

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(
                LocalizedStringKey("On-device results"),
                detail: leaderboard.isEmpty ? nil : "\(leaderboard.count)"
            )

            if leaderboard.isEmpty {
                Text(LocalizedStringKey("No benchmarks yet. Run one above to start the leaderboard."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .benchCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(leaderboard.enumerated()), id: \.element.id) { idx, record in
                        NavigationLink {
                            BenchmarkDetailView(record: record)
                        } label: {
                            leaderRow(rank: idx + 1, record: record)
                        }
                        .buttonStyle(.plain)
                        if idx < leaderboard.count - 1 {
                            Divider().overlay(Color.primary.opacity(0.06))
                        }
                    }
                }
                .benchCard()

                Text(LocalizedStringKey("Higher generation tok/s is faster. Peak memory is the real RAM used during the run."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func leaderRow(rank: Int, record: ModelBenchmarkResultStore.StoredResult) -> some View {
        let r = record.result
        let isBest = r.generationRate == bestGenerationRate
        return HStack(alignment: .center, spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.modelName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    formatBadge(r.format)
                    Text(record.quant.isEmpty ? "—" : record.quant)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text(r.completedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", r.generationRate))
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isBest ? Color.green : Color.primary)
                    Text("tok/s")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(String(format: String(localized: "prefill %.0f · ttft %.2fs · %.1f GB"),
                            r.promptRate, r.timeToFirstToken, gb(r.peakMemoryBytes)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.22))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func reload() {
        let all = ModelBenchmarkResultStore.loadAll()
        stored = Array(all.values)
        if selectedModelPath == nil {
            selectedModelPath = modelManager.loadedModel?.url.path ?? benchmarkableModels.first?.url.path
        }
        if stored.isEmpty {
            exportURL = nil
        } else if let data = try? ModelBenchmarkResultStore.exportData(records: all) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("noema-benchmark-results.json")
            try? data.write(to: url)
            exportURL = url
        }
    }

    private func runBenchmark(bypassRAMCheck: Bool = false) {
        guard !benchmarking, let model = selectedModel, model.format != .ane else { return }
        let settings = modelManager.settings(for: model)
        benchmarkError = nil
        benchmarking = true
        benchmarkProgress = 0
        benchmarkDetail = String(localized: "Benchmark running…")
        let taskID = UUID()
        benchmarkTaskID = taskID

        benchmarkTask = Task { [model, chatVM] in
            do {
                let result = try await ModelBenchmarkService.run(
                    model: model,
                    settings: settings,
                    vm: chatVM,
                    bypassRAMCheck: bypassRAMCheck
                ) { update in
                    benchmarkProgress = update.fraction
                    benchmarkDetail = update.detail
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard benchmarkTaskID == taskID else { return }
                    ModelBenchmarkResultStore.save(result: result, for: model)
                    justFinished = result
                    benchmarkTaskCompletedPath = model.url.path
                    benchmarkError = nil
                    reload()
                }
            } catch is CancellationError {
                await MainActor.run {
                    if benchmarkTaskID == taskID { benchmarkError = nil }
                }
            } catch ModelBenchmarkError.ramSafetyBlocked {
                await MainActor.run {
                    guard benchmarkTaskID == taskID else { return }
                    if bypassRAMCheck {
                        benchmarkError = ModelBenchmarkError.ramSafetyBlocked.localizedDescription
                    } else {
                        chatVM.loadError = nil
                        benchmarkError = nil
                        showRAMSafetyWarning = true
                    }
                }
            } catch {
                await MainActor.run {
                    guard benchmarkTaskID == taskID else { return }
                    benchmarkError = error.localizedDescription
                }
            }
            await MainActor.run {
                if benchmarkTaskID == taskID {
                    benchmarking = false
                    benchmarkTask = nil
                    benchmarkTaskID = nil
                }
            }
        }
    }

    private func cancelBenchmark() {
        benchmarkTask?.cancel()
        benchmarking = false
        benchmarkTaskID = nil
    }

    // MARK: Style helpers

    private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1_073_741_824.0 }

    private func formatBadge(_ format: ModelFormat) -> some View {
#if os(macOS)
        IndustrialBadge(verbatim: format.rawValue, tint: formatColor(format))
#else
        Text(format.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(formatColor(format))
            )
#endif
    }

    private func formatColor(_ format: ModelFormat) -> Color {
        switch format {
        case .gguf: return .blue
        case .mlx: return .orange
        case .et: return .teal
        case .ane: return .green
        case .afm: return .indigo
        case .coreai: return .purple
        }
    }

    private var horizontalPadding: CGFloat {
#if os(macOS)
        return 0
#else
        return 16
#endif
    }

    private var pageBackground: Color {
#if os(macOS)
        return .clear
#else
        return Color(.systemGroupedBackground)
#endif
    }
}

// MARK: - Full detail for one stored result

private struct BenchmarkDetailView: View {
    let record: ModelBenchmarkResultStore.StoredResult

    private var r: ModelBenchmarkResult { record.result }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                metricsSection
                if let preview = sampleOutput { sampleSection(preview) }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, detailHorizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(detailPageBackground.ignoresSafeArea())
        .navigationTitle(record.modelName)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                formatBadge(r.format)
                Text(record.quant.isEmpty ? "—" : record.quant)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f GB", record.sizeGB))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if r.kvCacheOffloadActive {
                    IndustrialBadge(LocalizedStringKey("KV cache offload"), tint: .blue, dot: true)
                }
            }
            Text(String(format: String(localized: "Measured %@"),
                        r.completedAt.formatted(.relative(presentation: .named))))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Result"))
            VStack(spacing: 0) {
                metricRow("Generation", String(format: "%.1f tok/s", r.generationRate))
                sep
                metricRow("Prefill", String(format: "%.0f tok/s", r.promptRate))
                sep
                metricRow("First token", String(format: "%.2f s", r.timeToFirstToken))
                sep
                metricRow("Total time", String(format: "%.1f s", r.totalDuration))
                sep
                metricRow("Peak memory", String(format: "%.2f GB", gb(r.peakMemoryBytes)))
                sep
                metricRow("Added memory", String(format: "%.2f GB", gb(r.memoryDeltaBytes)))
                sep
                metricRow("Prompt tokens", "\(r.promptTokens)")
                sep
                metricRow("Generated tokens", "\(r.generationTokens)")
                if let acceptance = r.speculativeTimings?.acceptanceRate {
                    sep
                    metricRow("Draft acceptance", String(format: "%.0f%%", acceptance * 100))
                }
            }
            .benchCard()
        }
    }

    @ViewBuilder
    private func sampleSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IndustrialSectionHeader(LocalizedStringKey("Sample output"))
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.8))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .benchCard()
        }
    }

    private var sampleOutput: String? {
        let trimmed = r.outputPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func metricRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sep: some View { Divider().overlay(Color.primary.opacity(0.06)) }

    private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1_073_741_824.0 }

    private func formatBadge(_ format: ModelFormat) -> some View {
#if os(macOS)
        IndustrialBadge(verbatim: format.rawValue, tint: formatColor(format))
#else
        Text(format.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(formatColor(format))
            )
#endif
    }

    private func formatColor(_ format: ModelFormat) -> Color {
        switch format {
        case .gguf: return .blue
        case .mlx: return .orange
        case .et: return .teal
        case .ane: return .green
        case .afm: return .indigo
        case .coreai: return .purple
        }
    }

    private var detailHorizontalPadding: CGFloat {
#if os(macOS)
        return 0
#else
        return 16
#endif
    }

    private var detailPageBackground: Color {
#if os(macOS)
        return .clear
#else
        return Color(.systemGroupedBackground)
#endif
    }
}

private extension Color {
    static var benchSurface: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(.secondarySystemGroupedBackground)
#endif
    }
}

private extension View {
    /// The Benchmarking Center's card surface: a quiet rounded fill with a
    /// hairline border that reads correctly in both light and dark on every
    /// platform.
    func benchCard(_ radius: CGFloat = 10) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.benchSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}
