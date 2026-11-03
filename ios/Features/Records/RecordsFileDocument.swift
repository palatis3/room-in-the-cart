import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import RecordArchive

extension UTType {
    static let roomRecovery = UTType(exportedAs: "com.roominthecart.personal-recovery", conformingTo: .json)
    static let roomHelper = UTType(exportedAs: "com.roominthecart.helper-shop", conformingTo: .json)
}

struct RecordsFileDocument: FileDocument {
    enum Kind: Equatable { case recovery, helper, text }
    static var readableContentTypes: [UTType] { [.roomRecovery, .roomHelper, .json, .plainText] }
    let data: Data
    let kind: Kind
    var contentType: UTType { switch kind { case .recovery: return .roomRecovery; case .helper: return .roomHelper; case .text: return .plainText } }
    init(data: Data, kind: Kind) { self.data = data; self.kind = kind }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= ArchiveCodec.maximumFileBytes else { throw ArchiveError.tooLarge }
        self.data = data
        kind = configuration.contentType == .plainText ? .text : configuration.contentType == .roomHelper ? .helper : .recovery
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct RecordsShareFile: Transferable {
    let data: Data
    let kind: RecordsFileDocument.Kind
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .roomRecovery) { $0.data }
            .exportingCondition { $0.kind == .recovery }
        DataRepresentation(exportedContentType: .roomHelper) { $0.data }
            .exportingCondition { $0.kind == .helper }
    }
}
