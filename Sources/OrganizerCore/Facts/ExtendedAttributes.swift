import Foundation

/// Extended attributes (xattrs): small named blobs macOS stores alongside a file.
/// Browsers record the download URL in one, Finder tags live in another.
public enum ExtendedAttributes {
    public static func data(_ name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read == size ? data : nil
        }
    }

    /// Like `data`, but nil only when the attribute isn't there; other failures throw.
    public static func dataChecked(_ name: String, at url: URL) throws -> Data? {
        try url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: url.path]) }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 {
                if errno == ENOATTR { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return data
        }
    }

    public static func set(_ data: Data, name: String, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    /// Removes an attribute. Removing one that isn't there is not an error.
    public static func remove(_ name: String, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return removexattr(path, name, XATTR_NOFOLLOW)
        }
        guard result == 0 || errno == ENOATTR else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// All attribute names on a file, e.g. ["com.apple.metadata:kMDItemWhereFroms"].
    public static func names(at url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) == size else { return [] }
            return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
    }

    /// Reads an attribute stored as a property list (the format Spotlight's `com.apple.metadata:` ones use).
    public static func propertyList(_ name: String, at url: URL) -> Any? {
        guard let data = data(name, at: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    public static func setPropertyList(_ value: Any, name: String, at url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try set(data, name: name, at: url)
    }
}

/// The download source(s) a browser recorded: usually [file URL, page URL].
public enum WhereFroms {
    public static let attribute = "com.apple.metadata:kMDItemWhereFroms"

    public static func read(_ url: URL) -> [String] {
        (ExtendedAttributes.propertyList(attribute, at: url) as? [String] ?? []).filter { !$0.isEmpty }
    }

    public static func write(_ sources: [String], to url: URL) throws {
        try ExtendedAttributes.setPropertyList(sources, name: attribute, at: url)
    }
}

/// macOS marks screenshots it takes with this attribute.
public enum ScreenCapture {
    public static let attribute = "com.apple.metadata:kMDItemIsScreenCapture"

    public static func isMarked(_ url: URL) -> Bool {
        let value = ExtendedAttributes.propertyList(attribute, at: url)
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }

    public static func mark(_ url: URL) throws {
        try ExtendedAttributes.setPropertyList(true, name: attribute, at: url)
    }
}
