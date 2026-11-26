//
//  ServerTableCellViews.swift
//  macSCP
//
//  Custom NSTableCellView implementations for server and folder rows in NativeServersTableView.
//

import AppKit
import UniformTypeIdentifiers

final class ServerTableCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSBox()
    private var defaultIconColor: NSColor = .systemBlue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(detailLabel)

        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.boxType = .custom
        badgeContainer.borderWidth = 0
        badgeContainer.cornerRadius = 4
        badgeContainer.fillColor = NSColor.labelColor.withAlphaComponent(0.06)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 9, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center
        badgeContainer.addSubview(badgeLabel)
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),
            iconImageView.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -6),

            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -5),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor)
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    private func updateColors() {
        let isEmphasized = backgroundStyle == .emphasized
        if isEmphasized {
            nameLabel.textColor = .white
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.8)
            badgeLabel.textColor = .white
            badgeContainer.fillColor = NSColor.white.withAlphaComponent(0.2)
            iconImageView.contentTintColor = .white
        } else {
            nameLabel.textColor = .labelColor
            detailLabel.textColor = .secondaryLabelColor
            badgeLabel.textColor = .secondaryLabelColor
            badgeContainer.fillColor = NSColor.labelColor.withAlphaComponent(0.06)
            iconImageView.contentTintColor = defaultIconColor
        }
    }

    func configure(connection: Connection) {
        nameLabel.stringValue = connection.name
        detailLabel.stringValue = connection.connectionString
        badgeLabel.stringValue = connection.connectionType.displayName

        let iconName = connection.iconName
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            iconImageView.image = img.withSymbolConfiguration(config)
        }

        switch connection.connectionType {
        case .sftp:
            defaultIconColor = .systemBlue
        case .s3:
            defaultIconColor = .systemOrange
        case .local:
            defaultIconColor = .systemGreen
        }
        updateColors()
    }
}

final class FolderTableCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var defaultTintColor: NSColor = .controlAccentColor
    private var isSystemFolderIcon = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    private func updateColors() {
        let isEmphasized = backgroundStyle == .emphasized
        if isEmphasized {
            titleLabel.textColor = .white
            countLabel.textColor = NSColor.white.withAlphaComponent(0.75)
            iconImageView.contentTintColor = isSystemFolderIcon ? nil : .white
        } else {
            titleLabel.textColor = .labelColor
            countLabel.textColor = .secondaryLabelColor
            iconImageView.contentTintColor = isSystemFolderIcon ? nil : defaultTintColor
        }
    }

    func configure(folder: Folder, count: Int) {
        titleLabel.stringValue = folder.name
        countLabel.stringValue = "(\(count))"
        isSystemFolderIcon = true
        iconImageView.image = NSWorkspace.shared.icon(for: .folder)
        updateColors()
    }

    func configure(title: String, iconName: String, count: Int) {
        titleLabel.stringValue = title
        countLabel.stringValue = "(\(count))"
        isSystemFolderIcon = false
        defaultTintColor = .secondaryLabelColor
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconImageView.image = img.withSymbolConfiguration(config)
        }
        updateColors()
    }
}
