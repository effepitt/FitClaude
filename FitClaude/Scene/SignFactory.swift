import UIKit

/// Disegna i "nizioleti", le scritte bianche con cornice nera dipinte sui muri di Venezia.
/// Claude li usa come cartelli: titolo e testo breve, con una fascia colorata per lo stile.
enum SignFactory {
    enum Style: String {
        case info, goal, warning, street, arrow

        var bandColor: UIColor? {
            switch self {
            case .info: return UIColor(red: 0.16, green: 0.36, blue: 0.62, alpha: 1)
            case .goal: return UIColor(red: 0.20, green: 0.50, blue: 0.30, alpha: 1)
            case .warning: return UIColor(red: 0.78, green: 0.32, blue: 0.12, alpha: 1)
            case .street, .arrow: return nil
            }
        }
    }

    /// Restituisce l'immagine e il rapporto larghezza/altezza.
    static func image(title: String, text: String, style: Style) -> (UIImage, CGFloat) {
        let width: CGFloat = 1024
        let padding: CGFloat = 48
        let titleFont = UIFont(name: "Georgia-Bold", size: style == .street ? 96 : 72) ?? .boldSystemFont(ofSize: 72)
        let textFont = UIFont(name: "Georgia", size: 54) ?? .systemFont(ofSize: 54)
        let black = UIColor(white: 0.08, alpha: 1)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: black, .paragraphStyle: paragraph]
        let textAttrs: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: black, .paragraphStyle: paragraph]

        let inner = width - padding * 2 - 24
        let titleText = title.uppercased()
        let titleRect = (titleText as NSString).boundingRect(with: CGSize(width: inner, height: 1000), options: .usesLineFragmentOrigin, attributes: titleAttrs, context: nil)
        let bodyRect = text.isEmpty ? .zero : (text as NSString).boundingRect(with: CGSize(width: inner, height: 2000), options: .usesLineFragmentOrigin, attributes: textAttrs, context: nil)
        let bandHeight: CGFloat = style.bandColor == nil ? 0 : 24
        let height = ceil(padding * 2 + 24 + bandHeight + titleRect.height + (text.isEmpty ? 0 : 24 + bodyRect.height))

        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            // Intonaco bianco con bordi leggermente consumati
            UIColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            // Cornice nera dipinta
            black.setStroke()
            g.setLineWidth(14)
            g.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18))
            var y = padding + 12
            if let band = style.bandColor {
                band.setFill()
                g.fill(CGRect(x: 32, y: 32, width: width - 64, height: bandHeight))
                y += bandHeight
            }
            (titleText as NSString).draw(with: CGRect(x: padding + 12, y: y, width: inner, height: titleRect.height + 4), options: .usesLineFragmentOrigin, attributes: titleAttrs, context: nil)
            y += titleRect.height + 24
            if !text.isEmpty {
                (text as NSString).draw(with: CGRect(x: padding + 12, y: y, width: inner, height: bodyRect.height + 4), options: .usesLineFragmentOrigin, attributes: textAttrs, context: nil)
            }
        }
        return (image, width / height)
    }

    /// Nomi in stile veneziano per i nizioleti lungo il percorso.
    static let streetNames = [
        "Calle del Forno", "Calle Larga", "Ramo Primo", "Calle dei Fabbri", "Fondamenta dei Mori",
        "Rio Terà", "Calle de la Madonna", "Campiello del Remer", "Sotoportego de le Acque",
        "Calle del Pistor", "Fondamenta del Vin", "Calle dei Botteri", "Corte Nova", "Calle del Squero",
        "Fondamenta de la Misericordia", "Calle dei Preti", "Campiello dei Squelini", "Calle de la Malvasia",
    ]
}
