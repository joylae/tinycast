import Foundation

enum CustomQuickActionPromptMigration {
    static func upgrading(_ data: Data) throws -> Data {
        guard var records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return data
        }
        for index in records.indices {
            guard records[index]["systemPrompt"] == nil,
                let instructions = records[index].removeValue(forKey: "instructions") as? String
            else { continue }
            let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            records[index]["systemPrompt"] =
                trimmed.isEmpty ? "" : QuickActionPrompt.boundary + "\n\n" + trimmed
        }
        return try JSONSerialization.data(withJSONObject: records)
    }
}
