import Foundation

/// One entry of a Space Lens tree.
public struct SpaceNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case directory
        /// A package (`.app`, Photos library, …) or `.git`: sized as a whole, never entered.
        case package
        case file
        /// A directory's files below the node threshold, summed into one row.
        case otherFiles(count: Int)
    }

    public var name: String
    /// Index of the parent; -1 for the root.
    public var parent: Int32
    public var kind: Kind
    /// Allocated bytes, including everything below.
    public var size: Int64
    public var children: [Int32]
    /// Something below could not be read, so `size` is partial.
    public var inaccessible: Bool

    public init(
        name: String, parent: Int32, kind: Kind, size: Int64, children: [Int32] = [], inaccessible: Bool = false
    ) {
        self.name = name
        self.parent = parent
        self.kind = kind
        self.size = size
        self.children = children
        self.inaccessible = inaccessible
    }

    public var isEnterable: Bool { kind == .directory }
}

/// Folder sizes of a whole walk, kept in one array (indices instead of references keep it compact
/// and `Sendable`). Node 0 is the root.
public struct SpaceTree: Sendable, Equatable {
    public private(set) var nodes: [SpaceNode]
    /// Canonical path of the root.
    public let root: URL

    public init(root: URL, nodes: [SpaceNode]) {
        self.root = root
        self.nodes = nodes
    }

    public subscript(index: Int32) -> SpaceNode { nodes[Int(index)] }

    /// Children of `index`, largest first (ties by name); `otherFiles` always last.
    public func children(of index: Int32) -> [Int32] {
        nodes[Int(index)].children.sorted { a, b in
            let l = nodes[Int(a)]
            let r = nodes[Int(b)]
            let lo = Self.isOther(l)
            let ro = Self.isOther(r)
            if lo != ro { return ro }
            if l.size != r.size { return l.size > r.size }
            return l.name.localizedStandardCompare(r.name) == .orderedAscending
        }
    }

    private static func isOther(_ node: SpaceNode) -> Bool {
        if case .otherFiles = node.kind { return true }
        return false
    }

    /// Indices from the root down to `index`.
    public func ancestry(of index: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = index
        while current >= 0 {
            chain.append(current)
            current = nodes[Int(current)].parent
        }
        return chain.reversed()
    }

    /// The file URL of a node (`otherFiles` resolves to its directory).
    public func url(of index: Int32) -> URL {
        var url = root
        for i in ancestry(of: index).dropFirst() {
            let node = nodes[Int(i)]
            if case .otherFiles = node.kind { break }
            url.appendPathComponent(node.name, isDirectory: node.kind != .file)
        }
        return url
    }

    /// True when `ancestor` is `index` or above it.
    public func isAncestor(_ ancestor: Int32, of index: Int32) -> Bool {
        var current = index
        while current >= 0 {
            if current == ancestor { return true }
            current = nodes[Int(current)].parent
        }
        return false
    }

    /// Detaches a removed node and takes its size off every ancestor.
    public mutating func remove(_ index: Int32) {
        guard index > 0, Int(index) < nodes.count else { return }
        let size = nodes[Int(index)].size
        let parent = nodes[Int(index)].parent
        guard parent >= 0 else { return }
        nodes[Int(parent)].children.removeAll { $0 == index }
        var current = parent
        while current >= 0 {
            nodes[Int(current)].size = max(0, nodes[Int(current)].size - size)
            current = nodes[Int(current)].parent
        }
    }
}
