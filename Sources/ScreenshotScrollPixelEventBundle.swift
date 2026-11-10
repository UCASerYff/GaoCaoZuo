import CoreGraphics

/// Memory-only construction of one wheel. The caller owns source/pointer validation and the sole post.
struct ScreenshotScrollPixelEventBundle {
    let wheel: CGEvent

    init?(anchor: CGPoint, pixels: Int32) {
        guard anchor.x.isFinite, anchor.y.isFinite,
              pixels >= 1, pixels <= 240,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -pixels, wheel2: 0, wheel3: 0) else { return nil }
        wheel.location = anchor
        wheel.flags = []
        guard wheel.type == .scrollWheel, wheel.location == anchor, wheel.flags.isEmpty,
              wheel.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
              wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -Int64(pixels),
              wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0,
              wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) == 0 else { return nil }
        self.wheel = wheel
    }
}
