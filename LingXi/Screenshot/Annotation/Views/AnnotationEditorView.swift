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
            bottomBarPlaceholder
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

    private var bottomBarPlaceholder: some View {
        HStack {
            Text("Bottom Bar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
    }
}
