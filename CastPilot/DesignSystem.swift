//  DesignSystem.swift
//  CastPilot
//
//  Shared spacing, type and small building blocks used by every window.

import SwiftUI

// MARK: - Shared UI Building Blocks

/// One place for spacing, label width and type used across the editor and settings windows.
enum UI {
    static let pad: CGFloat = 12
    static let labelWidth: CGFloat = 96
    static let itemTitle = Font.system(size: 13, weight: .semibold)
    static let coverTint = Color.orange
    /// Plain integer formatter — no thousands separator (ports, milliseconds).
    static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.usesGroupingSeparator = false
        f.allowsFloats = false
        return f
    }()
}

/// Column / section title with uniform spacing, so headers line up across columns.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UI.pad)
            .padding(.top, UI.pad)
            .padding(.bottom, 6)
    }
}

/// Label on the left (no colon), control on the right. Pass `labelWidth: nil` for a natural-width label.
struct FieldRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat?
    let content: Content

    init(_ label: String, labelWidth: CGFloat? = UI.labelWidth, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content
        }
    }
}

/// macOS-style +/− bar under a list. "−" removes the selected row.
struct AddRemoveBar: View {
    let addHelp: String
    let removeHelp: String
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onAdd) {
                Image(systemName: "plus").frame(width: 22, height: 18)
            }
            .help(addHelp)
            Button(action: onRemove) {
                Image(systemName: "minus").frame(width: 22, height: 18)
            }
            .disabled(!canRemove)
            .help(removeHelp)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Small orange "Cover" tag, used wherever a cover is selected.
struct CoverBadge: View {
    var body: some View {
        Text("Cover")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(UI.coverTint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(UI.coverTint.opacity(0.18)))
    }
}

/// Ballett variants are marked with "↪" wherever members are listed (menus can't show italics).
func memberDisplayName(_ member: CastMember) -> String {
    member.coverVariantOf == nil ? member.name : "↪ \(member.name)"
}

