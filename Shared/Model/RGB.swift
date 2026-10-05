//
//  RGB.swift
//  Tournesol
//
//  Created by Constantin Clerc on 05.10.2026.
//

import SwiftUI

nonisolated struct RGB: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let sunflower = RGB(red: 0.93, green: 0.62, blue: 0.13)

    var color: Color { Color(red: red, green: green, blue: blue) }

    func scaled(_ factor: Double) -> RGB {
        RGB(red: red * factor, green: green * factor, blue: blue * factor)
    }

    func normalized() -> RGB {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            switch maxC {
            case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            case green: hue = (blue - red) / delta + 2
            default: hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC == 0 ? 0 : min(1, delta / maxC * 1.25)
        return RGB(hue: hue, saturation: saturation, brightness: min(max(maxC, 0.4), 0.78))
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hue: Double, saturation s: Double, brightness v: Double) {
        let sector = (hue * 6).rounded(.down)
        let f = hue * 6 - sector
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(sector) % 6 {
        case 0: (red, green, blue) = (v, t, p)
        case 1: (red, green, blue) = (q, v, p)
        case 2: (red, green, blue) = (p, v, t)
        case 3: (red, green, blue) = (p, q, v)
        case 4: (red, green, blue) = (t, p, v)
        default: (red, green, blue) = (v, p, q)
        }
    }
}
