//
//  YouTubeUpload.swift
//  FlowKit
//

import Foundation

public enum YouTubeVideoPrivacy: String, Codable, Sendable {
    case `private`
    case unlisted
    case `public`
}

public struct YouTubeVideoUpload: Sendable {
    public let fileURL: URL
    public let mimeType: String
    public let title: String
    public let description: String
    public let tags: [String]
    public let categoryID: String
    public let privacy: YouTubeVideoPrivacy
    public let madeForKids: Bool
    public let containsSyntheticMedia: Bool?
    public let notifySubscribers: Bool

    public init(
        fileURL: URL,
        mimeType: String,
        title: String,
        description: String,
        tags: [String] = [],
        categoryID: String,
        privacy: YouTubeVideoPrivacy,
        madeForKids: Bool,
        containsSyntheticMedia: Bool? = nil,
        notifySubscribers: Bool = true
    ) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.title = title
        self.description = description
        self.tags = tags
        self.categoryID = categoryID
        self.privacy = privacy
        self.madeForKids = madeForKids
        self.containsSyntheticMedia = containsSyntheticMedia
        self.notifySubscribers = notifySubscribers
    }
}

public struct YouTubeUploadProgress: Sendable, Equatable {
    public let bytesSent: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesSent) / Double(totalBytes)
    }
}

public struct YouTubeVideo: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let snippet: Snippet?
    public let status: Status?

    public struct Snippet: Decodable, Sendable, Equatable {
        public let title: String
        public let description: String
        public let channelID: String?

        enum CodingKeys: String, CodingKey {
            case title
            case description
            case channelID = "channelId"
        }
    }

    public struct Status: Decodable, Sendable, Equatable {
        public let uploadStatus: String?
        public let privacyStatus: YouTubeVideoPrivacy?
    }
}

public enum YouTubeUploadError: LocalizedError, Sendable, Equatable {
    case invalidFile
    case invalidMIMEType
    case invalidChunkSize
    case missingUploadLocation
    case invalidResponse
    case uploadStalled
    case requestFailed(statusCode: Int, reason: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidFile:
            "The video must be a non-empty local file."
        case .invalidMIMEType:
            "YouTube uploads require a video MIME type or application/octet-stream."
        case .invalidChunkSize:
            "YouTube upload chunks must be positive multiples of 256 KB."
        case .missingUploadLocation:
            "YouTube did not return a resumable upload URL."
        case .invalidResponse:
            "YouTube returned an invalid upload response."
        case .uploadStalled:
            "The YouTube upload did not make progress."
        case let .requestFailed(statusCode, reason, message):
            message ?? reason ?? "YouTube upload failed with HTTP status \(statusCode)."
        }
    }
}

// MARK: - Resumable Video Upload
/// ```text
/// ┌──────────────────────────────┐
/// │ 1. Start resumable session   │
/// │                              │
/// │ POST /upload/youtube/v3/...  │
/// │ Send:                        │
/// │ - video metadata             │
/// │ - file size + MIME type      │
/// │ - Bearer access token        │
/// └───────────────┬──────────────┘
///                 │ Location header
///                 ▼
/// ┌──────────────────────────────┐
/// │ 2. Upload bounded chunks     │◄──────────────┐
/// │                              │               │
/// │ PUT resumable session URL    │               │
/// │ Send Content-Range + bytes   │               │
/// └───────────────┬──────────────┘               │
///                 │                              │
///         ┌───────┼──────────────┐               │
///         ▼       ▼              ▼               │
///       2xx      308         network/5xx          │
///     complete  advance      query status         │
///         │       │              │               │
///         ▼       └──────────────┴───────────────┘
///   Return video
/// ```
extension YouTubeFlow {
    /// Uploads a local video file to the channel associated with the Google
    /// account that authorized `accessToken`.
    ///
    /// The file is read in bounded chunks rather than loaded wholly into
    /// memory. Progress callbacks may safely cross actor boundaries.
    public func uploadVideo(
        _ upload: YouTubeVideoUpload,
        accessToken: String,
        progress: (@Sendable (YouTubeUploadProgress) async -> Void)? = nil
    ) async throws -> YouTubeVideo {
        guard upload.fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: upload.fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize > 0 else {
            throw YouTubeUploadError.invalidFile
        }
        guard upload.mimeType == "application/octet-stream" || upload.mimeType.hasPrefix("video/") else {
            throw YouTubeUploadError.invalidMIMEType
        }
        guard uploadChunkSize > 0, uploadChunkSize.isMultiple(of: 256 * 1024) else {
            throw YouTubeUploadError.invalidChunkSize
        }

        // Metadata and media bytes are separate requests in Google's resumable
        // protocol. The returned URL identifies this temporary upload session.
        let sessionURL = try await beginResumableUpload(
            upload,
            fileSize: fileSize,
            accessToken: accessToken
        )
        let handle = try FileHandle(forReadingFrom: upload.fileURL)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var stalledAttempts = 0
        while offset < fileSize {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let requestedCount = Int(min(Int64(uploadChunkSize), fileSize - offset))
            guard let chunk = try handle.read(upToCount: requestedCount), !chunk.isEmpty else {
                throw YouTubeUploadError.invalidFile
            }

            let lastByte = offset + Int64(chunk.count) - 1
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(upload.mimeType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            request.setValue("bytes \(offset)-\(lastByte)/\(fileSize)", forHTTPHeaderField: "Content-Range")
            request.httpBody = chunk

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch try await recoverUpload(
                    at: sessionURL,
                    fileSize: fileSize,
                    accessToken: accessToken
                ) {
                case .completed(let video):
                    await progress?(YouTubeUploadProgress(bytesSent: fileSize, totalBytes: fileSize))
                    return video
                case .resume(let recoveredOffset):
                    offset = recoveredOffset
                    continue
                }
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw YouTubeUploadError.invalidResponse
            }

            if (200...299).contains(httpResponse.statusCode) {
                await progress?(YouTubeUploadProgress(bytesSent: fileSize, totalBytes: fileSize))
                return try JSONDecoder().decode(YouTubeVideo.self, from: data)
            }

            // HTTP 308 means the session is still active. The Range response
            // header is the server's source of truth for the next byte.
            if httpResponse.statusCode == 308 {
                let nextOffset = try Self.nextUploadOffset(
                    from: httpResponse.value(forHTTPHeaderField: "Range"),
                    fallback: 0
                )
                guard nextOffset >= 0, nextOffset <= fileSize else {
                    throw YouTubeUploadError.uploadStalled
                }
                if nextOffset == offset {
                    stalledAttempts += 1
                    guard stalledAttempts <= 5 else {
                        throw YouTubeUploadError.uploadStalled
                    }
                    try await sleep(.seconds(1 << (stalledAttempts - 1)))
                    continue
                }
                stalledAttempts = 0
                offset = nextOffset
                await progress?(YouTubeUploadProgress(bytesSent: offset, totalBytes: fileSize))
                continue
            }

            // For retryable server errors, probe the session before resending.
            // This prevents duplicated or skipped bytes after an uncertain PUT.
            if (500...599).contains(httpResponse.statusCode) {
                switch try await recoverUpload(
                    at: sessionURL,
                    fileSize: fileSize,
                    accessToken: accessToken,
                    initialRetryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
                ) {
                case .completed(let video):
                    await progress?(YouTubeUploadProgress(bytesSent: fileSize, totalBytes: fileSize))
                    return video
                case .resume(let recoveredOffset):
                    offset = recoveredOffset
                    continue
                }
            }

            throw Self.uploadError(data: data, statusCode: httpResponse.statusCode)
        }

        throw YouTubeUploadError.invalidResponse
    }

    private struct UploadMetadata: Encodable {
        let snippet: Snippet
        let status: Status

        struct Snippet: Encodable {
            let title: String
            let description: String
            let tags: [String]?
            let categoryId: String
        }

        struct Status: Encodable {
            let privacyStatus: YouTubeVideoPrivacy
            let selfDeclaredMadeForKids: Bool
            let containsSyntheticMedia: Bool?
        }
    }

    /// Sends user-selected metadata and obtains the upload session URL from
    /// YouTube's `Location` response header.
    private func beginResumableUpload(
        _ upload: YouTubeVideoUpload,
        fileSize: Int64,
        accessToken: String
    ) async throws -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/upload/youtube/v3/videos")
        components?.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "part", value: "snippet,status"),
            URLQueryItem(name: "notifySubscribers", value: String(upload.notifySubscribers)),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        let metadata = UploadMetadata(
            snippet: .init(
                title: upload.title,
                description: upload.description,
                tags: upload.tags.isEmpty ? nil : upload.tags,
                categoryId: upload.categoryID
            ),
            status: .init(
                privacyStatus: upload.privacy,
                selfDeclaredMadeForKids: upload.madeForKids,
                containsSyntheticMedia: upload.containsSyntheticMedia
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue(upload.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.httpBody = try JSONEncoder().encode(metadata)

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeUploadError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.uploadError(data: data, statusCode: httpResponse.statusCode)
        }
        guard let location = httpResponse.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location) else {
            throw YouTubeUploadError.missingUploadLocation
        }
        return uploadURL
    }

    private static func nextUploadOffset(from range: String?, fallback: Int64) throws -> Int64 {
        guard let range else { return fallback }
        guard let lastComponent = range.split(separator: "-").last,
              let lastByte = Int64(lastComponent) else {
            throw YouTubeUploadError.invalidResponse
        }
        return lastByte + 1
    }

    private enum UploadRecovery {
        case resume(Int64)
        case completed(YouTubeVideo)
    }

    /// Checks how many bytes YouTube persisted after an interrupted request.
    /// Retries use `Retry-After` when supplied and bounded exponential backoff
    /// otherwise. A completed session can return the final video resource.
    private func recoverUpload(
        at uploadURL: URL,
        fileSize: Int64,
        accessToken: String,
        initialRetryAfter: String? = nil
    ) async throws -> UploadRecovery {
        var delaySeconds = Int(initialRetryAfter ?? "") ?? 1
        var lastError: (any Error)?

        for attempt in 0..<5 {
            try Task.checkCancellation()
            try await sleep(.seconds(delaySeconds))

            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.setValue("bytes */\(fileSize)", forHTTPHeaderField: "Content-Range")

            do {
                let (data, response) = try await send(request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw YouTubeUploadError.invalidResponse
                }

                if httpResponse.statusCode == 308 {
                    return .resume(try Self.nextUploadOffset(
                        from: httpResponse.value(forHTTPHeaderField: "Range"),
                        fallback: 0
                    ))
                }
                if (200...299).contains(httpResponse.statusCode) {
                    return .completed(try JSONDecoder().decode(YouTubeVideo.self, from: data))
                }
                if !(500...599).contains(httpResponse.statusCode) {
                    throw Self.uploadError(data: data, statusCode: httpResponse.statusCode)
                }

                lastError = Self.uploadError(data: data, statusCode: httpResponse.statusCode)
                delaySeconds = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "")
                    ?? min(delaySeconds * 2, 16)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as YouTubeUploadError {
                throw error
            } catch {
                lastError = error
                delaySeconds = min(delaySeconds * 2, 16)
            }

            if attempt == 4, let lastError {
                throw lastError
            }
        }

        throw YouTubeUploadError.uploadStalled
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody

        struct ErrorBody: Decodable {
            let message: String?
            let errors: [Detail]?
        }

        struct Detail: Decodable {
            let reason: String?
        }
    }

    private static func uploadError(data: Data, statusCode: Int) -> YouTubeUploadError {
        let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        return .requestFailed(
            statusCode: statusCode,
            reason: decoded?.error.errors?.first?.reason,
            message: decoded?.error.message
        )
    }
}
