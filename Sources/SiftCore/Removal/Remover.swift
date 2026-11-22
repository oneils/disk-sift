import Foundation

/// Removes findings, re-validating every one right before acting: canonical path inside the removal
/// roots, and removability recomputed from the filesystem (the `requiresRoot` flag is not trusted).
public struct Remover: Sendable {
    private let roots: RemovalRoots
    private let trasher: any Trasher

    public init(roots: RemovalRoots, trasher: any Trasher = FileManagerTrasher()) {
        self.roots = roots
        self.trasher = trasher
    }

    public func remove(_ findings: [Finding], policy: RemovalPolicy) -> RemovalReport {
        var report = RemovalReport()
        for finding in findings {
            switch removeOne(finding.url, policy: policy) {
            case nil: report.removed.append(RemovedItem(url: finding.url, size: finding.size))
            case let reason?: report.skipped.append(SkippedItem(url: finding.url, reason: reason))
            }
        }
        return report
    }

    /// `nil` on success, otherwise why the item was skipped.
    private func removeOne(_ url: URL, policy: RemovalPolicy) -> SkipReason? {
        let canonical: CanonicalPath
        do {
            canonical = try CanonicalPath.of(url)
        } catch {
            return Self.reason(for: error, fallback: .vanished)
        }
        guard roots.allows(canonical) else {
            Log.removal.error("refusing path outside removal roots: \(canonical.path, privacy: .public)")
            return .outsideRoots
        }
        // The window between this lstat and the removal is accepted: DiskSift is a single-user tool and
        // an attacker who can swap path components under the user's own Library already owns the account.
        let target = canonical.url
        var st = stat()
        guard lstat(target.path, &st) == 0 else { return .vanished }
        guard Writability.canRemove(target, policy: policy) else { return .needsAdmin }

        do {
            try perform(target, policy: policy)
            return nil
        } catch {
            let reason = Self.reason(for: error, fallback: .permissionDenied)
            guard policy == .delete, reason == .permissionDenied else {
                Log.removal.error("remove failed: \(target.path, privacy: .public)")
                return reason
            }
            // read-only tree (Go module cache): make it writable without following symlinks, retry once
            Self.makeWritable(target.path)
            do {
                try perform(target, policy: policy)
                return nil
            } catch {
                Log.removal.error("remove failed after chmod: \(target.path, privacy: .public)")
                return Self.reason(for: error, fallback: .permissionDenied)
            }
        }
    }

    private func perform(_ url: URL, policy: RemovalPolicy) throws {
        switch policy {
        case .trash: try trasher.trash(url)
        case .delete: try FileManager.default.removeItem(at: url)
        }
    }

    static func reason(for error: any Error, fallback: SkipReason) -> SkipReason {
        let ns = error as NSError
        var code: Int32?
        if ns.domain == NSPOSIXErrorDomain {
            code = Int32(ns.code)
        } else if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain {
            code = Int32(under.code)
        } else if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: code = ENOENT
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: code = EACCES
            default: break
            }
        }
        switch code {
        case ENOENT?: return .vanished
        case EBUSY?: return .inUse
        case EACCES?, EPERM?: return .permissionDenied
        default: return fallback
        }
    }

    /// Adds `u+w` (and `u+rx` on directories, needed to traverse them) to everything below `path`.
    /// Symlinks are skipped and never followed, so a link to a file outside the tree keeps the file's mode.
    static func makeWritable(_ path: String) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_SL, FTS_SLNONE, FTS_DP, FTS_NS, FTS_ERR:
                continue
            default:
                guard let st = entry.pointee.fts_statp?.pointee, let entryPath = entry.pointee.fts_path else {
                    continue
                }
                var mode = st.st_mode & 0o7777 | mode_t(S_IWUSR)
                if (st.st_mode & S_IFMT) == S_IFDIR { mode |= mode_t(S_IRUSR | S_IXUSR) }
                fchmodat(AT_FDCWD, entryPath, mode, AT_SYMLINK_NOFOLLOW)
            }
        }
    }
}
