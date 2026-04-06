//
//  AnnotationEditorView.swift
//  LingXi
//

import SwiftUI

struct AnnotationEditorView: View {
    var state: AnnotationState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            imageCanvas
            Divider()
            bottomBar
        }
        .background(.windowBackground)
    }

    // MARK: - Subviews

    private var toolbar: some View {
        AnnotationToolbar(state: state)
    }

    private var imageCanvas: some View {
        AnnotationCanvasView(state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
                state.onSave?()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                state.onCopy?()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
    }
}
