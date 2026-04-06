//
//  AnnotationEditorView.swift
//  LingXi
//

import SwiftUI

struct AnnotationEditorView: View {
    var state: AnnotationState

    var body: some View {
        VStack(spacing: 0) {
            toolbarPlaceholder
            Divider()
            imageCanvas
            Divider()
            bottomBarPlaceholder
        }
        .background(.windowBackground)
    }

    // MARK: - Subviews

    private var toolbarPlaceholder: some View {
        HStack {
            Text("Toolbar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 40)
        .frame(maxWidth: .infinity)
    }

    private var imageCanvas: some View {
        Image(nsImage: state.sourceImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
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
