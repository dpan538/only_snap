import CoreGraphics

/// Applies centre-crops to match target aspect ratios.
///
/// ## Coordinate system note
/// iPhone sensor data is always **landscape** (width > height).  The image is later
/// wrapped in a `UIImage` with `orientation = .right`, which swaps the displayed
/// width and height.  Therefore the crop logic must be expressed in *rotated display
/// coordinates*, i.e.:
///
///   displayed width  = raw image **height** (srcH)
///   displayed height = raw image **width**  (srcW)
///
/// To obtain a portrait 3:4 output (display W:H = 3:4) we need:
///   srcH / srcW = 3/4  →  srcW = srcH × 4/3 = 4032 (for the standard 12 MP sensor)
/// which is exactly the unmodified raw frame — **no crop needed** for 3:4.
///
/// For 2:3 portrait (display W:H = 2:3) we need srcH / srcW = 2/3, i.e.
///   srcW = srcH × 3/2 = 4536 — wider than the sensor, so we crop srcH instead:
///   srcH_new = srcW × 2/3 = 2688.
///
enum CropManager {

    /// Crops `image` (always 4:3 landscape from iPhone sensor) in two stages:
    /// 1. focal-length crop (digital zoom) based on `cropFactor`  — skipped when ≤ 1.0
    /// 2. aspect-ratio crop accounting for the 90° UIImage.Orientation.right rotation
    ///
    /// Returns `nil` only if the underlying `CGImage` cropping fails.
    static func crop(image: CGImage, format: AspectFormat, cropFactor: CGFloat) -> CGImage? {

        // ---------- Stage 1: focal crop ----------
        let focalCropped: CGImage
        if cropFactor <= 1.0 {
            focalCropped = image
        } else {
            let w = CGFloat(image.width)
            let h = CGFloat(image.height)
            let croppedW = w / cropFactor
            let croppedH = h / cropFactor

            let focalRect = centeredPixelAlignedRect(
                width: croppedW,
                height: croppedH,
                in: CGRect(x: 0, y: 0, width: w, height: h)
            )
            guard let cropped = image.cropping(to: focalRect) else { return nil }
            focalCropped = cropped
        }

        // ---------- Stage 2: aspect-ratio crop ----------
        // srcW > srcH for landscape sensor data.
        // After UIImage.Orientation.right is applied:
        //   display width  = srcH
        //   display height = srcW
        let srcW = CGFloat(focalCropped.width)
        let srcH = CGFloat(focalCropped.height)

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        switch format {

        case .square:
            // Display 1:1 → need srcH = srcW → crop to square using the shorter side.
            // With .right rotation: display = min(srcH, srcW) × min(srcH, srcW) ✓
            let side     = min(srcW, srcH)
            targetWidth  = side
            targetHeight = side

        case .threeToFour:
            // Display 3:4 → need srcH : srcW = 3 : 4.
            // Standard iPhone sensor: srcW = 4032, srcH = 3024 → ratio = 3:4 exactly.
            // No crop required; keep the full frame.
            targetWidth  = srcW
            targetHeight = srcH

        case .twoToThree:
            // Display 2:3 → need srcH : srcW = 2 : 3.
            // Required srcW = srcH × 3/2 = 4536 > 4032 — wider than the sensor.
            // Solution: keep full srcW and crop srcH symmetrically.
            //   targetHeight = srcW × (2/3)   e.g. 4032 × 2/3 = 2688
            // With .right rotation: display = 2688 × 4032 = 2:3 portrait ✓
            targetWidth  = srcW
            targetHeight = srcW * (2.0 / 3.0)

        case .cinematicWide:
            // Display 2.39:1 after the right-rotation metadata:
            //   display width = srcH, display height = cropped srcW
            // therefore cropped srcW = srcH / 2.39.
            // This is intentionally a narrow cinema crop, paired with 28mm capture.
            targetWidth = srcH / 2.39
            targetHeight = srcH
        }

        let aspectRect = centeredPixelAlignedRect(
            width: targetWidth,
            height: targetHeight,
            in: CGRect(x: 0, y: 0, width: srcW, height: srcH)
        )
        return focalCropped.cropping(to: aspectRect)
    }

    private static func centeredPixelAlignedRect(width: CGFloat, height: CGFloat, in bounds: CGRect) -> CGRect {
        let alignedWidth = max(2, floor(min(width, bounds.width) / 2.0) * 2.0)
        let alignedHeight = max(2, floor(min(height, bounds.height) / 2.0) * 2.0)
        let x = floor(bounds.midX - alignedWidth * 0.5)
        let y = floor(bounds.midY - alignedHeight * 0.5)

        return CGRect(x: x, y: y, width: alignedWidth, height: alignedHeight)
            .intersection(bounds)
            .integral
    }
}
