import Foundation
import CoreGraphics

struct GestureTranslator {
    let framebufferSize: CGSize
    let viewSize: CGSize

    /// The actual displayed image size within the view (aspect-ratio fit)
    var displayedImageSize: CGSize {
        guard framebufferSize.width > 0, framebufferSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        let imageAspect = framebufferSize.width / framebufferSize.height
        let viewAspect = viewSize.width / viewSize.height

        if imageAspect > viewAspect {
            return CGSize(
                width: viewSize.width,
                height: viewSize.width / imageAspect
            )
        } else {
            return CGSize(
                width: viewSize.height * imageAspect,
                height: viewSize.height
            )
        }
    }

    /// Offset of the displayed image from the top-left of the view
    var imageOffset: CGPoint {
        let displayed = displayedImageSize
        return CGPoint(
            x: (viewSize.width - displayed.width) / 2,
            y: (viewSize.height - displayed.height) / 2
        )
    }

    /// Convert a point in view coordinates to framebuffer coordinates.
    /// Returns nil if the point is outside the displayed image bounds.
    func viewToFramebuffer(_ viewPoint: CGPoint) -> (x: UInt16, y: UInt16)? {
        let displayed = displayedImageSize
        let offset = imageOffset

        let relativeX = viewPoint.x - offset.x
        let relativeY = viewPoint.y - offset.y

        guard relativeX >= 0, relativeX <= displayed.width,
              relativeY >= 0, relativeY <= displayed.height else {
            return nil
        }

        let fbX = relativeX / displayed.width * framebufferSize.width
        let fbY = relativeY / displayed.height * framebufferSize.height

        return (
            x: UInt16(clamping: Int(fbX)),
            y: UInt16(clamping: Int(fbY))
        )
    }
}
