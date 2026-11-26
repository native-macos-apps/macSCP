//
//  S3PathResolver.swift
//  macSCP
//
//  Pure S3 path, key, prefix, and object URL builder
//

import Foundation

struct S3PathResolver: Sendable {
    let configuredBucketName: String
    let regionName: String
    let endpointURL: URL?
    let usesPathStyleURLs: Bool

    init(
        configuredBucketName: String = "",
        regionName: String = "us-east-1",
        endpointURL: URL? = nil,
        usesPathStyleURLs: Bool = false
    ) {
        self.configuredBucketName = configuredBucketName
        self.regionName = regionName
        self.endpointURL = endpointURL
        self.usesPathStyleURLs = usesPathStyleURLs
    }

    static func normalizeEndpointURL(_ endpoint: String?) -> URL? {
        guard let endpoint else { return nil }
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"), let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }

        return URL(string: "https://\(trimmed)")
    }

    /// Normalizes a path to an S3 key (removes leading `/`)
    func normalizeKey(_ path: String) -> String {
        var key = path
        while key.hasPrefix("/") {
            key = String(key.dropFirst())
        }
        return key
    }

    /// Normalizes a path to a prefix for listing (removes leading `/`, ensures trailing `/` for directories)
    func normalizePrefix(_ path: String) -> String {
        var prefix = path
        while prefix.hasPrefix("/") {
            prefix = String(prefix.dropFirst())
        }
        if prefix == "/" || prefix.isEmpty {
            return ""
        }
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }
        return prefix
    }

    func resolveListTarget(for path: String) throws -> (bucket: String, prefix: String, displayPath: String) {
        if !configuredBucketName.isEmpty {
            let prefix = normalizePrefix(path)
            let displayPath = prefix.isEmpty ? "/" : "/" + prefix
            return (configuredBucketName, prefix, displayPath)
        }

        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            return ("", "", "/")
        }

        let components = trimmedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let bucket = components[0]
        let remainder = components.dropFirst().joined(separator: "/")
        let prefix = remainder.isEmpty ? "" : remainder + "/"
        return (bucket, prefix, "/" + ([bucket] + (remainder.isEmpty ? [] : [remainder])).joined(separator: "/"))
    }

    func resolveObjectTarget(for path: String) throws -> (bucket: String, key: String) {
        if !configuredBucketName.isEmpty {
            let key = normalizeKey(path)
            guard !key.isEmpty else {
                throw AppError.invalidPath
            }
            return (configuredBucketName, key)
        }

        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let bucket = components.first else {
            throw AppError.invalidPath
        }

        let key = components.dropFirst().joined(separator: "/")
        guard !key.isEmpty else {
            throw AppError.invalidPath
        }

        return (bucket, key)
    }

    /// Extracts the name from a key given a base prefix
    func extractName(from key: String, basePrefix: String) -> String {
        var name = String(key.dropFirst(basePrefix.count))
        if name.hasSuffix("/") {
            name = String(name.dropLast())
        }
        if let slashIndex = name.firstIndex(of: "/") {
            name = String(name[..<slashIndex])
        }
        return name
    }

    func copySource(bucket: String, key: String) -> String {
        let raw = "\(bucket)/\(key)"
        return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    func buildDisplayPath(bucket: String, key: String) -> String {
        guard !configuredBucketName.isEmpty else {
            return "/" + bucket + (key.isEmpty ? "" : "/" + key)
        }
        return "/" + key
    }

    func buildObjectURL(bucket: String, forKey key: String) -> URL? {
        if usesPathStyleURLs, let endpointURL {
            return buildPathStyleURL(baseURL: endpointURL, bucket: bucket, key: key)
        }
        return buildAWSHostedStyleURL(bucket: bucket, forKey: key)
    }

    private func buildPathStyleURL(baseURL: URL, bucket: String, key: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let bucketPath = percentEncodePathComponent(bucket)
        let keyPath = percentEncodeObjectKey(key)
        let joinedPath = [basePath, bucketPath, keyPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        components.percentEncodedPath = "/" + joinedPath
        return components.url
    }

    private func buildAWSHostedStyleURL(bucket: String, forKey key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(bucket).s3.\(regionName).amazonaws.com"
        components.percentEncodedPath = "/" + percentEncodeObjectKey(key)
        return components.url
    }

    private func percentEncodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private func percentEncodeObjectKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
                ) ?? String(segment)
            }
            .joined(separator: "/")
    }
}
