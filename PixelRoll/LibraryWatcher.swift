import Foundation
import CoreServices
import UniformTypeIdentifiers

// FSEvents watches the chosen tree without opening each photo or polling the entire library.
nonisolated final class LibraryWatcher {
    private let root: URL
    private let scoped: Bool
    private var stream: FSEventStreamRef?

    private final class Callback {
        let action: @Sendable ([LibraryChange]) -> Void
        init(_ action: @escaping @Sendable ([LibraryChange]) -> Void) { self.action = action }
    }

    init?(root: URL, changed: @escaping @Sendable ([LibraryChange]) -> Void) {
        self.root = root
        scoped = root.startAccessingSecurityScopedResource()
        let callback = Callback(changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let changes = (0..<Int(count)).compactMap { index -> LibraryChange? in
                guard index < paths.count else { return .rescan }
                return LibraryWatcher.change(path: paths[index], flags: flags[index])
            }
            guard !changes.isEmpty else { return }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().action(changes)
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { return nil }
    }

    static func change(path: String, flags: FSEventStreamEventFlags) -> LibraryChange? {
        guard affectsLibrary(path: path, flags: flags) else { return nil }
        let recovery = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                              kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged |
                              kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        if flags == 0 || flags & recovery != 0 { return .rescan }
        let url = URL(fileURLWithPath: path)
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
            let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            return flags & structural == 0 ? nil : .subtree(url)
        }
        return .file(url)
    }

    static func affectsLibrary(path: String, flags: FSEventStreamEventFlags) -> Bool {
        let recovery = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                              kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged |
                              kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        if flags & recovery != 0 { return true }
        let url = URL(fileURLWithPath: path)
        guard !url.pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "/" }) else { return false }
        let content = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                             kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
        // Attribute-only notifications (including background indexing) do not change pixels or notes.
        guard flags == 0 || flags & content != 0 else { return false }
        if flags == 0 || flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "pixelroll" || ["nef", "nrw", "dng", "arw", "cr2", "cr3", "raf", "orf", "rw2", "pef", "srw"].contains(ext) ||
            UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if scoped { root.stopAccessingSecurityScopedResource() }
    }
}
