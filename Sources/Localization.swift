// Idiomas: o app segue o idioma do sistema (ou o escolhido para ele em
// Ajustes do Sistema > Geral > Idioma e Região > Apps). Português, inglês e espanhol;
// qualquer outro idioma usa o inglês.
//
// Os textos são escritos em português no código: L("…") procura a tradução
// em Translations.table. {0}, {1}… são trocados pelos valores passados.

import Foundation

enum Lang: String {
    case pt, en, es

    static let current: Lang = {
        let first = (Bundle.main.preferredLocalizations + Locale.preferredLanguages).first?.lowercased() ?? "en"
        if first.hasPrefix("pt") { return .pt }
        if first.hasPrefix("es") { return .es }
        return .en
    }()

    static var locale: Locale {
        switch current {
        case .pt: Locale(identifier: "pt_BR")
        case .en: Locale(identifier: "en_US")
        case .es: Locale(identifier: "es_ES")
        }
    }

    static func pick(pt: String, en: String, es: String) -> String {
        switch current { case .pt: pt; case .en: en; case .es: es }
    }
}

func L(_ key: String, _ args: Any...) -> String {
    var s = key
    if Lang.current != .pt, let t = Translations.table[key] {
        s = Lang.current == .en ? t.0 : t.1
    }
    for (i, a) in args.enumerated() {
        s = s.replacingOccurrences(of: "{\(i)}", with: "\(a)")
    }
    return s
}
