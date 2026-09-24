import Foundation

/// Filesystem-only selection logic. Call off the main actor: resolving paths and
/// enumerating a large (or remote) folder can block even before decoding begins.
struct ImportSelection: Sendable {
    static let supportedExtensions: Set<String> = ["flac", "wav", "mp3", "m4a", "aac", "mp4"]

    var files: [URL] = []
    var result = ImportResult()

    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func enumerate(
        _ urls: [URL],
        existingPaths: [String] = [],
        isCancelled: @escaping () -> Bool = { false }
    ) -> ImportSelection {
        var selection = ImportSelection()
        var knownPaths = Set<String>()
        for path in existingPaths {
            if isCancelled() {
                selection.result.wasCancelled = true
                return selection
            }
            knownPaths.insert(canonicalURL(URL(fileURLWithPath: path)).path)
        }

        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]

        func addFile(_ url: URL, values: URLResourceValues) {
            guard values.isRegularFile == true,
                  supportedExtensions.contains(url.pathExtension.lowercased()) else {
                selection.result.unsupportedCount += 1
                return
            }
            guard knownPaths.insert(url.path).inserted else {
                selection.result.duplicateCount += 1
                return
            }
            selection.files.append(url)
        }

        for input in urls {
            if isCancelled() {
                selection.result.wasCancelled = true
                break
            }
            guard input.isFileURL else {
                selection.result.recordFailure(file: input, reason: "Only local files and folders can be imported.")
                continue
            }
            let root = canonicalURL(input)
            do {
                let values = try root.resourceValues(forKeys: keys)
                guard values.isDirectory == true else {
                    addFile(root, values: values)
                    continue
                }
                guard let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, error in
                        selection.result.recordFailure(file: url, reason: error.localizedDescription)
                        return !isCancelled()
                    }
                ) else {
                    selection.result.recordFailure(file: root, reason: "The folder could not be read.")
                    continue
                }

                while !isCancelled(), let child = enumerator.nextObject() as? URL {
                    do {
                        let file = canonicalURL(child)
                        let childValues = try file.resourceValues(forKeys: keys)
                        // Directory symlinks are not traversed by the enumerator;
                        // resolving file symlinks still deduplicates their targets.
                        if childValues.isDirectory != true {
                            addFile(file, values: childValues)
                        }
                    } catch {
                        selection.result.recordFailure(file: child, reason: error.localizedDescription)
                    }
                }
                if isCancelled() {
                    selection.result.wasCancelled = true
                    break
                }
            } catch {
                selection.result.recordFailure(file: root, reason: error.localizedDescription)
            }
        }
        return selection
    }
}

/// Counts only successful database writes as imports; cancellation leaves those
/// writes intact and reports the files that were discovered but not processed.
struct ImportResult: Sendable {
    var importedCount = 0
    var duplicateCount = 0
    var unsupportedCount = 0
    var failedCount = 0
    var notProcessedCount = 0
    var wasCancelled = false
    var firstFailure: String?

    var skippedCount: Int { duplicateCount + unsupportedCount }

    mutating func recordFailure(file: URL, reason: String) {
        failedCount += 1
        if firstFailure == nil {
            firstFailure = "\(file.lastPathComponent): \(reason)"
        }
    }

    var summary: String {
        let heading = wasCancelled ? "Import cancelled" : "Import complete"
        var text = "\(heading): \(importedCount) imported, \(skippedCount) skipped, \(failedCount) failed."
        if skippedCount > 0 {
            text += " Skipped: \(duplicateCount) duplicate, \(unsupportedCount) unsupported."
        }
        if wasCancelled {
            text += " \(notProcessedCount) discovered files not processed; scanning may be incomplete."
        }
        if let firstFailure {
            text += " First failure: \(firstFailure)"
        }
        return text
    }
}
