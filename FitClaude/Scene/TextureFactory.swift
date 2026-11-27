import UIKit

/// Texture generate via codice: facciate veneziane, masegni, mattoni, acqua.
/// Nessuna immagine esterna da scaricare.
enum TextureFactory {
    /// Colori tipici degli intonaci veneziani.
    static let plasterColors: [UIColor] = [
        UIColor(red: 0.80, green: 0.42, blue: 0.30, alpha: 1), // rosso veneziano
        UIColor(red: 0.89, green: 0.66, blue: 0.40, alpha: 1), // ocra
        UIColor(red: 0.91, green: 0.72, blue: 0.64, alpha: 1), // rosa salmone
        UIColor(red: 0.93, green: 0.86, blue: 0.72, alpha: 1), // crema
        UIColor(red: 0.70, green: 0.33, blue: 0.25, alpha: 1), // mattone bruciato
        UIColor(red: 0.95, green: 0.78, blue: 0.52, alpha: 1), // giallo pastello
        UIColor(red: 0.84, green: 0.56, blue: 0.48, alpha: 1), // terracotta chiara
    ]

    private static var cache: [String: UIImage] = [:]

    private static func cached(_ key: String, _ make: () -> UIImage) -> UIImage {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }

    /// Facciata: intonaco con macchie, finestre con cornici in pietra d'Istria, scuri verdi, portone.
    static func facade(colorIndex: Int, columns: Int, floors: Int, shutters: Bool) -> UIImage {
        let key = "facade-\(colorIndex)-\(columns)-\(floors)-\(shutters)"
        return cached(key) {
            let size = CGSize(width: 512, height: 1024)
            let base = plasterColors[colorIndex % plasterColors.count]
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                base.setFill()
                g.fill(CGRect(origin: .zero, size: size))

                // Macchie di umidità e intonaco scrostato
                var rng = SeededRandom(seed: UInt64(colorIndex * 31 + columns * 7 + floors))
                for _ in 0..<60 {
                    let r = CGFloat(rng.next(in: 10...70))
                    let rect = CGRect(x: CGFloat(rng.next(in: 0...512)) - r / 2, y: CGFloat(rng.next(in: 0...1024)) - r / 2, width: r, height: r * 0.7)
                    UIColor(white: rng.next(in: 0...1) > 0.5 ? 1 : 0, alpha: 0.05).setFill()
                    g.fillEllipse(in: rect)
                }
                // Zoccolo umido in basso
                UIColor(white: 0.25, alpha: 0.25).setFill()
                g.fill(CGRect(x: 0, y: size.height - 70, width: size.width, height: 70))

                // Finestre
                let stone = UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1)
                let glass = UIColor(red: 0.12, green: 0.14, blue: 0.16, alpha: 1)
                let green = UIColor(red: 0.20, green: 0.38, blue: 0.27, alpha: 1)
                let colWidth = size.width / CGFloat(columns)
                let floorHeight = (size.height - 200) / CGFloat(floors)
                for floor in 0..<floors {
                    for col in 0..<columns {
                        let w = colWidth * 0.42, h = floorHeight * 0.55
                        let x = CGFloat(col) * colWidth + (colWidth - w) / 2
                        let y = 40 + CGFloat(floor) * floorHeight + (floorHeight - h) / 2
                        let frame = CGRect(x: x - 8, y: y - 10, width: w + 16, height: h + 18)
                        stone.setFill()
                        // arco gotico/tondo in cima
                        let path = UIBezierPath(roundedRect: frame, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: w / 2, height: w / 2))
                        path.fill()
                        glass.setFill()
                        UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: w / 2.4, height: w / 2.4)).fill()
                        if shutters && (floor + col) % 3 != 0 {
                            green.setFill()
                            g.fill(CGRect(x: x - w * 0.45 - 8, y: y, width: w * 0.45, height: h))
                            g.fill(CGRect(x: x + w + 8, y: y, width: w * 0.45, height: h))
                        }
                    }
                }
                // Portone al piano terra
                let doorW: CGFloat = 120, doorH: CGFloat = 170
                let door = CGRect(x: (size.width - doorW) / 2, y: size.height - doorH, width: doorW, height: doorH)
                stone.setFill()
                UIBezierPath(roundedRect: door.insetBy(dx: -10, dy: -10), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 70, height: 70)).fill()
                UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1).setFill()
                UIBezierPath(roundedRect: door, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 60, height: 60)).fill()
                // Cornicione
                stone.setFill()
                g.fill(CGRect(x: 0, y: 0, width: size.width, height: 18))
            }
        }
    }

    /// Masegni: lastre di trachite grigia posate a correre.
    static func paving() -> UIImage {
        cached("paving") {
            let size = CGSize(width: 512, height: 512)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                UIColor(white: 0.22, alpha: 1).setFill()
                g.fill(CGRect(origin: .zero, size: size))
                var rng = SeededRandom(seed: 42)
                let rowH: CGFloat = 64
                var y: CGFloat = 0
                var row = 0
                while y < size.height {
                    var x: CGFloat = row % 2 == 0 ? 0 : -60
                    while x < size.width {
                        let w = CGFloat(rng.next(in: 90...150))
                        UIColor(white: CGFloat(rng.next(in: 0.38...0.50)), alpha: 1).setFill()
                        g.fill(CGRect(x: x + 3, y: y + 3, width: w - 6, height: rowH - 6))
                        x += w
                    }
                    y += rowH
                    row += 1
                }
            }
        }
    }

    static func bricks() -> UIImage {
        cached("bricks") {
            let size = CGSize(width: 256, height: 256)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                UIColor(red: 0.78, green: 0.74, blue: 0.68, alpha: 1).setFill()
                g.fill(CGRect(origin: .zero, size: size))
                var rng = SeededRandom(seed: 7)
                for row in 0..<16 {
                    let offset: CGFloat = row % 2 == 0 ? 0 : 16
                    for col in -1..<9 {
                        let r = CGFloat(rng.next(in: 0.55...0.72))
                        UIColor(red: r, green: r * 0.45, blue: r * 0.32, alpha: 1).setFill()
                        g.fill(CGRect(x: CGFloat(col) * 32 + offset + 1, y: CGFloat(row) * 16 + 1, width: 30, height: 14))
                    }
                }
            }
        }
    }

    static func roofTiles() -> UIImage {
        cached("roof") {
            let size = CGSize(width: 128, height: 128)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor(red: 0.62, green: 0.30, blue: 0.20, alpha: 1).setFill()
                ctx.cgContext.fill(CGRect(origin: .zero, size: size))
                UIColor(red: 0.45, green: 0.20, blue: 0.14, alpha: 1).setFill()
                for i in 0..<8 { ctx.cgContext.fill(CGRect(x: 0, y: CGFloat(i) * 16, width: 128, height: 3)) }
            }
        }
    }

    /// Acqua della laguna: verde-azzurro con increspature.
    static func water() -> UIImage {
        cached("water") {
            let size = CGSize(width: 512, height: 512)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let g = ctx.cgContext
                UIColor(red: 0.13, green: 0.33, blue: 0.32, alpha: 1).setFill()
                g.fill(CGRect(origin: .zero, size: size))
                var rng = SeededRandom(seed: 99)
                for _ in 0..<500 {
                    let w = CGFloat(rng.next(in: 20...80))
                    let rect = CGRect(x: CGFloat(rng.next(in: 0...512)), y: CGFloat(rng.next(in: 0...512)), width: w, height: 3)
                    UIColor(red: 0.55, green: 0.75, blue: 0.72, alpha: CGFloat(rng.next(in: 0.08...0.25))).setFill()
                    g.fillEllipse(in: rect)
                }
            }
        }
    }
}

/// Generatore pseudo-casuale riproducibile: la stessa sezione di percorso viene sempre uguale.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 1 }

    mutating func nextUInt() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt() % 1_000_000) / 1_000_000
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        Int(nextUInt() % UInt64(max(upperBound, 1)))
    }
}
