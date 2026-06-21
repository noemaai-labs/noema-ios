import Foundation

struct ModelDependencyGraph: Equatable {
    struct Node: Identifiable, Equatable {
        enum Role: Equatable {
            case root
            case required
            case optional
            case installCheck
        }

        let id: String
        let entryKind: ModelDownloadPlan.Entry.Kind?
        let title: String
        let detail: String
        let role: Role
    }

    struct Edge: Equatable {
        let sourceID: String
        let targetID: String
    }

    let nodes: [Node]
    let edges: [Edge]

    var root: Node {
        nodes[0]
    }

    var dependencies: [Node] {
        Array(nodes.dropFirst())
    }

    var requiredDependencies: [Node] {
        dependencies.filter { $0.role == .required }
    }

    var optionalDependencies: [Node] {
        dependencies.filter { $0.role == .optional }
    }

    var installChecks: [Node] {
        dependencies.filter { $0.role == .installCheck }
    }

    static func make(rootTitle: String, plan: ModelDownloadPlan) -> ModelDependencyGraph {
        let root = Node(
            id: "root",
            entryKind: nil,
            title: rootTitle,
            detail: "model quant",
            role: .root
        )
        let dependencies = plan.entries.enumerated().map { index, entry in
            Node(
                id: "dependency-\(index)-\(entry.id)",
                entryKind: entry.kind,
                title: entry.relativePath,
                detail: detail(for: entry),
                role: role(for: entry)
            )
        }
        return ModelDependencyGraph(
            nodes: [root] + dependencies,
            edges: dependencies.map { Edge(sourceID: root.id, targetID: $0.id) }
        )
    }

    private static func role(for entry: ModelDownloadPlan.Entry) -> Node.Role {
        if entry.isResolvedDuringInstall { return .installCheck }
        return entry.isRequired ? .required : .optional
    }

    private static func detail(for entry: ModelDownloadPlan.Entry) -> String {
        if entry.isResolvedDuringInstall {
            return entry.isRequired ? "required install check" : "optional install check"
        }
        return entry.isRequired ? "required file" : "optional file"
    }
}
