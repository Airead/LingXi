//
//  CGRect+Flip.swift
//  LingXi
//

import CoreGraphics

extension CGRect {
    /// Convert between flipped coordinate systems (y=0 at top vs y=0 at bottom).
    nonisolated func verticallyFlipped(imageHeight: CGFloat) -> CGRect {
        CGRect(x: origin.x, y: imageHeight - origin.y - height, width: width, height: height)
    }
}
