//
//  AnnotationToolbar.swift
//  LingXi
//

import SwiftUI

struct AnnotationToolbar: View {
    var state: AnnotationState

    @State private var showColorPopover = false
    @State private var showStrokeWidthPopover = false

    private static let enabledTools: Set<AnnotationTool> = [
        .selection, .rectangle, .filledRectangle, .ellipse, .line,
    ]

    private static let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .white, .black,
    ]

    private static let strokeWidths: [CGFloat] = [1, 2, 3, 5, 8]

    var body: some View {
        HStack(spacing: 12) {
            toolButtons
            Divider().frame(height: 24)
            colorSection
            Divider().frame(height: 24)
            strokeWidthButton
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tool buttons

    private var toolButtons: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                let enabled = Self.enabledTools.contains(tool)
                Button {
                    state.selectedTool = tool
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(state.selectedTool == tool
                                      ? Color.accentColor.opacity(0.2)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1.0 : 0.3)
                .help(tool.displayName)
            }
        }
    }

    // MARK: - Color section

    private var colorSection: some View {
        HStack(spacing: 4) {
            ForEach(Self.presetColors, id: \.self) { color in
                colorSwatch(color)
            }
            customColorButton
        }
    }

    private func colorSwatch(_ color: Color) -> some View {
        Button {
            state.strokeColor = color
        } label: {
            Circle()
                .fill(color)
                .stroke(
                    state.strokeColor == color ? Color.accentColor : Color.gray.opacity(0.4),
                    lineWidth: state.strokeColor == color ? 2 : 1
                )
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }

    private var customColorButton: some View {
        Button {
            showColorPopover = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        )
                    )
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(.background)
                    .frame(width: 10, height: 10)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPopover) {
            ColorPicker("Color", selection: Bindable(state).strokeColor)
                .labelsHidden()
                .padding(8)
        }
    }

    // MARK: - Stroke width button

    private var strokeWidthButton: some View {
        Button {
            showStrokeWidthPopover = true
        } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary)
                    .frame(width: 16, height: max(2, state.strokeWidth))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 32)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(showStrokeWidthPopover
                          ? Color.accentColor.opacity(0.2)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showStrokeWidthPopover) {
            VStack(spacing: 0) {
                ForEach(Array(Self.strokeWidths.enumerated()), id: \.offset) { _, width in
                    Button {
                        state.strokeWidth = width
                        showStrokeWidthPopover = false
                    } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary)
                                .frame(width: 40, height: max(2, width))
                            Spacer()
                            Text("\(Int(width))px")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if state.strokeWidth == width {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 140)
            .padding(.vertical, 4)
        }
    }
}
