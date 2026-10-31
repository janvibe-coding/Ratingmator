import Foundation

/// The ExifTool bundled in the app, run with macOS's Perl and kept running between commands.
nonisolated final class ExifTool {
    enum ToolError: Error, Equatable {
        case notBundled
        case stopped
    }

    let argFiles: URL

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init() throws {
        guard let folder = Bundle.main.url(forResource: "ExifTool", withExtension: "bundle") else {
            throw ToolError.notBundled
        }
        argFiles = folder.appendingPathComponent("arg_files")

        signal(SIGPIPE, SIG_IGN)  // a stopped ExifTool should show as an error, not end the app
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [folder.appendingPathComponent("exiftool").path, "-stay_open", "True", "-@", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    /// Runs one command and returns what it printed. Every path is written as UTF-8 bytes, so the
    /// on-disk spelling of accented names is kept.
    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let lines = (["-charset", "filename=utf8"] + arguments + ["-execute"]).joined(separator: "\n") + "\n"
        try input.fileHandleForWriting.write(contentsOf: Data(lines.utf8))

        var printed = Data()
        let ready = Data("{ready}\n".utf8)
        while !printed.suffix(ready.count).elementsEqual(ready) {
            let more = output.fileHandleForReading.availableData
            guard !more.isEmpty else { throw ToolError.stopped }
            printed += more
        }
        return String(decoding: printed.dropLast(ready.count), as: UTF8.self)
    }

    func close() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
        process.waitUntilExit()
    }
}
