import CoreGraphics
import Foundation

struct NotchWheelGesture {
    enum Route { case pages, songs, native }
    enum Action: Equatable {
        case forward, consume, selectPage(Int), changeTrack(Int)
    }

    struct Movement {
        let dx: CGFloat
        let dy: CGFloat
        let timestamp: TimeInterval
        let startsGesture: Bool
        let isUnphased: Bool
        let isMomentum: Bool
        let isPrecise: Bool
    }

    private var route: Route?
    private var distance: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0
    private var handled = false

    mutating func handle(_ movement: Movement, routeFor: (Bool) -> Route) -> Action {
        if movement.isMomentum {
            return route == .pages || route == .songs ? .consume : .forward
        }
        if movement.startsGesture || (movement.isUnphased && movement.timestamp - lastTimestamp > 0.20) {
            route = nil
            distance = 0
            handled = false
        }
        lastTimestamp = movement.timestamp

        if route == nil, movement.dx != 0 || movement.dy != 0 {
            route = routeFor(abs(movement.dx) > abs(movement.dy))
        }
        guard let route, route != .native else { return .forward }
        distance += route == .songs ? movement.dx : movement.dy
        let threshold: CGFloat = movement.isPrecise ? 28 : 1
        guard !handled, abs(distance) >= threshold else { return .consume }
        handled = true

        if route == .songs {
            return .changeTrack(distance > 0 ? 1 : -1)
        }
        return .selectPage(distance < 0 ? 1 : -1)
    }
}
