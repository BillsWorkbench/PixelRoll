import CoreImage

// Kernels are compiled once; all effects retain the input's bounds and alpha.
nonisolated enum DevelopEffects {
    private static let haze = CIColorKernel(source: """
        kernel vec4 pixelrollHaze(__sample image, __sample dark, float amount) {
            vec4 p = unpremultiply(image);
            vec3 air = vec3(0.95);
            if (amount < 0.0) { return premultiply(vec4(mix(p.rgb, air, -amount * 0.35), p.a)); }
            float transmission = clamp(1.0 - amount * 0.75 * dark.r / 0.95, 0.35, 1.0);
            return premultiply(vec4(clamp((p.rgb-air)/transmission+air, 0.0, 1.0), p.a));
        }
        """)!
    private static let channels = CIColorKernel(source: """
        kernel vec4 pixelrollChannels(__sample red, __sample original, __sample blue) {
            vec4 r = unpremultiply(red), g = unpremultiply(original), b = unpremultiply(blue);
            return premultiply(vec4(r.r, g.g, b.b, g.a));
        }
        """)!
    private static let distortion = CIWarpKernel(source: """
        kernel vec2 pixelrollDistortion(vec2 center, vec2 halfSize, float amount) {
            vec2 p = (destCoord()-center)/halfSize;
            float radius = dot(p,p)*0.5;
            float zoom = 1.0 + max(amount, 0.0);
            return center + p*halfSize*(1.0+amount*radius)/zoom;
        }
        """)!
    static func presence(_ input: CIImage, settings s: PhotoAdjustments) -> CIImage {
        var image = input
        let scale = max(input.extent.width, input.extent.height)/2560
        for (amount, radius, strength) in [(s.texture, 2.0, 0.75), (s.clarity, 28.0, 0.45)] where amount != 0 {
            let extent = image.extent
            if amount > 0 {
                image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": max(0.25, radius*scale), "inputIntensity": amount/100*strength]).cropped(to: extent)
            } else {
                let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(0.25, radius*scale)]).cropped(to: extent)
                let weight = -amount/100*strength
                let mask = CIImage(color: CIColor(red: weight, green: weight, blue: weight)).cropped(to: extent)
                image = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            }
        }
        if s.dehaze != 0 {
            // Local dark-channel transmission, with a neutral atmospheric-light assumption.
            let extent = image.extent
            let dark = image.clampedToExtent().applyingFilter("CIMinimumComponent")
                .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": max(1, 10*scale)])
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(1, 8*scale)]).cropped(to: extent)
            image = haze.apply(extent: extent, arguments: [image, dark, s.dehaze/100]) ?? CIImage.empty()
        }
        return image
    }
    static func lens(_ input: CIImage, settings s: PhotoAdjustments) -> CIImage {
        var image = input
        let extent = input.extent, center = CIVector(x: extent.midX, y: extent.midY)
        if s.distortion != 0 {
            let clamped = image.clampedToExtent()
            image = distortion.apply(extent: extent, roiCallback: { _, _ in extent }, image: clamped,
                arguments: [center, CIVector(x: extent.width/2, y: extent.height/2), s.distortion/100*0.15]) ?? CIImage.empty()
        }
        if s.redFringe != 0 || s.blueFringe != 0 {
            func shifted(_ amount: Double) -> CIImage {
                let scale = 1+amount/2000
                let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                    .scaledBy(x: scale, y: scale).translatedBy(x: -extent.midX, y: -extent.midY)
                return image.clampedToExtent().transformed(by: transform).cropped(to: extent)
            }
            image = channels.apply(extent: extent, arguments: [shifted(s.redFringe), image, shifted(s.blueFringe)]) ?? CIImage.empty()
        }
        if s.vignette != 0 {
            // Exposure compensation grows smoothly from zero in the center to the edge.
            let amount = abs(s.vignette)/100
            let exposed = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": s.vignette/100*2])
            let mask = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": center,
                "inputRadius0": min(extent.width, extent.height)*0.15,
                "inputRadius1": hypot(extent.width, extent.height)*0.5,
                "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!.cropped(to: extent)
            // Amount is already represented by exposure; mask supplies only the spatial falloff.
            if amount > 0 { image = exposed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]) }
        }
        return image.cropped(to: extent)
    }
}
