import Combine
import Foundation

/// Settings for the depth effect, backed by `UserDefaults`.
///
/// Every key is namespaced, so the effect can be removed without disturbing
/// the rest of NotchDay's stored state.
///
/// Ported from Mac-Duo's `Preferences`, Apache License 2.0.
@MainActor
final class DepthPreferences: ObservableObject {
    static let shared = DepthPreferences()

    private enum Key {
        static let isEnabled = "depth.isEnabled"
        static let isOpeningEnabled = "depth.isOpeningEnabled"
        static let isTimeoutEnabled = "depth.isTimeoutEnabled"
        static let thresholdAngle = "depth.thresholdAngle"
        static let blurSpan = "depth.blurSpan"
        static let maxBlurRadius = "depth.maxBlurRadius"
        static let maxDim = "depth.maxDim"
        static let viewingDistance = "depth.viewingDistance"
        static let recession = "depth.recession"
        static let blurEvenness = "depth.blurEvenness"
        static let dimReach = "depth.dimReach"
        static let isLivePicture = "depth.isLivePicture"

        static let all = [
            isEnabled, isOpeningEnabled, isTimeoutEnabled, thresholdAngle, blurSpan, maxBlurRadius,
            maxDim, viewingDistance, recession, blurEvenness, dimReach, isLivePicture,
        ]
    }

    private static let factory: [String: Any] = [
        Key.isEnabled: true,
        Key.isOpeningEnabled: true,
        Key.isTimeoutEnabled: false,
        Key.thresholdAngle: 90.0,
        Key.blurSpan: 60.0,
        Key.maxBlurRadius: 135.0,
        Key.maxDim: 1.0,
        Key.viewingDistance: 6.0,
        Key.recession: 1.0,
        Key.blurEvenness: 0.0,
        Key.dimReach: 0.5,
        Key.isLivePicture: true,
    ]

    /// Master switch for the depth effect.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    @Published var isOpeningEnabled: Bool {
        didSet { defaults.set(isOpeningEnabled, forKey: Key.isOpeningEnabled) }
    }

    /// Ends the effect early if the angle holds still while below the
    /// threshold, instead of waiting for the lid to open back past it.
    @Published var isTimeoutEnabled: Bool {
        didSet { defaults.set(isTimeoutEnabled, forKey: Key.isTimeoutEnabled) }
    }

    /// Closing past this angle starts the depth effect. Degrees.
    @Published var thresholdAngle: Double {
        didSet { defaults.set(thresholdAngle, forKey: Key.thresholdAngle) }
    }

    /// How many degrees below the threshold the blur takes to reach maximum.
    @Published var blurSpan: Double {
        didSet { defaults.set(blurSpan, forKey: Key.blurSpan) }
    }

    /// Gaussian blur radius at full effect, in points.
    @Published var maxBlurRadius: Double {
        didSet { defaults.set(maxBlurRadius, forKey: Key.maxBlurRadius) }
    }

    /// Black overlay opacity where the blur is at full strength, 0...1.
    @Published var maxDim: Double {
        didSet { defaults.set(maxDim, forKey: Key.maxDim) }
    }

    /// Distance from the eye to the middle of the screen, as a multiple of
    /// the screen height.
    @Published var viewingDistance: Double {
        didSet { defaults.set(viewingDistance, forKey: Key.viewingDistance) }
    }

    /// Degrees the picture turns away from the glass for each degree the lid
    /// closes. One holds the picture still in the room.
    @Published var recession: Double {
        didSet { defaults.set(recession, forKey: Key.recession) }
    }

    /// Blur at the hinge edge as a fraction of the blur at the far edge. One
    /// blurs the whole picture by the same amount.
    @Published var blurEvenness: Double {
        didSet { defaults.set(blurEvenness, forKey: Key.blurEvenness) }
    }

    /// Height at which the dimming reaches full strength, as a fraction of
    /// the screen height.
    @Published var dimReach: Double {
        didSet { defaults.set(dimReach, forKey: Key.dimReach) }
    }

    /// Keep the picture under the effect updating, instead of holding the one
    /// frame that was on screen at the trigger angle.
    @Published var isLivePicture: Bool {
        didSet { defaults.set(isLivePicture, forKey: Key.isLivePicture) }
    }

    /// Eye distance in screen heights, at the two ends of the perspective
    /// slider. The panel offers the strength, which runs the other way.
    static let farthestEye: Double = 6
    static let nearestEye: Double = 1
    static let eyeRange: Double = farthestEye - nearestEye

    /// Highest angle above the threshold at which the pre-warm may run.
    let prewarmCeiling: Double = 25

    /// Closing speed in degrees per second that starts the pre-warm.
    let closingSpeed: Double = 8

    /// How long the pre-warm runs after the lid stops moving.
    let prewarmLinger: TimeInterval = 0.75

    /// Seconds between pre-warm screenshots.
    let prewarmInterval: TimeInterval = 0.25

    /// Degrees above the threshold before the overlay is released.
    let hysteresis: Double = 4

    private let defaults = UserDefaults.standard

    // No inline values on purpose. Swift skips property observers for the
    // assignment that initialises a property.
    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.factory)
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isOpeningEnabled = defaults.bool(forKey: Key.isOpeningEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
    }

    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isOpeningEnabled = defaults.bool(forKey: Key.isOpeningEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
    }

    var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: viewingDistance,
            recession: recession,
            blurEvenness: blurEvenness,
            dimReach: dimReach,
            maxBlurRadius: maxBlurRadius,
            maxDim: maxDim
        )
    }
}
