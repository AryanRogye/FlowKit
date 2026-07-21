//
//  GoogleDriveFolders.swift
//  FlowKit
//

import Foundation

/// An explicitly selected destination for an upload or new folder.
public enum GoogleDriveDestination: Sendable, Equatable {
    /// The top level of the user's My Drive.
    case root
    /// A folder selected by its Drive file ID.
    case folder(id: String)
    /// The hidden application-data folder.
    case appData

    var folderID: String {
        switch self {
        case .root: "root"
        case .folder(let id): id
        case .appData: "appDataFolder"
        }
    }

    var isValid: Bool {
        if case .folder(let id) = self {
            return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

public struct GoogleDriveFolder: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let parents: [String]?
    public let createdTime: Date?
    public let modifiedTime: Date?
}

public struct GoogleDriveFolderPage: Sendable, Equatable {
    public let folders: [GoogleDriveFolder]
    public let nextPageToken: String?
}

public enum GoogleDriveFolderError: LocalizedError, Sendable, Equatable {
    case invalidName
    case invalidFolderID
    case invalidPageSize
    case invalidResponse
    case requestFailed(statusCode: Int, reason: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "A Google Drive folder name is required."
        case .invalidFolderID: "A valid Google Drive folder ID is required."
        case .invalidPageSize: "Google Drive folder page size must be between 1 and 1,000."
        case .invalidResponse: "Google Drive returned an invalid folder response."
        case let .requestFailed(statusCode, reason, message):
            message ?? reason ?? "Google Drive folder request failed with HTTP status \(statusCode)."
        }
    }
}

extension GoogleDriveFlow {
    /// Lists the accessible child folders of an explicitly chosen location.
    public func listFolders(
        in destination: GoogleDriveDestination,
        accessToken: String,
        pageSize: Int = 100,
        pageToken: String? = nil
    ) async throws -> GoogleDriveFolderPage {
        try Self.validate(destination)
        guard (1...1_000).contains(pageSize) else { throw GoogleDriveFolderError.invalidPageSize }

        let parent = Self.escapedQueryValue(destination.folderID)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
        components?.queryItems = [
            .init(name: "q", value: "mimeType = 'application/vnd.google-apps.folder' and trashed = false and '\(parent)' in parents"),
            .init(name: "spaces", value: destination == .appData ? "appDataFolder" : "drive"),
            .init(name: "orderBy", value: "name_natural"),
            .init(name: "pageSize", value: String(pageSize)),
            .init(name: "fields", value: "nextPageToken,files(id,name,parents,createdTime,modifiedTime)"),
        ]
        if let pageToken, !pageToken.isEmpty {
            components?.queryItems?.append(.init(name: "pageToken", value: pageToken))
        }
        guard let url = components?.url else { throw GoogleDriveFolderError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, rawResponse) = try await send(request)
        try Self.checkFolderResponse(data: data, response: rawResponse)
        do {
            let decoded = try Self.driveDecoder.decode(FolderListResponse.self, from: data)
            return .init(folders: decoded.files, nextPageToken: decoded.nextPageToken)
        } catch {
            throw GoogleDriveFolderError.invalidResponse
        }
    }

    /// Creates a folder inside an explicitly chosen parent location.
    public func createFolder(
        named name: String,
        in destination: GoogleDriveDestination,
        accessToken: String
    ) async throws -> GoogleDriveFolder {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleDriveFolderError.invalidName
        }
        try Self.validate(destination)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
        components?.queryItems = [
            .init(name: "fields", value: "id,name,parents,createdTime,modifiedTime"),
        ]
        guard let url = components?.url else { throw GoogleDriveFolderError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateFolderRequest(
            name: name,
            mimeType: "application/vnd.google-apps.folder",
            parents: [destination.folderID]
        ))
        let (data, rawResponse) = try await send(request)
        try Self.checkFolderResponse(data: data, response: rawResponse)
        do { return try Self.driveDecoder.decode(GoogleDriveFolder.self, from: data) }
        catch { throw GoogleDriveFolderError.invalidResponse }
    }

    private struct FolderListResponse: Decodable {
        let files: [GoogleDriveFolder]
        let nextPageToken: String?
    }

    private struct CreateFolderRequest: Encodable {
        let name: String
        let mimeType: String
        let parents: [String]
    }

    private struct FolderErrorEnvelope: Decodable {
        let error: Body
        struct Body: Decodable { let message: String?; let errors: [Detail]? }
        struct Detail: Decodable { let reason: String? }
    }

    private static let driveDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func validate(_ destination: GoogleDriveDestination) throws {
        if !destination.isValid {
            throw GoogleDriveFolderError.invalidFolderID
        }
    }

    private static func escapedQueryValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private static func checkFolderResponse(data: Data, response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw GoogleDriveFolderError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            let decoded = try? JSONDecoder().decode(FolderErrorEnvelope.self, from: data)
            throw GoogleDriveFolderError.requestFailed(
                statusCode: response.statusCode,
                reason: decoded?.error.errors?.first?.reason,
                message: decoded?.error.message
            )
        }
    }
}
