import Foundation

struct ConverterTrackedInput {
    let expectedWord: String?
    let trailingText: String
    let allowUndo: Bool
}

@MainActor
struct ConverterTrackedScope {
    let bundleID: String
    let layout: Layout
    let check: Converter.ContextCheck
    let diagnostics: ConversionDiagnostics
}
