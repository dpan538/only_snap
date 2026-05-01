import CoreImage

/// Shared film-profile processing used by both live preview and saved photos.
enum FilmProfileProcessor {

    nonisolated static func preheatResources(for profile: FilmProfile) {
        switch profile {
        case .raw:
            return
        case .vg:
            VGProcessor.preheatResources()
        case .ew:
            EWProcessor.preheatResources()
        case .lg:
            LGProcessor.preheatResources()
        }
    }

    nonisolated static func apply(
        profile: FilmProfile,
        to image: CIImage,
        focalLength: Int = 28,
        isPreview: Bool = false
    ) -> CIImage {
        switch profile {
        case .raw:
            return image
        case .vg:
            return VGProcessor.apply(to: image, focalLength: focalLength)
        case .ew:
            return EWProcessor.apply(to: image, focalLength: focalLength, useFastAnalysis: isPreview)
        case .lg:
            return LGProcessor.apply(to: image, focalLength: focalLength, isPreview: isPreview)
        }
    }
}

extension CGFloat {
    nonisolated func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
