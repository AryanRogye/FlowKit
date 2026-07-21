//
//  GoogleDriveUpload.swift
//  FlowKit
//

import Foundation

public struct GoogleDriveFileUpload: Sendable {
    public let fileURL: URL
    public let name: String
    public let mimeType: String
    public let destination: GoogleDriveDestination
    public let description: String?

    public init(
        fileURL: URL,
        name: String,
        mimeType: String,
        destination: GoogleDriveDestination,
        description: String? = nil
    ) {
        self.fileURL = fileURL
        self.name = name
        self.mimeType = mimeType
        self.destination = destination
        self.description = description
    }
}

public struct GoogleDriveUploadProgress: Sendable, Equatable {
    public let bytesSent: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesSent) / Double(totalBytes)
    }
}

public struct GoogleDriveFile: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let mimeType: String?
    public let size: String?
    public let webViewLink: URL?
    public let parents: [String]?
}

public enum GoogleDriveUploadError: LocalizedError, Sendable, Equatable {
    case invalidFile
    case invalidName
    case invalidMIMEType
    case invalidDestination
    case invalidChunkSize
    case missingUploadLocation
    case invalidResponse
    case uploadStalled
    case requestFailed(statusCode: Int, reason: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidFile: "The upload must be a non-empty local file."
        case .invalidName: "A Google Drive file name is required."
        case .invalidMIMEType: "A MIME type is required for the Google Drive upload."
        case .invalidDestination: "A valid Google Drive upload destination is required."
        case .invalidChunkSize: "Google Drive upload chunks must be positive multiples of 256 KB."
        case .missingUploadLocation: "Google Drive did not return a resumable upload URL."
        case .invalidResponse: "Google Drive returned an invalid upload response."
        case .uploadStalled: "The Google Drive upload did not make progress."
        case let .requestFailed(statusCode, reason, message):
            message ?? reason ?? "Google Drive upload failed with HTTP status \(statusCode)."
        }
    }
}

extension GoogleDriveFlow {
    /// Uploads a local file using Drive's resumable protocol and bounded chunks.
    public func uploadFile(
        _ upload: GoogleDriveFileUpload,
        accessToken: String,
        progress: (@Sendable (GoogleDriveUploadProgress) async -> Void)? = nil
    ) async throws -> GoogleDriveFile {
        guard upload.fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: upload.fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize > 0 else { throw GoogleDriveUploadError.invalidFile }
        guard !upload.name.isEmpty else { throw GoogleDriveUploadError.invalidName }
        guard !upload.mimeType.isEmpty else { throw GoogleDriveUploadError.invalidMIMEType }
        guard upload.destination.isValid else { throw GoogleDriveUploadError.invalidDestination }
        guard uploadChunkSize > 0, uploadChunkSize.isMultiple(of: 256 * 1024) else {
            throw GoogleDriveUploadError.invalidChunkSize
        }

        let sessionURL = try await beginUpload(upload, fileSize: fileSize, accessToken: accessToken)
        let handle = try FileHandle(forReadingFrom: upload.fileURL)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var stalledAttempts = 0

        while offset < fileSize {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let count = Int(min(Int64(uploadChunkSize), fileSize - offset))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                throw GoogleDriveUploadError.invalidFile
            }
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(upload.mimeType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            request.setValue(
                "bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(fileSize)",
                forHTTPHeaderField: "Content-Range"
            )
            request.httpBody = chunk

            let result: (Data, URLResponse)
            do {
                result = try await send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch try await recoverUpload(at: sessionURL, fileSize: fileSize, accessToken: accessToken) {
                case .completed(let file): return file
                case .resume(let recovered): offset = recovered; continue
                }
            }
            guard let response = result.1 as? HTTPURLResponse else {
                throw GoogleDriveUploadError.invalidResponse
            }
            if (200...299).contains(response.statusCode) {
                await progress?(.init(bytesSent: fileSize, totalBytes: fileSize))
                return try decodeFile(result.0)
            }
            if response.statusCode == 308 {
                let next = try Self.nextOffset(from: response.value(forHTTPHeaderField: "Range"))
                guard next >= 0, next <= fileSize else { throw GoogleDriveUploadError.uploadStalled }
                if next == offset {
                    stalledAttempts += 1
                    guard stalledAttempts <= 5 else { throw GoogleDriveUploadError.uploadStalled }
                    try await sleep(.seconds(1 << (stalledAttempts - 1)))
                    continue
                }
                stalledAttempts = 0
                offset = next
                await progress?(.init(bytesSent: offset, totalBytes: fileSize))
                continue
            }
            if (500...599).contains(response.statusCode) {
                switch try await recoverUpload(
                    at: sessionURL,
                    fileSize: fileSize,
                    accessToken: accessToken,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                ) {
                case .completed(let file): return file
                case .resume(let recovered): offset = recovered; continue
                }
            }
            throw Self.apiError(data: result.0, statusCode: response.statusCode)
        }
        throw GoogleDriveUploadError.invalidResponse
    }

    private struct UploadMetadata: Encodable {
        let name: String
        let mimeType: String
        let parents: [String]?
        let description: String?
    }

    private func beginUpload(
        _ upload: GoogleDriveFileUpload,
        fileSize: Int64,
        accessToken: String
    ) async throws -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")
        components?.queryItems = [
            .init(name: "uploadType", value: "resumable"),
            .init(name: "fields", value: "id,name,mimeType,size,webViewLink,parents"),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue(upload.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.httpBody = try JSONEncoder().encode(UploadMetadata(
            name: upload.name,
            mimeType: upload.mimeType,
            parents: [upload.destination.folderID],
            description: upload.description
        ))
        let (data, rawResponse) = try await send(request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw GoogleDriveUploadError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw Self.apiError(data: data, statusCode: response.statusCode)
        }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location) else { throw GoogleDriveUploadError.missingUploadLocation }
        return url
    }

    private enum Recovery { case resume(Int64), completed(GoogleDriveFile) }

    private func recoverUpload(
        at url: URL,
        fileSize: Int64,
        accessToken: String,
        retryAfter: String? = nil
    ) async throws -> Recovery {
        var delay = Int(retryAfter ?? "") ?? 1
        var lastError: (any Error)?
        for attempt in 0..<5 {
            try Task.checkCancellation()
            try await sleep(.seconds(delay))
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.setValue("bytes */\(fileSize)", forHTTPHeaderField: "Content-Range")
            do {
                let (data, rawResponse) = try await send(request)
                guard let response = rawResponse as? HTTPURLResponse else {
                    throw GoogleDriveUploadError.invalidResponse
                }
                if response.statusCode == 308 {
                    return .resume(try Self.nextOffset(from: response.value(forHTTPHeaderField: "Range")))
                }
                if (200...299).contains(response.statusCode) { return .completed(try decodeFile(data)) }
                if !(500...599).contains(response.statusCode) {
                    throw Self.apiError(data: data, statusCode: response.statusCode)
                }
                lastError = Self.apiError(data: data, statusCode: response.statusCode)
                delay = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? min(delay * 2, 16)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GoogleDriveUploadError {
                throw error
            } catch {
                lastError = error
                delay = min(delay * 2, 16)
            }
            if attempt == 4, let lastError { throw lastError }
        }
        throw GoogleDriveUploadError.uploadStalled
    }

    private func decodeFile(_ data: Data) throws -> GoogleDriveFile {
        do { return try JSONDecoder().decode(GoogleDriveFile.self, from: data) }
        catch { throw GoogleDriveUploadError.invalidResponse }
    }

    private static func nextOffset(from range: String?) throws -> Int64 {
        guard let range else { return 0 }
        guard let last = range.split(separator: "-").last, let byte = Int64(last) else {
            throw GoogleDriveUploadError.invalidResponse
        }
        return byte + 1
    }

    private struct ErrorEnvelope: Decodable {
        let error: Body
        struct Body: Decodable { let code: Int?; let message: String?; let errors: [Detail]? }
        struct Detail: Decodable { let reason: String? }
    }

    private static func apiError(data: Data, statusCode: Int) -> GoogleDriveUploadError {
        let error = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        return .requestFailed(
            statusCode: statusCode,
            reason: error?.error.errors?.first?.reason,
            message: error?.error.message
        )
    }
}
