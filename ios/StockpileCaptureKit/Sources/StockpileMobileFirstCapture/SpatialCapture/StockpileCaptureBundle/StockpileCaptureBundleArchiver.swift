import Foundation
import ZIPFoundation

/// Errors emitted by `StockpileCaptureBundleArchiver` while assembling and zipping
/// a `.stockpilecapture` bundle.
public enum StockpileCaptureBundleArchiverError: Error, LocalizedError, Equatable, Sendable {
    case stagingDirectoryMissing(URL)
    case stagingDirectoryNotADirectory(URL)
    case manifestEncodingFailed(String)
    case posesEncodingFailed(String)
    case anchorsEncodingFailed(String)
    case archiveCreationFailed(String)
    case archiveWriteFailed(String)
    case archiveReplaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .stagingDirectoryMissing(url):
            return "Capture bundle staging directory does not exist at \(url.path)."
        case let .stagingDirectoryNotADirectory(url):
            return "Capture bundle staging path \(url.path) is not a directory."
        case let .manifestEncodingFailed(detail):
            return "Failed to encode manifest.json: \(detail)"
        case let .posesEncodingFailed(detail):
            return "Failed to encode poses.json: \(detail)"
        case let .anchorsEncodingFailed(detail):
            return "Failed to encode anchors.json: \(detail)"
        case let .archiveCreationFailed(detail):
            return "Failed to create capture bundle archive: \(detail)"
        case let .archiveWriteFailed(detail):
            return "Failed to write capture bundle archive contents: \(detail)"
        case let .archiveReplaceFailed(detail):
            return "Failed to replace existing capture bundle archive: \(detail)"
        }
    }
}

/// Assembles a `.stockpilecapture` bundle directory into a standard PKZIP (DEFLATE)
/// archive that the backend can unpack with Python's stdlib `zipfile` module.
///
/// The staging directory is expected to already contain the per-frame `rgb/`,
/// `depth/`, and `confidence/` subfolders populated by the capture session. The
/// archiver writes the JSON sidecars (`manifest.json`, `poses.json`,
/// `anchors.json`) into the staging directory before zipping the entire tree.
public struct StockpileCaptureBundleArchiver: @unchecked Sendable {
    private let fileManager: FileManager
    private let jsonEncoder: StockpileCaptureBundleJSONEncoder

    public init(
        fileManager: FileManager = .default,
        jsonEncoder: StockpileCaptureBundleJSONEncoder = StockpileCaptureBundleJSONEncoder()
    ) {
        self.fileManager = fileManager
        self.jsonEncoder = jsonEncoder
    }

    /// Writes the manifest/poses/anchors JSON files into `stagingDirectory` and
    /// then ZIPs the entire staging directory tree to `outputURL`.
    /// - Returns: The resulting archive URL on success.
    @discardableResult
    public func archive(
        stagingDirectory: URL,
        manifest: StockpileCaptureBundleManifest,
        poses: StockpileCaptureBundlePoseDocument,
        anchors: StockpileCaptureBundleAnchorDocument,
        outputURL: URL
    ) throws -> URL {
        try validateStagingDirectory(stagingDirectory)
        try writeJSONSidecars(into: stagingDirectory, manifest: manifest, poses: poses, anchors: anchors)
        try zipStagingDirectory(stagingDirectory, to: outputURL)
        return outputURL
    }

    private func validateStagingDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw StockpileCaptureBundleArchiverError.stagingDirectoryMissing(url)
        }
        guard isDirectory.boolValue else {
            throw StockpileCaptureBundleArchiverError.stagingDirectoryNotADirectory(url)
        }
    }

    private func writeJSONSidecars(
        into stagingDirectory: URL,
        manifest: StockpileCaptureBundleManifest,
        poses: StockpileCaptureBundlePoseDocument,
        anchors: StockpileCaptureBundleAnchorDocument
    ) throws {
        do {
            let manifestData = try jsonEncoder.encode(manifest)
            try manifestData.write(
                to: stagingDirectory.appendingPathComponent(StockpileCaptureBundleContract.manifestFileName),
                options: .atomic
            )
        } catch {
            throw StockpileCaptureBundleArchiverError.manifestEncodingFailed(error.localizedDescription)
        }

        do {
            let posesData = try jsonEncoder.encode(poses)
            try posesData.write(
                to: stagingDirectory.appendingPathComponent(StockpileCaptureBundleContract.posesFileName),
                options: .atomic
            )
        } catch {
            throw StockpileCaptureBundleArchiverError.posesEncodingFailed(error.localizedDescription)
        }

        do {
            let anchorsData = try jsonEncoder.encode(anchors)
            try anchorsData.write(
                to: stagingDirectory.appendingPathComponent(StockpileCaptureBundleContract.anchorsFileName),
                options: .atomic
            )
        } catch {
            throw StockpileCaptureBundleArchiverError.anchorsEncodingFailed(error.localizedDescription)
        }
    }

    private func zipStagingDirectory(_ stagingDirectory: URL, to outputURL: URL) throws {
        // Ensure the output directory exists before writing.
        let outputDirectory = outputURL.deletingLastPathComponent()
        if outputDirectory.path.isEmpty == false {
            try? fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        }

        // Always replace any pre-existing archive to keep the bundle byte-stable
        // across reruns of the same capture.
        if fileManager.fileExists(atPath: outputURL.path) {
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                throw StockpileCaptureBundleArchiverError.archiveReplaceFailed(error.localizedDescription)
            }
        }

        // Most bundle bytes are already JPEG or raw binary depth. Deflating them
        // on an iPhone can keep the operator stuck on "Sealing" for minutes, so
        // store entries without compression and let upload/network handle the
        // tradeoff. Python's stdlib `zipfile` reads this standard ZIP normally.
        do {
            try fileManager.zipItem(
                at: stagingDirectory,
                to: outputURL,
                shouldKeepParent: false,
                compressionMethod: .none
            )
        } catch {
            throw StockpileCaptureBundleArchiverError.archiveCreationFailed(error.localizedDescription)
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw StockpileCaptureBundleArchiverError.archiveWriteFailed(
                "Archive at \(outputURL.path) was not produced."
            )
        }
    }
}
