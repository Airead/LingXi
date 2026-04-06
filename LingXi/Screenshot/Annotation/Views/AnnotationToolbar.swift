//
//  AnnotationToolbar.swift
//  LingXi
//

import SwiftUI

struct AnnotationToolbar: View {
    var state: AnnotationState

    @State private var showColorPopover = false
    @State private var showStrokeWidthPopover = false
    @State private var showFontSizePopover = false

    private static let enabledTools: Set<AnnotationTool> = [
        .selection, .rectangle, .filledRectangle, .ellipse, .arrow, .line,
        .pencil, .highlighter, .text, .counter, .blur, .crop,
    ]

    private static let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .white, .black,
    ]

    private static let strokeWidths: [CGFloat] = [1, 2, 3, 5, 8]
    private static let fontSizes: [CGFloat] = [12, 14, 16, 20, 24, 32, 48]

    var body: some View {
        HStack(spacing: 12) {
            toolButtons
            Divider().frame(height: 24)
            colorSection
            Divider().frame(height: 24)
            strokeWidthButton
            if state.selectedTool == .text || state.selectedTool == .counter {
                fontSizeButton
            }
            if state.selectedTool == .blur {
                blurTypeToggle
            }
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
        popoverPicker(
            isPresented: $showStrokeWidthPopover,
            values: Self.strokeWidths,
            selected: state.strokeWidth,
            onSelect: { state.strokeWidth = $0 },
            triggerLabel: {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary)
                    .frame(width: 16, height: max(2, state.strokeWidth))
            },
            rowLabel: { width in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary)
                    .frame(width: 40, height: max(2, width))
            },
            rowDetail: { width in "\(Int(width))px" }
        )
    }

    // MARK: - Font size button

    private var fontSizeButton: some View {
        popoverPicker(
            isPresented: $showFontSizePopover,
            values: Self.fontSizes,
            selected: state.fontSize,
            onSelect: { state.fontSize = $0 },
            triggerLabel: {
                Text("\(Int(state.fontSize))pt")
                    .font(.system(size: 12))
            },
            rowLabel: { size in
                Text("Aa")
                    .font(.system(size: min(size, 20)))
            },
            rowDetail: { size in "\(Int(size))pt" }
        )
    }

    private func popoverPicker<Trigger: View, RowLabel: View>(
        isPresented: Binding<Bool>,
        values: [CGFloat],
        selected: CGFloat,
        onSelect: @escaping (CGFloat) -> Void,
        @ViewBuilder triggerLabel: () -> Trigger,
        @ViewBuilder rowLabel: @escaping (CGFloat) -> RowLabel,
        rowDetail: @escaping (CGFloat) -> String
    ) -> some View {
        Button {
            isPresented.wrappedValue = true
        } label: {
            HStack(spacing: 4) {
                triggerLabel()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 32)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPresented.wrappedValue
                          ? Color.accentColor.opacity(0.2)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: isPresented) {
            VStack(spacing: 0) {
                ForEach(values, id: \.self) { value in
                    Button {
                        onSelect(value)
                        isPresented.wrappedValue = false
                    } label: {
                        HStack {
                            rowLabel(value)
                            Spacer()
                            Text(rowDetail(value))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if selected == value {
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

    // MARK: - Blur type toggle

    private var blurTypeToggle: some View {
        HStack(spacing: 2) {
            blurTypeButton(.pixelate)
            blurTypeButton(.gaussian)
        }
    }

    private func blurTypeButton(_ type: BlurType) -> some View {
        Button {
            state.blurType = type
        } label: {
            Image(systemName: type.systemImage)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(state.blurType == type
                              ? Color.accentColor.opacity(0.2)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(type.label)
    }
}
