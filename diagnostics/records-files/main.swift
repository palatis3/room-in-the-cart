import Foundation

// Fictional fixture key, for the two local simulator files only.
let key = Data(repeating: 42, count: 32).base64EncodedString()
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let date = Date(timeIntervalSince1970: 1_700_000_000)
let recipe = ImportedRecipe(title: "Earlier saffron rice", yieldText: "Makes four bowls",
                            ingredients: ["2 cups short-grain rice"], steps: ["Steam for twenty minutes."],
                            sourceURL: "https://cook.invalid/rice", notes: "Set one bowl aside.")
let record = try recipe.archiveRecord(origin: "n06-local-kitchen", savedAt: date)
let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery,
                                     origin: "n06-local-kitchen", revision: "reviewed-rice-v1",
                                     exportedAt: date)
let sealed = try EncryptedArchive.seal(envelope, key: key)
try sealed.write(to: destination.appendingPathComponent("N06-valid.roomrecovery"))
// Drop the quoted algorithm value, preserving balanced delimiters. The result
// is invalid JSON and still resembles the original authenticated container.
let corrupt = String(decoding: sealed, as: UTF8.self)
    .replacingOccurrences(of: #""AES-256-GCM""#, with: "")
precondition(Data(corrupt.utf8) != sealed)
try Data(corrupt.utf8).write(to: destination.appendingPathComponent("N06-damaged.roomrecovery"))
