//
//  S3ErrorMapper.swift
//  macSCP
//
//  Maps typed AWS SDK / network errors to AppError cases
//

import AWSS3
import Foundation

enum S3ErrorMapper {
    static func mapConnectionError(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        if error is AWSS3.NoSuchBucket {
            return .s3BucketNotFound
        }
        if error is AWSS3.NotFound {
            return .s3BucketNotFound
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .connectionTimeout
        }

        let description = error.localizedDescription.lowercased()
        if description.contains("invalid access key") || description.contains("signature") {
            return .invalidS3Credentials
        } else if description.contains("bucket") && description.contains("not found") {
            return .s3BucketNotFound
        } else if description.contains("access denied") || description.contains("forbidden") {
            return .s3AccessDenied
        } else if description.contains("timeout") {
            return .connectionTimeout
        }

        return .connectionFailed(error.localizedDescription)
    }

    static func mapOperationError(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        if error is AWSS3.NoSuchBucket {
            return .s3BucketNotFound
        }
        if error is AWSS3.NoSuchKey || error is AWSS3.NotFound {
            return .s3ObjectNotFound
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .connectionTimeout
        }

        let description = String(describing: error).lowercased()
        if description.contains("nosuchbucket") || (description.contains("bucket") && description.contains("not found")) {
            return .s3BucketNotFound
        } else if description.contains("nosuchkey") || description.contains("no such key") || description.contains("not found") {
            return .s3ObjectNotFound
        } else if description.contains("accessdenied") || description.contains("access denied") || description.contains("forbidden") {
            return .s3AccessDenied
        } else if description.contains("invalidsignature") || description.contains("credential") {
            return .invalidS3Credentials
        }

        return .s3OperationFailed(error.localizedDescription)
    }
}
