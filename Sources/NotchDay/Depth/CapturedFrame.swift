import CoreVideo
import Metal

/// A captured texture whose Core Video owner keeps the pixel buffer from being
/// recycled while the GPU is still reading it.
///
/// Ported from Mac-Duo, Apache License 2.0.
struct CapturedFrame: @unchecked Sendable {
    let texture: MTLTexture
    private let owner: CVMetalTexture

    init?(_ owner: CVMetalTexture) {
        guard let texture = CVMetalTextureGetTexture(owner) else { return nil }
        self.texture = texture
        self.owner = owner
    }
}
