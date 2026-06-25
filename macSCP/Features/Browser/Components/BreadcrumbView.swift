//
//  BreadcrumbView.swift
//  macSCP
//
//  Finder-style path bar for the file browser
//

import SwiftUI

struct BreadcrumbView: View {
    let components: [PathComponent]
    let onNavigate: (String) -> Void

    @State private var hoveredPath: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Root
                    pathButton(icon: "externaldrive.fill", path: "/", isLast: components.isEmpty)

                    ForEach(components) { component in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 1)

                        pathButton(text: component.name, path: component.path, isLast: component.path == components.last?.path)
                            .id(component.path)
                    }
                }
                .padding(.horizontal, 0)
                .padding(.vertical, 2)
            }
            .onChange(of: components) { _, newComponents in
                if let lastPath = newComponents.last?.path {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(lastPath, anchor: .trailing)
                    }
                }
            }
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private func pathButton(icon: String? = nil, text: String? = nil, path: String, isLast: Bool) -> some View {
        let isHovered = hoveredPath == path

        Button {
            onNavigate(path)
        } label: {
            Group {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                } else if let text = text {
                    Text(text)
                        .font(.system(size: 12, weight: isLast ? .medium : .regular))
                }
            }
            .foregroundStyle(isLast ? .primary : .tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredPath = hovering ? path : nil
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 0) {
        BreadcrumbView(
            components: [],
            onNavigate: { _ in }
        )

        Divider()

        BreadcrumbView(
            components: [
                PathComponent(name: "home", path: "/home"),
                PathComponent(name: "user", path: "/home/user"),
                PathComponent(name: "documents", path: "/home/user/documents")
            ],
            onNavigate: { _ in }
        )

        Divider()

        BreadcrumbView(
            components: [
                PathComponent(name: "var", path: "/var"),
                PathComponent(name: "www", path: "/var/www"),
                PathComponent(name: "html", path: "/var/www/html"),
                PathComponent(name: "myproject", path: "/var/www/html/myproject"),
                PathComponent(name: "src", path: "/var/www/html/myproject/src")
            ],
            onNavigate: { _ in }
        )
    }
    .frame(width: 400)
}
