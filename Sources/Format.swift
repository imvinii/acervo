// Formatação de tamanhos, datas e durações.

import Foundation

enum AppInfo {
    static let name = "Acervo"
}

enum Fmt {
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Lang.locale; f.setLocalizedDateFormatFromTemplate("d MMM yyyy"); return f
    }()
    static let month: DateFormatter = {
        let f = DateFormatter(); f.locale = Lang.locale; f.dateFormat = "LLL"; return f
    }()
    /// "OUT 2026" (cabe na coluna da data)
    static func monthYear(_ d: Date) -> String {
        "\(month.string(from: d).trimmingCharacters(in: CharacterSet(charactersIn: "."))) \(Calendar.current.component(.year, from: d))"
    }
    static func duration(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60, sec = Int(s) % 60
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return m > 0 ? "\(m) min \(sec) s" : "\(sec) s"
    }
    static func files(_ n: Int) -> String { n == 1 ? L("1 arquivo") : L("{0} arquivos", n) }
}

