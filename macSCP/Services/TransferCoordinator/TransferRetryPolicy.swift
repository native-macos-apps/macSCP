//
//  TransferRetryPolicy.swift
//  macSCP
//
//  Application-level retry, exponential backoff with jitter, and transient error classification
//

import Foundation

struct TransferRetryPolicy: Sendable {
    let maxRetries: Int
    let initialDelay: TimeInterval
    let maxDelay: TimeInterval
    let backoffMultiplier: Double
    let jitterFactor: Double

    static let `default` = TransferRetryPolicy(
        maxRetries: 3,
        initialDelay: 0.4,
        maxDelay: 4.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.25
    )

    static let none = TransferRetryPolicy(
        maxRetries: 0,
        initialDelay: 0,
        maxDelay: 0,
        backoffMultiplier: 1.0,
        jitterFactor: 0
    )

    init(
        maxRetries: Int = 3,
        initialDelay: TimeInterval = 0.4,
        maxDelay: TimeInterval = 4.0,
        backoffMultiplier: Double = 2.0,
        jitterFactor: Double = 0.25
    ) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitterFactor = jitterFactor
    }

    /// Determines if an error is transient and retriable under the policy
    func shouldRetry(error: Error, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }

        // Never retry cancellation
        if Task.isCancelled || error is CancellationError {
            return false
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("cancel") {
            return false
        }

        // Never retry permanent permission or invalid path / credential errors
        if let appErr = error as? AppError {
            switch appErr {
            case .permissionDenied, .s3AccessDenied, .invalidS3Credentials, .fileNotFound:
                return false
            case .connectionTimeout, .connectionFailed, .notConnected:
                return true
            case .s3OperationFailed(let msg):
                let lower = msg.lowercased()
                if lower.contains("accessdenied") || lower.contains("forbidden") || lower.contains("credential") || lower.contains("nosuchkey") || lower.contains("nosuchbucket") {
                    return false
                }
                if lower.contains("slowdown") || lower.contains("503") || lower.contains("429") || lower.contains("timeout") || lower.contains("throttling") {
                    return true
                }
                return true
            default:
                break
            }
        }

        // Check POSIX error codes
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            let code = Int32(nsError.code)
            if code == EACCES || code == EPERM || code == ENOENT || code == ENOTDIR {
                return false
            }
            if code == ECONNRESET || code == ETIMEDOUT || code == EPIPE || code == ENETDOWN || code == ENETUNREACH || code == ECONNREFUSED {
                return true
            }
        }

        // Check common strings
        if desc.contains("permission") || desc.contains("access denied") || desc.contains("unauthorized") || desc.contains("no such file") {
            return false
        }
        if desc.contains("parent directory") && desc.contains("failed") {
            return false
        }

        // Transient network & throttling errors are retriable
        if desc.contains("timeout") || desc.contains("connection reset") || desc.contains("broken pipe") || desc.contains("slowdown") || desc.contains("rate limit") || desc.contains("network") || desc.contains("socket") || desc.contains("temporarily unavailable") {
            return true
        }

        // Default: treat unknown repository errors as retriable up to maxRetries
        return true
    }

    /// Computes exponential backoff delay with random jitter for a given retry attempt (1-based)
    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = Double(max(0, attempt - 1))
        let baseDelay = min(maxDelay, initialDelay * pow(backoffMultiplier, exponent))
        let jitterRange = baseDelay * jitterFactor
        let jitter = Double.random(in: -jitterRange...jitterRange)
        return max(0.05, baseDelay + jitter)
    }
}
