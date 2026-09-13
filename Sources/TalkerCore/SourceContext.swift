import Foundation

// Origin metadata only: Orb never executes or navigates to these identifiers.
public struct SourceContext: Decodable, Equatable {
    public let kind: String
    public let workspaceID: String
    public let tabID: String
    public let paneID: String
    enum CodingKeys: String, CodingKey {
        case kind, workspaceID = "workspace_id", tabID = "tab_id", paneID = "pane_id"
    }

    func validated() throws -> SourceContext {
        let workspace = try Self.identifier(workspaceID, limit: 32)
        let tab = try Self.identifier(tabID, limit: 64), pane = try Self.identifier(paneID, limit: 64)
        guard kind == "herdr", tab.hasPrefix(workspace + ":t"), pane.hasPrefix(workspace + ":p"),
              tab.count > workspace.count + 2, pane.count > workspace.count + 2 else {
            throw APIError(422, "Source context must identify a Herdr workspace, tab and pane")
        }
        return SourceContext(kind: kind, workspaceID: workspace, tabID: tab, paneID: pane)
    }

    private static func identifier(_ raw: String, limit: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...limit).contains(value.count), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 58, 95].contains($0)
        }) else { throw APIError(422, "Invalid source identifier") }
        return value
    }
}
