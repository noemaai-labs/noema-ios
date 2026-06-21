import Foundation

struct ModelProvenanceSnapshot: Codable, Equatable, Sendable {
    let modelID: String
    let displayName: String
    let alias: String?
    let formatRawValue: String
    let quantLabel: String
    let parameterCountLabel: String?
    let localPath: String
    let installRootPath: String
    let sizeBytes: Int64
    let installDate: Date
    let lastUsedDate: Date?
    let checksum: String?
    let isFavourite: Bool
    let totalLayers: Int
    let isMultimodal: Bool
    let isToolCapable: Bool
    let isMoE: Bool?
    let expertCount: Int?
    let defaultExperts: Int?
    let moeLayerCount: Int?

    init(installed: InstalledModel) {
        self.modelID = installed.modelID
        self.displayName = installed.displayName
        self.alias = installed.alias
        self.formatRawValue = installed.format.rawValue
        self.quantLabel = installed.quantLabel
        self.parameterCountLabel = installed.parameterCountLabel
        self.localPath = installed.url.path
        self.installRootPath = InstalledModelsStore.baseDir(for: installed.format, modelID: installed.modelID).path
        self.sizeBytes = installed.sizeBytes
        self.installDate = installed.installDate
        self.lastUsedDate = installed.lastUsed
        self.checksum = installed.checksum
        self.isFavourite = installed.isFavourite
        self.totalLayers = installed.totalLayers
        self.isMultimodal = installed.isMultimodal
        self.isToolCapable = installed.isToolCapable
        self.isMoE = installed.moeInfo?.isMoE
        self.expertCount = installed.moeInfo?.expertCount
        self.defaultExperts = installed.moeInfo?.defaultUsed
        self.moeLayerCount = installed.moeInfo?.moeLayerCount
    }

    init(model: LocalModel, installed: InstalledModel?) {
        if let installed {
            self = Self(installed: installed)
            return
        }

        self.modelID = model.modelID
        self.displayName = model.displayName
        self.alias = model.alias
        self.formatRawValue = model.format.rawValue
        self.quantLabel = model.quant
        self.parameterCountLabel = model.parameterCountLabel
        self.localPath = model.url.path
        self.installRootPath = InstalledModelsStore.baseDir(for: model.format, modelID: model.modelID).path
        self.sizeBytes = Int64((model.sizeGB * 1_073_741_824.0).rounded())
        self.installDate = model.downloadDate
        self.lastUsedDate = model.lastUsedDate
        self.checksum = nil
        self.isFavourite = model.isFavourite
        self.totalLayers = model.totalLayers
        self.isMultimodal = model.isMultimodal
        self.isToolCapable = model.isToolCapable
        self.isMoE = model.moeInfo?.isMoE
        self.expertCount = model.moeInfo?.expertCount
        self.defaultExperts = model.moeInfo?.defaultUsed
        self.moeLayerCount = model.moeInfo?.moeLayerCount
    }
}
