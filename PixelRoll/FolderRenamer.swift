import Foundation
import Darwin

nonisolated enum FolderRenameError: LocalizedError {
    case invalidName, collision, invalidFolder
    var errorDescription: String? {
        switch self {
        case .invalidName: "Choose a folder name without slashes, colons, control characters, or leading/trailing spaces."
        case .collision: "A file or folder already uses that name. Nothing was renamed."
        case .invalidFolder: "The folder is outside this library or is a symbolic link."
        }
    }
}

enum FolderRenamer {
    nonisolated static func rename(_ folder: URL, to name: String, library: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.rangeOfCharacter(from: .controlCharacters) == nil, !name.contains("/"), !name.contains(":"), name.utf8.count <= 255 else { throw FolderRenameError.invalidName }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              SessionPaths.relative(folder, to: library) != nil,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) == nil else { throw FolderRenameError.invalidFolder }
        let target = folder.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        if target.path == folder.path { return folder }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FolderRenameError.collision }
        try FileManager.default.moveItem(at: folder, to: target)
        return target
    }

    nonisolated static func rebase(_ url: URL, from old: URL, to new: URL) -> URL {
        // The old folder no longer exists after the move. Resolve its nearest existing
        // ancestor so /var and /private/var aliases still map to the same location.
        let base = canonicalMissingPath(old).pathComponents
        let parts = canonicalMissingPath(url).pathComponents
        guard parts.starts(with: base) else { return url }
        let relative = parts.dropFirst(base.count).joined(separator: "/")
        return canonicalMissingPath(relative.isEmpty ? new : new.appendingPathComponent(relative))
    }

    nonisolated static func canonicalMissingPath(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            tail.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var result: URL
        if let resolved = realpath(ancestor.path, nil) {
            result = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
        } else {
            result = ancestor.resolvingSymlinksInPath()
        }
        for component in tail { result.appendPathComponent(component) }
        return result
    }
}
