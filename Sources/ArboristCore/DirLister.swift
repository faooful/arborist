import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One directory entry with its allocated size, read in bulk.
public struct DirEntry: Equatable, Sendable {
    public enum Kind: Sendable { case file, dir, symlink, other }
    public var name: String
    public var kind: Kind
    /// Allocated bytes on disk (all forks); 0 for directories and links.
    public var allocated: Int64
}

/// Lists a directory with sizes in as few syscalls as possible (D11).
/// macOS: `getattrlistbulk`, which returns names, types and allocated sizes for many entries per call.
/// Linux: readdir + fstatat on the open directory (sizes as `du` reports them).
/// If those fail: FileManager with the size keys prefetched.
public enum DirLister {
    public static func list(_ path: String) -> [DirEntry]? {
        #if os(macOS)
        if let r = bulk(path) { return r }
        #elseif canImport(Glibc)
        if let r = posix(path) { return r }
        #endif
        return fileManager(path)
    }

    #if canImport(Glibc)
    /// Swift-corelibs Foundation reports allocated size as st_blocks × st_blksize (8× too big on
    /// 4 KB-block filesystems), so on Linux sizes come straight from lstat: st_blocks × 512.
    static func posix(_ path: String) -> [DirEntry]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var out: [DirEntry] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: ent.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind: DirEntry.Kind
            switch st.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .dir
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            out.append(DirEntry(name: name, kind: kind, allocated: kind == .file ? Int64(st.st_blocks) * 512 : 0))
        }
        return out
    }
    #endif

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]

    /// Portable fallback. Sizes come from the values prefetched with the listing.
    public static func fileManager(_ path: String) -> [DirEntry]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: keys, options: []) else { return nil }
        let keySet = Set(keys)
        var out: [DirEntry] = []
        out.reserveCapacity(urls.count)
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: keySet) else { continue }
            let kind: DirEntry.Kind = v.isSymbolicLink == true ? .symlink : v.isDirectory == true ? .dir : .file
            let bytes = kind == .file ? Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0) : 0
            out.append(DirEntry(name: u.lastPathComponent, kind: kind, allocated: bytes))
        }
        return out
    }

    #if os(macOS)
    // Bit values from <sys/attr.h>, spelled out so they import as UInt32.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturned: UInt32 = 0x8000_0000
    private static let fileAllocSize: UInt32 = 0x0000_0004

    /// `getattrlistbulk` listing. Returns nil if the directory can't be opened or the call fails,
    /// so the caller can fall back. Layout per entry (see `man getattrlistbulk`):
    /// u_int32 length · attribute_set_t returned · [u_int32 error] · attrreference_t name ·
    /// fsobj_type_t type · [off_t allocsize]
    static func bulk(_ path: String) -> [DirEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var req = attrlist()
        req.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        req.commonattr = cmnReturned | cmnName | cmnError | cmnObjType
        req.fileattr = fileAllocSize
        let bufSize = 128 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }
        var out: [DirEntry] = []
        while true {
            let n = getattrlistbulk(fd, &req, buf, bufSize, 0)
            if n < 0 { return out.isEmpty ? nil : out }
            if n == 0 { return out }
            var entry = buf
            for _ in 0..<Int(n) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                var failed = false
                if returned.commonattr & cmnError != 0 {
                    failed = p.loadUnaligned(as: UInt32.self) != 0
                    p += 4
                }
                var name = ""
                if returned.commonattr & cmnName != 0 {
                    let off = Int(p.loadUnaligned(as: Int32.self))
                    let len = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                    let start = (p + off).assumingMemoryBound(to: UInt8.self)
                    name = String(decoding: UnsafeBufferPointer(start: start, count: max(0, len - 1)), as: UTF8.self)
                    p += 8
                }
                var type: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 {
                    type = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                var alloc: Int64 = 0
                if returned.fileattr & fileAllocSize != 0 { alloc = p.loadUnaligned(as: Int64.self) }
                entry += length
                if failed || name.isEmpty { continue }
                let kind: DirEntry.Kind
                switch type {
                case 1: kind = .file      // VREG
                case 2: kind = .dir       // VDIR
                case 5: kind = .symlink   // VLNK
                default: kind = .other
                }
                out.append(DirEntry(name: name, kind: kind, allocated: kind == .file ? alloc : 0))
            }
        }
    }
    #endif
}

/// Shared stop signal for a running scan (timeouts, a newer rescan).
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var next = 0
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func cancel() {
        lock.lock(); value = true; let hs = Array(handlers.values); handlers = [:]; lock.unlock()
        hs.forEach { $0() }
    }
    /// D34: runs `h` on cancel (at once if already cancelled). Returns a token for `remove`.
    @discardableResult
    public func onCancel(_ h: @escaping @Sendable () -> Void) -> Int {
        lock.lock()
        if value { lock.unlock(); h(); return -1 }
        next += 1; let t = next; handlers[t] = h; lock.unlock(); return t
    }
    public func remove(_ token: Int) { lock.lock(); handlers[token] = nil; lock.unlock() }

    /// D34: the scan's flag for the current thread, so `Shell.run` can kill its child on cancel.
    public static var current: CancelFlag? {
        get { Thread.current.threadDictionary["arborist.cancel"] as? CancelFlag }
        set { Thread.current.threadDictionary["arborist.cancel"] = newValue }
    }
}
