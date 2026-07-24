import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Charts)
import Charts
#endif

public struct ChartRenderTool: Tool {
    public let name = "noema.chart.render"
    public let description = "Draw a chart (bar, line, scatter, or pie) from data and show it to the user in the chat. Provide one or more series of numeric values plus optional category labels. Returns confirmation that the chart was rendered."
    public let schema = #"""
    { "type":"object", "properties":{
        "type":{"type":"string","enum":["bar","line","scatter","pie"],"default":"bar","description":"Chart type."},
        "title":{"type":"string","description":"Optional chart title."},
        "labels":{"type":"array","items":{"type":"string"},"description":"Optional category labels for the x-axis (or pie slices), one per data point."},
        "series":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string","description":"Series name shown in the legend."},"values":{"type":"array","items":{"type":"number"},"description":"Numeric data points."}},"required":["values"]},"description":"One or more data series. For a pie chart only the first series is used."}
    }, "required":["series"] }
    """#

    public init() {}

    struct ChartSpec: Decodable, Sendable {
        let type: String?
        let title: String?
        let labels: [String]?
        let series: [Series]
        struct Series: Decodable, Sendable { let name: String?; let values: [Double] }
    }

    struct Output: Encodable { let ok: Bool; let type: String; let title: String?; let summary: String; let image_base64: String? }

    public func call(args: Data) async throws -> Data {
        let spec: ChartSpec
        do {
            spec = try JSONDecoder().decode(ChartSpec.self, from: args)
        } catch {
            return try JSONSerialization.data(withJSONObject: ["ok": false, "error": "Couldn't read the chart data. Provide series as [{\"name\":..,\"values\":[..]}]."])
        }
        // Drop non-finite values (NaN/inf would corrupt the chart), then bound the
        // workload: the view is built and rasterized on the main actor, so an
        // unbounded series list from a runaway model would hang or OOM the app.
        let sanitized = spec.series.map { series in
            ChartSpec.Series(name: series.name, values: series.values.filter(\.isFinite))
        }
        let nonEmpty = sanitized.filter { !$0.values.isEmpty }
        guard !nonEmpty.isEmpty else {
            return try JSONSerialization.data(withJSONObject: ["ok": false, "error": "Provide at least one series with finite numeric values."])
        }
        let maxSeries = 12
        let maxPointsPerSeries = 500
        guard nonEmpty.count <= maxSeries,
              (nonEmpty.map(\.values.count).max() ?? 0) <= maxPointsPerSeries else {
            return try JSONSerialization.data(withJSONObject: [
                "ok": false,
                "error": "Too much data to render: use at most \(maxSeries) series with \(maxPointsPerSeries) points each. Aggregate or sample the data first."
            ])
        }
        let boundedSpec = ChartSpec(type: spec.type, title: spec.title.map { String($0.prefix(200)) }, labels: spec.labels, series: nonEmpty)
        let type = (spec.type ?? "bar").lowercased()

        #if canImport(Charts) && canImport(SwiftUI)
        let png = await MainActor.run { ChartRenderer.renderPNG(spec: boundedSpec, type: type) }
        guard let png else {
            return try JSONSerialization.data(withJSONObject: ["ok": false, "error": "Couldn't render the chart on this device."])
        }
        let pointCount = nonEmpty.map(\.values.count).max() ?? 0
        let summary = "Rendered a \(type) chart with \(nonEmpty.count) series and \(pointCount) point\(pointCount == 1 ? "" : "s"); it is shown to the user."
        let output = Output(ok: true, type: type, title: spec.title, summary: summary, image_base64: png.base64EncodedString())
        return try JSONEncoder().encode(output)
        #else
        return try JSONSerialization.data(withJSONObject: ["ok": false, "error": "Charts aren't available on this platform."])
        #endif
    }
}

#if canImport(Charts) && canImport(SwiftUI)
@MainActor
enum ChartRenderer {
    static func renderPNG(spec: ChartRenderTool.ChartSpec, type: String) -> Data? {
        let view = ChartImageView(spec: spec, type: type)
            .frame(width: 640, height: 400)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        #if os(macOS)
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
        #else
        guard let uiImage = renderer.uiImage, let png = uiImage.pngData() else { return nil }
        return png
        #endif
    }
}

private struct ChartImageView: View {
    let spec: ChartRenderTool.ChartSpec
    let type: String

    private func label(at index: Int) -> String {
        if let labels = spec.labels, index < labels.count { return labels[index] }
        return "\(index + 1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.title3.weight(.semibold))
            }
            chart
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 1.0))
    }

    @ViewBuilder
    private var chart: some View {
        if type == "pie", let first = spec.series.first {
            Chart(Array(first.values.enumerated()), id: \.offset) { index, value in
                SectorMark(angle: .value("Value", value), innerRadius: .ratio(0.2))
                    .foregroundStyle(by: .value("Slice", label(at: index)))
            }
        } else {
            Chart {
                ForEach(Array(spec.series.enumerated()), id: \.offset) { seriesIndex, series in
                    let seriesName = series.name ?? "Series \(seriesIndex + 1)"
                    ForEach(Array(series.values.enumerated()), id: \.offset) { pointIndex, value in
                        xyMark(x: label(at: pointIndex), y: value, series: seriesName)
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func xyMark(x: String, y: Double, series: String) -> some ChartContent {
        switch type {
        case "line":
            LineMark(x: .value("X", x), y: .value("Y", y))
                .foregroundStyle(by: .value("Series", series))
        case "scatter":
            PointMark(x: .value("X", x), y: .value("Y", y))
                .foregroundStyle(by: .value("Series", series))
        default:
            BarMark(x: .value("X", x), y: .value("Y", y))
                .foregroundStyle(by: .value("Series", series))
        }
    }
}
#endif
