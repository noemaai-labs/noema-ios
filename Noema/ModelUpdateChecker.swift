import Foundation

struct ModelUpdateCheckResult: Equatable {
    enum State: Equatable {
        case current
        case updateAvailable
        case missingRemoteQuant
        case unableToCompare
    }

    enum Difference: String, CaseIterable, Equatable {
        case checksum
        case size
        case primaryFile
        case partCount
    }

    let state: State
    let differences: [Difference]
    let remoteQuant: QuantInfo?
}

enum ModelUpdateChecker {
    static func compare(installed: ModelProvenanceSnapshot, against details: ModelDetails) -> ModelUpdateCheckResult {
        guard let remoteQuant = matchingQuant(for: installed, in: details.quants) else {
            return ModelUpdateCheckResult(state: .missingRemoteQuant, differences: [], remoteQuant: nil)
        }

        var differences: [ModelUpdateCheckResult.Difference] = []
        var comparable = false

        if let installedChecksum = normalizedChecksum(installed.checksum),
           let remoteChecksum = normalizedChecksum(remoteQuant.primaryDownloadPart.sha256) {
            comparable = true
            if installedChecksum != remoteChecksum {
                differences.append(.checksum)
            }
        }

        if installed.sizeBytes > 0, remoteQuant.sizeBytes > 0 {
            comparable = true
            if installed.sizeBytes != remoteQuant.sizeBytes {
                differences.append(.size)
            }
        }

        let installedFilename = URL(fileURLWithPath: installed.localPath).lastPathComponent
        let remoteFilename = remoteQuant.primaryDownloadRelativePath.split(separator: "/").last.map(String.init) ?? remoteQuant.primaryDownloadRelativePath
        if !installedFilename.isEmpty, !remoteFilename.isEmpty {
            comparable = true
            if installedFilename.localizedCaseInsensitiveCompare(remoteFilename) != .orderedSame {
                differences.append(.primaryFile)
            }
        }

        if remoteQuant.isMultipart {
            comparable = true
            if installedFilename.localizedCaseInsensitiveContains("-of-") == false {
                differences.append(.partCount)
            }
        }

        if !differences.isEmpty {
            return ModelUpdateCheckResult(state: .updateAvailable, differences: differences, remoteQuant: remoteQuant)
        }

        return ModelUpdateCheckResult(
            state: comparable ? .current : .unableToCompare,
            differences: [],
            remoteQuant: remoteQuant
        )
    }

    private static func matchingQuant(for installed: ModelProvenanceSnapshot, in quants: [QuantInfo]) -> QuantInfo? {
        let installedLabel = installed.quantLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameFormat = quants.filter { $0.format.rawValue == installed.formatRawValue }

        if let exact = sameFormat.first(where: {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(installedLabel) == .orderedSame
        }) {
            return exact
        }

        let installedFilename = URL(fileURLWithPath: installed.localPath).lastPathComponent
        return sameFormat.first { quant in
            quant.allRelativeDownloadPaths.contains { path in
                let remoteFilename = path.split(separator: "/").last.map(String.init) ?? path
                return remoteFilename.localizedCaseInsensitiveCompare(installedFilename) == .orderedSame
            }
        }
    }

    private static func normalizedChecksum(_ checksum: String?) -> String? {
        guard var checksum = checksum?.trimmingCharacters(in: .whitespacesAndNewlines), !checksum.isEmpty else {
            return nil
        }
        if let range = checksum.range(of: ":") {
            checksum = String(checksum[range.upperBound...])
        }
        return checksum.lowercased()
    }
}
