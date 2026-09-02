import AppKit
import CoreGraphics

/// 스프라이트 위에 덧입히는 상태 스킨.
///
/// 왜 필요한가: 리아코 시트에는 졸음(`idle`)·얼음(`waiting`) 스킨이 **정면 포즈에만** 구워져 있다.
/// 뒷모습 행(`waving`)은 정상 색 한 벌뿐이라, 졸거나 얼어 있는 펫에 마우스를 올려 돌아세우면
/// 갑자기 멀쩡해 보인다. 그래서 시트를 다시 굽는 대신, 구울 때 쓴 것과 **같은 파라미터**를
/// 런타임에 적용해 없는 조합을 만들어 낸다.
///
/// 수치는 connor-pet `scripts/build_sheet.py` 에서 그대로 가져왔다 —
/// 졸음 `desaturate(0.4, 0.62)` + 떠오르는 "Zzz", 얼음 `tint(desaturate(0.35, 1.1), (170,215,250), 0.6)`
/// + 각진 얼음 결정. 구워진 행과 나란히 놓아도 튀지 않게 하려는 것이다.
enum PetSkin: String {
    case none
    case sleep
    case freeze
}

enum PetSkinRenderer {
    /// `skin` 을 입힌 프레임을 만든다. `frameIndex` 는 Zzz 표류·얼음 반짝임의 위상에 쓴다.
    static func apply(_ skin: PetSkin, to source: CGImage, frameIndex: Int) -> CGImage {
        switch skin {
        case .none:
            return source
        case .sleep:
            let base = recolor(source) { r, g, b in
                let (dr, dg, db) = desaturate(r, g, b, saturation: 0.4, brightness: 0.62)
                return (dr, dg, db)
            }
            return overlay(on: base) { ctx, size in
                drawZzz(ctx: ctx, size: size, frameIndex: frameIndex)
            }
        case .freeze:
            let base = recolor(source) { r, g, b in
                let (dr, dg, db) = desaturate(r, g, b, saturation: 0.35, brightness: 1.1)
                return tint(dr, dg, db, toward: (170.0 / 255, 215.0 / 255, 250.0 / 255), strength: 0.6)
            }
            // 구워진 얼음 행과 같은 반짝임 위상.
            let shimmer = [0.85, 1.0, 1.0, 0.85][frameIndex % 4]
            return overlay(on: base) { ctx, size in
                drawIceCrystal(ctx: ctx, size: size, shimmer: shimmer)
            }
        }
    }

    // MARK: - 색 변환

    /// Pillow `ImageEnhance.Color` 와 같은 ITU-R 601-2 휘도 기준으로 채도를 낮추고,
    /// `ImageEnhance.Brightness` 와 같이 밝기를 **곱한다** (더하는 게 아니다).
    private static func desaturate(
        _ r: Double, _ g: Double, _ b: Double,
        saturation: Double, brightness: Double
    ) -> (Double, Double, Double) {
        let luma = r * 0.299 + g * 0.587 + b * 0.114
        return (
            ((luma + (r - luma) * saturation) * brightness),
            ((luma + (g - luma) * saturation) * brightness),
            ((luma + (b - luma) * saturation) * brightness)
        )
    }

    /// Pillow `Image.blend` 와 같은 선형 보간.
    private static func tint(
        _ r: Double, _ g: Double, _ b: Double,
        toward color: (Double, Double, Double), strength: Double
    ) -> (Double, Double, Double) {
        (
            r + (color.0 - r) * strength,
            g + (color.1 - g) * strength,
            b + (color.2 - b) * strength
        )
    }

    /// 픽셀별 색 변환. 알파는 건드리지 않는다.
    ///
    /// premultiplied 버퍼라 곱해진 색을 그대로 계산하면 반투명 가장자리가 어긋난다 —
    /// 알파로 나눠 원래 색을 복원하고, 변환한 뒤 다시 곱한다.
    private static func recolor(
        _ source: CGImage,
        transform: (Double, Double, Double) -> (Double, Double, Double)
    ) -> CGImage {
        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return source }

        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        for index in stride(from: 0, to: buffer.count, by: 4) {
            let alpha = Double(buffer[index + 3]) / 255
            guard alpha > 0 else { continue }

            let r = Double(buffer[index]) / 255 / alpha
            let g = Double(buffer[index + 1]) / 255 / alpha
            let b = Double(buffer[index + 2]) / 255 / alpha
            let (nr, ng, nb) = transform(r, g, b)

            buffer[index] = clampByte(nr * alpha)
            buffer[index + 1] = clampByte(ng * alpha)
            buffer[index + 2] = clampByte(nb * alpha)
        }
        return ctx.makeImage() ?? source
    }

    private static func clampByte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    // MARK: - 오버레이

    /// 색만 바꾼 프레임 위에 그림을 얹는다. 좌표계는 y-up 이므로,
    /// build_sheet.py 의 위에서 아래로 재는 좌표는 `size.height - y` 로 뒤집어 쓴다.
    ///
    /// 그림은 **투명한 별도 레이어에 `.copy` 로** 그린 뒤 한 번만 합성한다. Pillow 의
    /// `ImageDraw` 는 도형을 오버레이에 덮어쓰고 마지막에 `alpha_composite` 를 한 번 하는데,
    /// 그대로 겹쳐 그리면 반투명 도형끼리 알파가 누적돼 구워진 행보다 훨씬 불투명해진다
    /// (얼음 결정 안의 리아코가 안 보일 정도로).
    private static func overlay(
        on base: CGImage,
        draw: (CGContext, CGSize) -> Void
    ) -> CGImage {
        let width = base.width
        let height = base.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let size = CGSize(width: width, height: height)

        func makeContext() -> CGContext? {
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }

        guard let layer = makeContext(), let output = makeContext() else { return base }

        layer.setBlendMode(.copy)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: layer, flipped: false)
        draw(layer, size)
        NSGraphicsContext.current = previous

        output.draw(base, in: rect)
        if let drawn = layer.makeImage() {
            output.draw(drawn, in: rect)
        }
        return output.makeImage() ?? base
    }

    /// 졸음 스킨의 떠오르는 "Zzz". 프레임마다 오른쪽 위로 흘러가며 사라진다.
    private static func drawZzz(ctx: CGContext, size: CGSize, frameIndex: Int) {
        let index = frameIndex % 4
        let alphas: [CGFloat] = [0, 210.0 / 255, 130.0 / 255, 0]
        let alpha = alphas[index]
        guard alpha > 0 else { return }

        let dx: [CGFloat] = [0, 4, 12, 20]
        let dy: [CGFloat] = [8, -2, -14, -26]
        // 원본 시트가 200px 프레임 기준으로 22pt 를 썼다 — 다른 크기의 시트로 바뀌어도 비율을 지킨다.
        let fontSize = size.height * (22.0 / 200.0)
        let text = NSAttributedString(string: "Zzz", attributes: [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor(red: 210 / 255, green: 230 / 255, blue: 1, alpha: alpha)
        ])

        let bounds = text.size()
        let topDownY = size.height * 0.10 + dy[index]
        text.draw(at: NSPoint(
            x: size.width * 0.62 + dx[index],
            y: size.height - topDownY - bounds.height
        ))
    }

    /// 얼음 스킨의 각진 결정 — 둥근 거품이 아니라 다면체 + 삐져나온 조각 셋.
    private static func drawIceCrystal(ctx: CGContext, size: CGSize, shimmer: Double) {
        let inset = size.width * (25.0 / 200.0)
        let x0 = inset
        let y0 = inset
        let x1 = size.width - inset
        let y1 = size.height - inset
        let w = x1 - x0
        let h = y1 - y0

        // build_sheet.py 의 위에서 아래로 재는 좌표를 y-up 으로 뒤집는다.
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: x0 + fx * w, y: size.height - (y0 + fy * h))
        }

        func fill(_ points: [CGPoint], _ color: NSColor) {
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            path.close()
            color.setFill()
            path.fill()
        }

        let body = [
            pt(0.50, 0.02), pt(0.78, 0.14), pt(1.00, 0.40), pt(0.92, 0.74),
            pt(0.68, 0.98), pt(0.32, 0.94), pt(0.04, 0.68), pt(0.10, 0.30)
        ]
        fill(body, NSColor(red: 150 / 255, green: 205 / 255, blue: 245 / 255, alpha: 130 / 255 * shimmer))

        let outline = NSBezierPath()
        outline.move(to: body[0])
        for point in body.dropFirst() { outline.line(to: point) }
        outline.close()
        outline.lineWidth = size.width * (3.0 / 200.0)
        NSColor(red: 230 / 255, green: 248 / 255, blue: 1, alpha: 235 / 255).setStroke()
        outline.stroke()

        fill(
            [pt(0.50, 0.02), pt(0.78, 0.14), pt(0.50, 0.46), pt(0.10, 0.30)],
            NSColor(white: 1, alpha: 120 / 255 * shimmer)
        )
        fill(
            [pt(0.68, 0.98), pt(0.92, 0.74), pt(0.50, 0.46), pt(0.32, 0.94)],
            NSColor(red: 30 / 255, green: 80 / 255, blue: 150 / 255, alpha: 100 / 255 * shimmer)
        )

        // 결정 밖으로 삐져나온 조각 — 위, 오른쪽, 아래.
        let unit = size.width / 200.0
        let shards: [[CGPoint]] = [
            [
                CGPoint(x: x0 + 0.10 * w, y: size.height - (y0 - 4 * unit)),
                CGPoint(x: x0 + 0.30 * w, y: size.height - (y0 - 4 * unit)),
                CGPoint(x: x0 + 0.20 * w, y: size.height - (y0 - 22 * unit))
            ],
            [
                CGPoint(x: x1 + 4 * unit, y: size.height - (y0 + 0.28 * h)),
                CGPoint(x: x1 + 4 * unit, y: size.height - (y0 + 0.46 * h)),
                CGPoint(x: x1 + 20 * unit, y: size.height - (y0 + 0.36 * h))
            ],
            [
                CGPoint(x: x0 + 0.28 * w, y: size.height - (y1 + 4 * unit)),
                CGPoint(x: x0 + 0.46 * w, y: size.height - (y1 + 4 * unit)),
                CGPoint(x: x0 + 0.36 * w, y: size.height - (y1 + 20 * unit))
            ]
        ]
        for shard in shards {
            fill(shard, NSColor(red: 220 / 255, green: 240 / 255, blue: 1, alpha: 160 / 255 * shimmer))
            let edge = NSBezierPath()
            edge.move(to: shard[0])
            for point in shard.dropFirst() { edge.line(to: point) }
            edge.close()
            edge.lineWidth = size.width * (2.0 / 200.0)
            NSColor(red: 235 / 255, green: 250 / 255, blue: 1, alpha: 220 / 255).setStroke()
            edge.stroke()
        }
    }
}
