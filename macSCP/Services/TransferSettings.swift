//
//  TransferSettings.swift
//  macSCP
//
//  Manages file transfer preferences (concurrent stream limits, etc.)
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class TransferSettings {
    static let shared = TransferSettings()

    private enum Keys {
        static let maxConcurrentTransfers = "app.settings.maxConcurrentTransfers"
    }

    /// Number of concurrent transfer streams (1 to 8, default 3)
    var maxConcurrentTransfers: Int {
        didSet {
            let clamped = max(1, min(8, maxConcurrentTransfers))
            if maxConcurrentTransfers != clamped {
                maxConcurrentTransfers = clamped
            }
            UserDefaults.standard.set(maxConcurrentTransfers, forKey: Keys.maxConcurrentTransfers)
        }
    }

    private init() {
        let stored = UserDefaults.standard.integer(forKey: Keys.maxConcurrentTransfers)
        self.maxConcurrentTransfers = stored > 0 ? max(1, min(8, stored)) : 3
    }
}
