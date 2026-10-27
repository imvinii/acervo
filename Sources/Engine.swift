// Motor do app: lista as captações, lê o cartão e copia com verificação.
// Nada aqui apaga, move ou renomeia arquivo do cartão: ele só é lido
// (a não ser na limpeza pedida no fim, que confere cada arquivo antes de apagar).

import Foundation
import CryptoKit

// MARK: - Tipos de arquivo (modelos para o que cada subpasta recebe)

enum FileType: String, CaseIterable, Sendable {
    case videos, raw, jpg, audios, documentos, design

    var name: String {
        switch self {
        case .videos: L("Vídeos")
        case .raw: L("Fotos RAW")
        case .jpg: L("Fotos JPG e HEIC")
        case .audios: L("Áudios")
        case .documentos: L("Documentos")
        case .design: L("Design (PSD, AI)")
        }
    }
    var extensions: [String] {
        switch self {
        case .videos: ["mp4", "mov", "mxf", "braw"]
        case .raw: ["cr2", "cr3", "arw", "nef", "raf", "rw2", "orf", "dng"]
        case .jpg: ["jpg", "jpeg", "heic"]
        case .audios: ["mp3", "wav"]
        case .documentos: ["pdf", "doc", "docx", "pages", "rtf", "odt"]
        case .design: ["psd", "psb", "ai"]
        }
    }
    var symbol: String {
        switch self {
        case .videos: "video.fill"
        case .raw, .jpg: "camera.fill"
        case .audios: "waveform"
        case .documentos: "doc.text.fill"
        case .design: "paintbrush.pointed.fill"
        }
    }
    static func matching(_ exts: [String]) -> FileType? {
        allCases.first { !Set($0.extensions).isDisjoint(with: exts) }
    }
}

// MARK: - Configuração (escolhida na primeira abertura, muda em Ajustes)

/// Subpasta criada em toda captação. Recebe os arquivos com as extensões listadas
/// (sem extensões = pasta vazia, ex.: Fotos/Seleção).
struct Subfolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var path: String
    var extensions: [String]
    /// Ícone escolhido pela pessoa (nil = automático, pelo tipo de arquivo).
    var icon: String?

    init(_ path: String, _ type: FileType?) {
        self.path = path
        self.extensions = type?.extensions ?? []
    }

    var receives: Bool { !extensions.isEmpty && !trimmedPath.isEmpty }
    var trimmedPath: String {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
    }
    var symbol: String { icon ?? FileType.matching(extensions)?.symbol ?? (extensions.isEmpty ? "folder" : "doc.fill") }

    /// Ícones que dá para escolher para uma subpasta (símbolo, nome).
    static var icons: [(String, String)] {[
        ("folder.fill", L("Pasta")), ("video.fill", L("Vídeo")), ("film.fill", L("Filme")),
        ("camera.fill", L("Câmera")), ("photo.fill", L("Foto")), ("waveform", L("Áudio")),
        ("mic.fill", L("Microfone")), ("music.note", L("Música")), ("doc.text.fill", L("Documento")),
        ("paintbrush.pointed.fill", L("Design")), ("cube.fill", L("3D")), ("text.bubble.fill", L("Legenda")),
        ("star.fill", L("Favoritos")), ("archivebox.fill", L("Arquivo")), ("airplane", L("Drone")),
        ("person.2.fill", L("Pessoas")),
    ]}
    var extensionsLabel: String { extensions.map { $0.uppercased() }.joined(separator: ", ") }
    /// Documentos só vêm marcados se a pessoa marcar; o resto já vem marcado.
    var onByDefault: Bool { !Set(extensions).isSubset(of: FileType.documentos.extensions) }

    /// "mp4, .MOV;wav" → ["mp4", "mov", "wav"]
    static func parse(_ text: String) -> [String] {
        var out: [String] = []
        for part in text.split(whereSeparator: { ", ;".contains($0) }) {
            let e = part.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            if !e.isEmpty && !out.contains(e) { out.append(e) }
        }
        return out
    }
}

/// Padrão de nome para os arquivos de uma subpasta.
struct NamingRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var folder: UUID
    var pattern: String
}

struct Config: Codable, Equatable, Sendable {
    /// Disco principal: a pasta onde ficam as captações.
    var inbox: String
    /// Discos de redundância: recebem uma cópia idêntica, com a mesma pasta e os mesmos nomes.
    var backups: [String]
    /// Nome da pasta de cada captação, ex.: "{AAAA}{MM}{DD} - {NOME}".
    var folderPattern: String
    var folders: [Subfolder]
    /// Desligado, os arquivos mantêm o nome que vieram do cartão.
    var rename: Bool
    var rules: [NamingRule]
    /// Discos que nunca aparecem na lista de cartões.
    var ignoredVolumes: [String]
    /// Com mais de um cartão: cada um numa subpasta com o nome dele (ex.: Vídeos/CAM A).
    var splitByCard = false
    /// Relatório em PDF de cada importação.
    var reportPDF = true
    /// Pasta dos relatórios ("" = junto do backup, na pasta da captação).
    var reportFolder = ""
    /// Registro ASC MHL (lista de checksums no padrão do mercado) dentro da pasta da captação.
    var mhl = true

    var inboxURL: URL { URL(fileURLWithPath: inbox) }
    var backupURLs: [URL] { backups.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) } }

    var receivingFolders: [Subfolder] { folders.filter(\.receives) }

    /// Subpasta que recebe um arquivo (a primeira da lista com essa extensão).
    func folder(for url: URL) -> Subfolder? {
        let ext = url.pathExtension.lowercased()
        return receivingFolders.first { $0.extensions.contains(ext) }
    }
    func folder(id: UUID) -> Subfolder? { folders.first { $0.id == id } }

    /// Com "Renomear" ligado, todo arquivo leva o nome da pasta da captação e um número.
    static let defaultFilePattern = "{PASTA} - {NNN}"

    /// Padrão de nome dos arquivos de uma subpasta: o próprio dela (se tiver) ou o padrão geral;
    /// nil = nome original (Renomear desligado).
    func pattern(for f: Subfolder) -> String? {
        guard rename else { return nil }
        let own = rules.first(where: { $0.folder == f.id })?.pattern.trimmingCharacters(in: .whitespaces) ?? ""
        return own.isEmpty ? Self.defaultFilePattern : own
    }

    /// Subpastas criadas numa captação nova.
    var captureFolders: [String] {
        var out: [String] = []
        for f in folders.map(\.trimmedPath) where !f.isEmpty && !out.contains(f) { out.append(f) }
        return out
    }

    /// Modelo para quem está começando (nomes no idioma do sistema).
    static var simple: Config {
        let v = Subfolder(L("Vídeos"), .videos), f = Subfolder(L("Fotos"), .raw)
        let a = Subfolder(L("Áudios"), .audios), d = Subfolder(L("Documentos"), .documentos)
        return Config(inbox: "", backups: [], folderPattern: "\(Tok.year){MM}{DD} - \(Tok.name)",
                      folders: [v, f, a, d], rename: false,
                      rules: [NamingRule(folder: d.id, pattern: "{ORIGINAL}")],
                      ignoredVolumes: [])
    }

    /// Padrão da Vértice (o mesmo dos atalhos "Criar projeto" e "Importar SD").
    static var vertice: Config {
        let v = Subfolder("Vídeos", .videos), f = Subfolder("Fotos/Brutas", .raw)
        let s = Subfolder("Fotos/Seleção", nil), a = Subfolder("Áudios", .audios)
        let d = Subfolder("Documentos", .documentos)
        return Config(inbox: "/Volumes/Mídias/Inbox", backups: ["/Volumes/Projetos/Inbox (BACKUP)"],
                      folderPattern: "{AAAA}{MM}{DD} - {NOME}",
                      folders: [v, f, s, a, d], rename: true,
                      // Vídeos e fotos seguem o padrão geral ({PASTA} - {NNN})
                      rules: [NamingRule(folder: a.id, pattern: "{PASTA}.{N}"),
                              NamingRule(folder: d.id, pattern: "{ORIGINAL}")],
                      ignoredVolumes: ["Elements"])
    }

    /// Sugestão da primeira abertura: o padrão da Vértice se os SSDs dela estiverem neste Mac.
    static var suggested: Config {
        FileManager.default.fileExists(atPath: "/Volumes/Mídias/Inbox") ? vertice : simple
    }

    enum CodingKeys: String, CodingKey {
        case inbox, backups, folderPattern, folders, rename, rules, ignoredVolumes, splitByCard, reportPDF, reportFolder, mhl
    }

    static let key = "config"
    static func load() -> Config? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: d)
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

extension Config {
    /// Lê configurações salvas por versões anteriores (sem os campos novos).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inbox = try c.decode(String.self, forKey: .inbox)
        backups = try c.decode([String].self, forKey: .backups)
        folderPattern = try c.decode(String.self, forKey: .folderPattern)
        folders = try c.decode([Subfolder].self, forKey: .folders)
        rename = try c.decode(Bool.self, forKey: .rename)
        rules = try c.decode([NamingRule].self, forKey: .rules)
        ignoredVolumes = try c.decode([String].self, forKey: .ignoredVolumes)
        splitByCard = try c.decodeIfPresent(Bool.self, forKey: .splitByCard) ?? false
        reportPDF = try c.decodeIfPresent(Bool.self, forKey: .reportPDF) ?? true
        reportFolder = try c.decodeIfPresent(String.self, forKey: .reportFolder) ?? ""
        mhl = try c.decodeIfPresent(Bool.self, forKey: .mhl) ?? true
    }
}

// MARK: - Discos conectados

struct Volume: Hashable, Identifiable, Sendable {
    let url: URL
    let name: String
    let free: Int64
    var id: URL { url }

    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard u.path == "/" || u.path.hasPrefix("/Volumes/"), let r = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return Volume(url: u, name: r.volumeName ?? u.lastPathComponent, free: Int64(r.volumeAvailableCapacityForImportantUsage ?? 0))
        }
    }

    /// Nome do disco onde está uma pasta ("Mídias", "Projetos"…).
    static func name(of url: URL) -> String {
        let c = url.pathComponents
        if c.count > 2, c[1] == "Volumes" { return c[2] }
        return (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }
}

// MARK: - Padrões de nome

/// Etiquetas aceitas nos três idiomas (o app grava e lê qualquer uma delas).
enum Tok {
    static let aliases: [String: String] = [
        "PASTA": "PASTA", "FOLDER": "PASTA", "CARPETA": "PASTA",
        "NOME": "NOME", "NAME": "NOME", "NOMBRE": "NOME",
        "AAAA": "AAAA", "YYYY": "AAAA", "AA": "AA", "YY": "AA",
        "MM": "MM", "DD": "DD", "ORIGINAL": "ORIGINAL",
    ]
    static func canonical(_ name: String) -> String? {
        if !name.isEmpty, name.allSatisfy({ $0 == "N" }) { return name }
        return aliases[name]
    }
    // Etiquetas mostradas no idioma do app
    static var folder: String { Lang.pick(pt: "{PASTA}", en: "{FOLDER}", es: "{CARPETA}") }
    static var name: String { Lang.pick(pt: "{NOME}", en: "{NAME}", es: "{NOMBRE}") }
    static var year: String { Lang.pick(pt: "{AAAA}", en: "{YYYY}", es: "{AAAA}") }
    static var shortYear: String { Lang.pick(pt: "{AA}", en: "{YY}", es: "{AA}") }
}

/// Etiquetas: {PASTA} nome da pasta da captação, {NOME} só o nome (sem a data),
/// {AAAA} {AA} {MM} {DD} data da captação, {N} {NN} {NNN}… número com esse tanto
/// de dígitos, {ORIGINAL} nome do arquivo no cartão.
enum Pattern {
    static let token = /\{([A-Z]+)\}/

    static func render(_ pattern: String, folder: String = "", title: String = "", date: Date?,
                       original: String = "", number: Int = 1) -> String {
        let c = date.map { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0) }
        let out = pattern.replacing(token) { m -> String in
            let raw = String(m.1)
            switch Tok.canonical(raw) {
            case "PASTA": return folder
            case "NOME": return title
            case "ORIGINAL": return original
            case "AAAA": return c.map { String(format: "%04d", $0.year ?? 0) } ?? raw
            case "AA": return c.map { String(format: "%02d", ($0.year ?? 0) % 100) } ?? raw
            case "MM": return c.map { String(format: "%02d", $0.month ?? 0) } ?? raw
            case "DD": return c.map { String(format: "%02d", $0.day ?? 0) } ?? raw
            case let n? where n.allSatisfy({ $0 == "N" }): return String(format: "%0\(n.count)d", number)
            default: return "{\(raw)}"
            }
        }
        // "/" e ":" não podem entrar em nome de arquivo no Mac
        return out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    static func hasNumber(_ pattern: String) -> Bool { pattern.contains(/\{N+\}/) }
    static func hasOriginal(_ pattern: String) -> Bool { pattern.contains("{ORIGINAL}") }

    /// Reconhece nomes feitos com o padrão. `fixed` dá o valor de etiquetas já conhecidas;
    /// as outras viram grupos que dá para ler (data, nome, número).
    struct Matcher {
        let re: NSRegularExpression
        let groups: [String]

        init?(_ pattern: String, fixed: [String: String] = [:]) {
            var out = "^", groups: [String] = []
            var rest = Substring(pattern)
            while let m = rest.firstMatch(of: Pattern.token) {
                out += NSRegularExpression.escapedPattern(for: String(rest[..<m.range.lowerBound]))
                let raw = String(m.1)
                if let name = Tok.canonical(raw) {
                    let group = name.allSatisfy({ $0 == "N" }) ? "N" : name
                    if let v = fixed[name] {
                        out += NSRegularExpression.escapedPattern(for: v)
                    } else if groups.contains(group) {
                        out += ".+?"
                    } else {
                        groups.append(group)
                        switch group {
                        case "AAAA": out += "(?<AAAA>\\d{4})"
                        case "AA", "MM", "DD": out += "(?<\(group)>\\d{2})"
                        case "N": out += "(?<N>\\d+)"
                        default: out += "(?<\(group)>.+?)"
                        }
                    }
                } else {
                    out += NSRegularExpression.escapedPattern(for: "{\(raw)}")
                }
                rest = rest[m.range.upperBound...]
            }
            out += NSRegularExpression.escapedPattern(for: String(rest)) + "$"
            guard let re = try? NSRegularExpression(pattern: out) else { return nil }
            self.re = re
            self.groups = groups
        }

        func match(_ s: String) -> [String: String]? {
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            var out: [String: String] = [:]
            for g in groups {
                let r = m.range(withName: g)
                if r.location != NSNotFound { out[g] = ns.substring(with: r) }
            }
            return out
        }
    }

    static func date(from g: [String: String]) -> Date? {
        guard let m = g["MM"].flatMap(Int.init), let d = g["DD"].flatMap(Int.init) else { return nil }
        let y = g["AAAA"].flatMap(Int.init) ?? g["AA"].flatMap(Int.init).map { 2000 + $0 }
        guard let y else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))
    }
}

// MARK: - Nomes dos arquivos

enum Naming {
    /// Nome final de um arquivo do cartão, conforme a regra da subpasta (ou o nome original).
    static func fileName(_ cfg: Config, folder: Subfolder, capture: Capture, number: Int, source: URL, date: Date) -> String {
        guard let pattern = cfg.pattern(for: folder) else { return source.lastPathComponent }
        let original = source.deletingPathExtension().lastPathComponent
        // Com {ORIGINAL} a extensão fica como veio; nos outros, em maiúsculas (padrão dos atalhos).
        let ext = Pattern.hasOriginal(pattern) ? source.pathExtension : source.pathExtension.uppercased()
        var stem = Pattern.render(pattern, folder: capture.name, title: capture.title,
                                  date: capture.date ?? date, original: original, number: number)
        if stem.isEmpty { stem = original }
        return "\(stem).\(ext)"
    }

    /// Lê o número dos arquivos que já estão no destino, para continuar a numeração.
    static func numberMatcher(_ pattern: String, capture: Capture) -> Pattern.Matcher? {
        var fixed = ["PASTA": capture.name, "NOME": capture.title]
        if let d = capture.date {
            for t in ["AAAA", "AA", "MM", "DD"] { fixed[t] = Pattern.render("{\(t)}", date: d) }
        }
        return Pattern.Matcher(pattern, fixed: fixed)
    }
}

// MARK: - Captações do disco principal

struct Capture: Identifiable, Hashable, Sendable {
    let name: String
    let date: Date?
    let title: String
    var id: String { name }

    init(name: String, matcher: Pattern.Matcher? = nil) {
        self.name = name
        if let g = matcher?.match(name), let d = Pattern.date(from: g) {
            date = d
            let t = (g["NOME"] ?? "").trimmingCharacters(in: .whitespaces)
            title = t.isEmpty ? name : t
        } else if let m = name.firstMatch(of: /^(\d{8})\s*-?\s*(.*)$/) {
            // Pastas antigas: "20261020 - CC BEB Atividade Extra" (aceita também "20260925- ...")
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.locale = Locale(identifier: "en_US_POSIX")
            date = f.date(from: String(m.1))
            title = m.2.isEmpty ? name : String(m.2).trimmingCharacters(in: .whitespaces)
        } else {
            date = nil
            title = name
        }
    }

    /// Mais recente no topo; pastas sem data no fim, em ordem alfabética.
    static func sorted(_ list: [Capture]) -> [Capture] {
        list.sorted { a, b in
            switch (a.date, b.date) {
            case let (da?, db?): da == db ? a.name.localizedStandardCompare(b.name) == .orderedDescending : da > db
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    static func list(_ cfg: Config) -> [Capture] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: cfg.inboxURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let matcher = Pattern.Matcher(cfg.folderPattern)
        return sorted(dirs.map { Capture(name: $0.lastPathComponent, matcher: matcher) })
    }

    static func folderName(_ cfg: Config, date: Date, title: String) -> String {
        Pattern.render(cfg.folderPattern, title: title.trimmingCharacters(in: .whitespacesAndNewlines), date: date)
    }

    /// Cria a pasta da captação com as subpastas escolhidas. Não mexe em nada que já exista.
    static func create(named name: String, _ cfg: Config) throws -> URL {
        let root = cfg.inboxURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sub in cfg.captureFolders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return root
    }
}

// MARK: - Arquivos do cartão

struct SourceFile: Sendable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    let folder: UUID       // subpasta que recebe este arquivo
    let card: URL          // cartão (ou pasta) de onde ele vem
    var cardName: String { card.lastPathComponent }
}

enum CardScanner {
    /// Pastas que o cartão tem e não interessam (proxies da Sony, lixo do macOS).
    static let skippedFolders: Set<String> = [".Spotlight-V100", ".Trashes", ".fseventsd", "SUB", "THMBNL"]

    /// Vários cartões: junta tudo e põe em ordem de gravação (as câmeras ficam intercaladas no tempo).
    static func scan(_ roots: [URL], _ cfg: Config) -> [SourceFile] {
        sorted(roots.flatMap { scan($0, cfg) })
    }

    static func sorted(_ files: [SourceFile]) -> [SourceFile] {
        files.sorted { $0.date == $1.date ? $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending : $0.date < $1.date }
    }

    static func scan(_ root: URL, _ cfg: Config) -> [SourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [SourceFile] = []
        for case let url as URL in e {
            if skippedFolders.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard let folder = cfg.folder(for: url),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append(SourceFile(
                url: url, size: Int64(v.fileSize ?? 0),
                date: [v.creationDate, v.contentModificationDate].compactMap { $0 }.min() ?? .distantPast, folder: folder.id, card: root))
        }
        // Ordem de gravação: assim o 001 é sempre o primeiro clipe/foto do dia.
        return sorted(out)
    }
}

// MARK: - Plano de importação

struct CopyJob: Sendable {
    let source: SourceFile
    let targets: [URL]      // disco principal (e, se marcados, os de redundância)
    var name: String { targets[0].lastPathComponent }
}

/// Arquivo do cartão que já está no disco principal (mesmo tamanho e mesmo conteúdo).
struct Duplicate: Sendable {
    let source: SourceFile
    let existing: URL
    let capture: String     // pasta da captação onde ele já está
}

struct ImportPlan: Sendable {
    var capture = ""
    /// Pasta da captação em cada destino: o disco principal primeiro, depois as redundâncias.
    var roots: [URL] = []
    var jobs: [CopyJob] = []
    var duplicates: [Duplicate] = []
    var bytes: Int64 { jobs.reduce(0) { $0 + $1.source.size } }
    var alreadyHere: [Duplicate] { duplicates.filter { $0.capture == capture } }
    var elsewhere: [Duplicate] { duplicates.filter { $0.capture != capture } }

    static func make(files: [SourceFile], selected: Set<UUID>, capture: Capture,
                     cfg: Config, backups: [URL]) -> ImportPlan {
        var plan = ImportPlan(capture: capture.name)
        let chosen = files.filter { selected.contains($0.folder) }
        let index = InboxIndex(cfg, sizes: Set(chosen.map(\.size)), preferring: capture.name)
        let root = cfg.inboxURL.appendingPathComponent(capture.name)
        let backupRoots = backups.map { $0.appendingPathComponent(capture.name) }
        plan.roots = [root] + backupRoots
        // Com mais de um cartão e "separar por cartão", cada cartão ganha a sua subpasta
        let split = cfg.splitByCard && Set(chosen.map(\.card)).count > 1
        for folder in cfg.receivingFolders where selected.contains(folder.id) {
            let ofFolder = chosen.filter { $0.folder == folder.id }
            let groups: [(String, [SourceFile])] = split
                ? Dictionary(grouping: ofFolder, by: \.cardName).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                : [("", ofFolder)]
            for (cardName, group) in groups {
                let sub = cardName.isEmpty ? folder.trimmedPath : "\(folder.trimmedPath)/\(cardName)"
                let dest = root.appendingPathComponent(sub)
                let backupDests = backupRoots.map { $0.appendingPathComponent(sub) }
                let existing = names(in: dest)
                var used = Set(existing)
                for b in backupDests { used.formUnion(names(in: b)) }
                let pattern = cfg.pattern(for: folder)
                let numbered = pattern.map(Pattern.hasNumber) ?? false
                let matcher = pattern.flatMap { Naming.numberMatcher($0, capture: capture) }
                var number = (existing.compactMap { name -> Int? in
                    let stem = (name as NSString).deletingPathExtension
                    return matcher?.match(stem)?["N"].flatMap(Int.init)
                }.max() ?? 0) + 1

                for file in group {
                    if let dup = index.match(file) {
                        plan.duplicates.append(dup)
                        continue
                    }
                    func make(_ n: Int) -> String {
                        Naming.fileName(cfg, folder: folder, capture: capture, number: n, source: file.url, date: file.date)
                    }
                    var name = make(number)
                    if numbered {
                        while used.contains(name) { number += 1; name = make(number) }
                        number += 1
                    } else {
                        // Sem número (ex.: nome original): nomes repetidos ganham " (2)", " (3)"…
                        let base = name as NSString
                        var k = 2
                        while used.contains(name) {
                            name = "\(base.deletingPathExtension) (\(k)).\(base.pathExtension)"
                            k += 1
                        }
                    }
                    used.insert(name)
                    plan.jobs.append(CopyJob(source: file, targets: [dest.appendingPathComponent(name)]
                                             + backupDests.map { $0.appendingPathComponent(name) }))
                }
            }
        }
        return plan
    }

    static func names(in dir: URL?) -> [String] {
        guard let dir else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }) ?? []
    }
}

/// Arquivos já importados no disco principal, por tamanho (só os tamanhos que existem no cartão).
/// Olha a captação inteira, em qualquer subpasta, para reconhecer também o que veio de
/// estruturas antigas (ex.: a pasta Lapela) ou dos atalhos que não guardavam a data original:
/// mesmo tamanho + mesmo começo e fim do arquivo = mesmo arquivo.
struct InboxIndex {
    struct Entry { let url: URL; let capture: String }
    private var bySize: [Int64: [Entry]] = [:]

    init(_ cfg: Config, sizes: Set<Int64>, preferring capture: String) {
        guard !sizes.isEmpty else { return }
        let fm = FileManager.default
        let inbox = cfg.inboxURL
        let captures = (try? fm.contentsOfDirectory(atPath: inbox.path).filter { !$0.hasPrefix(".") }) ?? []
        // A captação escolhida vem primeiro, para o aviso apontar para ela quando o arquivo estiver nas duas.
        for c in captures.sorted(by: { a, _ in a == capture }) {
            guard let e = fm.enumerator(at: inbox.appendingPathComponent(c), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true,
                      let size = v.fileSize, sizes.contains(Int64(size)) else { continue }
                bySize[Int64(size), default: []].append(Entry(url: url, capture: c))
            }
        }
    }

    func match(_ file: SourceFile) -> Duplicate? {
        guard let candidates = bySize[file.size], let sig = Signature.of(file.url) else { return nil }
        for c in candidates where Signature.of(c.url) == sig {
            return Duplicate(source: file, existing: c.url, capture: c.capture)
        }
        return nil
    }
}

/// Hash do primeiro e do último 256 KB: rápido e suficiente para reconhecer o mesmo arquivo.
/// (Antes de apagar algo do cartão, a conferência é feita no arquivo inteiro.)
enum Signature {
    static let span = 256 * 1024
    static func of(_ url: URL) -> SHA256.Digest? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        guard let head = try? h.read(upToCount: span) else { return nil }
        hasher.update(data: head)
        if let end = try? h.seekToEnd(), end > UInt64(span) {
            try? h.seek(toOffset: end - UInt64(span))
            if let tail = try? h.readToEnd() { hasher.update(data: tail) }
        }
        return hasher.finalize()
    }
}

// MARK: - Cópia com verificação

/// Original do cartão e a cópia já conferida no disco principal.
struct VerifiedCopy: Sendable {
    let source: URL
    let copy: URL
    let size: Int64
}

/// Um arquivo copiado e conferido (para o relatório e o ASC MHL).
struct FileEntry: Sendable {
    let source: URL
    let cardName: String
    let size: Int64
    let hash: String          // xxHash64
    let targets: [URL]        // cópia em cada destino, na mesma ordem de ImportPlan.roots
    let modified: Date
    let hashDate: Date
}

struct ImportReport: Sendable {
    var plan = ImportPlan()
    var copies: [VerifiedCopy] = []
    var entries: [FileEntry] = []
    var copied: [UUID: Int] = [:]
    var verified = 0
    var skipped = 0
    var failures: [String] = []
    /// Avisos que não afetam as cópias (ex.: relatório que não pôde ser salvo).
    var warnings: [String] = []
    var cancelled = false
    var bytes: Int64 = 0
    var start = Date()
    var end = Date()
    var seconds: Double { end.timeIntervalSince(start) }
}

final class Copier: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }

    struct Progress: Sendable {
        var done: Int64; var total: Int64
        var fileIndex: Int; var fileCount: Int
        var fileName: String; var phase: String
        var cards = 1         // cartões sendo copiados ao mesmo tempo
    }

    static let chunk = 8 * 1024 * 1024

    /// Copia cada arquivo para um temporário oculto, relê a cópia do disco (sem cache),
    /// compara o xxHash64 com o do original e só então dá o nome final.
    /// Cada cartão é copiado ao mesmo tempo que os outros (um leitor não espera o outro).
    func run(_ plan: ImportPlan, onProgress: @escaping @Sendable (Progress) -> Void) -> ImportReport {
        let state = NSLock()
        var report = ImportReport()
        report.plan = plan
        report.skipped = plan.duplicates.count
        report.start = Date()
        let total = plan.jobs.reduce(Int64(0)) { $0 + $1.source.size * Int64(1 + $1.targets.count) }
        var done: Int64 = 0
        var finished = 0
        var lastReport = Date.distantPast
        let copying = L("Copiando"), checking = L("Conferindo")
        // Um grupo por cartão, na ordem do plano
        var order: [URL] = []
        var byCard: [URL: [CopyJob]] = [:]
        for j in plan.jobs {
            if byCard[j.source.card] == nil { order.append(j.source.card) }
            byCard[j.source.card, default: []].append(j)
        }

        func tick(_ name: String, _ phase: String, add: Int64 = 0, force: Bool = false) {
            state.lock()
            done += add
            let now = Date()
            let send = force || now.timeIntervalSince(lastReport) > 0.1
            if send { lastReport = now }
            let p = Progress(done: done, total: total, fileIndex: finished, fileCount: plan.jobs.count,
                             fileName: name, phase: phase, cards: order.count)
            state.unlock()
            if send { onProgress(p) }
        }

        DispatchQueue.concurrentPerform(iterations: order.count) { g in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
            defer { buffer.deallocate() }
            for job in byCard[order[g]]! {
                if isCancelled { state.withLock { report.cancelled = true }; break }
                tick(job.name, copying, force: true)
                let temps = job.targets.map { $0.deletingLastPathComponent().appendingPathComponent(".\($0.lastPathComponent).importando") }
                do {
                    for t in job.targets {
                        try FileManager.default.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: t.path) { throw CopyError.exists(t.lastPathComponent) }
                    }
                    let digest = try copy(job.source.url, to: temps, buffer: buffer) { n in tick(job.name, copying, add: n) }
                    let modified = (try? job.source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? job.source.date
                    for (t, final) in zip(temps, job.targets) {
                        tick(job.name, checking, force: true)
                        let check = try hash(t, buffer: buffer) { n in tick(job.name, checking, add: n) }
                        guard check == digest else { throw CopyError.mismatch(final.lastPathComponent) }
                        try FileManager.default.setAttributes([.creationDate: job.source.date, .modificationDate: modified], ofItemAtPath: t.path)
                        try FileManager.default.moveItem(at: t, to: final)
                    }
                    let entry = FileEntry(source: job.source.url, cardName: job.source.cardName, size: job.source.size,
                                          hash: XXH64.hex(digest), targets: job.targets, modified: modified, hashDate: Date())
                    state.withLock {
                        report.copies.append(VerifiedCopy(source: job.source.url, copy: job.targets[0], size: job.source.size))
                        report.entries.append(entry)
                        report.copied[job.source.folder, default: 0] += 1
                        report.verified += 1
                        report.bytes += job.source.size
                        finished += 1
                    }
                } catch CopyError.cancelled {
                    for t in temps { try? FileManager.default.removeItem(at: t) }   // só a cópia incompleta
                    state.withLock { report.cancelled = true }
                    break
                } catch {
                    for t in temps { try? FileManager.default.removeItem(at: t) }   // só a cópia que falhou
                    state.withLock {
                        report.failures.append("\(job.source.url.lastPathComponent) → \(job.name): \(error.localizedDescription)")
                        finished += 1
                    }
                }
            }
        }
        // Relatório na ordem de gravação, não na ordem em que os cartões terminaram
        let rank = Dictionary(uniqueKeysWithValues: plan.jobs.enumerated().map { ($1.source.url, $0) })
        report.entries.sort { rank[$0.source, default: 0] < rank[$1.source, default: 0] }
        report.end = Date()
        tick("", L("Pronto"), force: true)
        return report
    }

    struct CleanupReport: Sendable {
        var deleted = 0
        var bytes: Int64 = 0
        var problems: [String] = []
        var leftovers = 0
        var cancelled = false
    }

    /// Limpa os cartões: relê o original e a cópia inteiros, compara o xxHash64
    /// e só então apaga o original. O que não bater (ou sumir do disco) fica no cartão.
    func cleanCards(roots: [URL], items: [VerifiedCopy], onProgress: @escaping @Sendable (Progress) -> Void) -> CleanupReport {
        var report = CleanupReport()
        let total = items.reduce(Int64(0)) { $0 + $1.size * 2 }
        var done: Int64 = 0
        var lastReport = Date.distantPast
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
        defer { buffer.deallocate() }
        let checking = L("Conferindo")

        func tick(_ i: Int, _ name: String, _ phase: String, force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                onProgress(Progress(done: done, total: total, fileIndex: i, fileCount: items.count,
                                    fileName: name, phase: phase))
            }
        }

        let rootPaths = roots.map { $0.standardizedFileURL.path + "/" }
        for (i, item) in items.enumerated() {
            if isCancelled { report.cancelled = true; break }
            let name = item.source.lastPathComponent
            tick(i, name, checking, force: true)
            do {
                // Segurança: só apaga dentro dos cartões escolhidos.
                let path = item.source.standardizedFileURL.path
                guard rootPaths.contains(where: { path.hasPrefix($0) }) else { throw CopyError.outside(name) }
                guard FileManager.default.fileExists(atPath: item.copy.path) else { throw CopyError.missing(item.copy.lastPathComponent) }
                let original = try hash(item.source, buffer: buffer) { n in done += n; tick(i, name, checking) }
                let copy = try hash(item.copy, buffer: buffer) { n in done += n; tick(i, name, checking) }
                guard original == copy else { throw CopyError.mismatch(item.copy.lastPathComponent) }
                try FileManager.default.removeItem(at: item.source)
                report.deleted += 1
                report.bytes += item.size
            } catch CopyError.cancelled {
                report.cancelled = true
                break
            } catch {
                report.problems.append(L("{0}: {1}. Ficou no cartão.", name, error.localizedDescription))
            }
        }
        // O que sobrou nos cartões (JPG, proxies, arquivos da câmera…)
        for root in roots {
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) {
                for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    report.leftovers += 1
                }
            }
        }
        tick(items.count, "", L("Pronto"), force: true)
        return report
    }

    enum CopyError: LocalizedError {
        case open(String), read(String), write(String), mismatch(String), exists(String), missing(String), outside(String), cancelled
        var errorDescription: String? {
            switch self {
            case .open(let s): L("não foi possível abrir {0}", s)
            case .read(let s): L("erro de leitura em {0}", s)
            case .write(let s): L("erro de gravação em {0} (disco cheio?)", s)
            case .mismatch(let s): L("a cópia de {0} não bate com o original", s)
            case .exists(let s): L("já existe um arquivo chamado {0}", s)
            case .missing(let s): L("a cópia {0} não está mais no disco", s)
            case .outside(let s): L("{0} não está no cartão", s)
            case .cancelled: L("cancelado")
            }
        }
    }

    private func copy(_ src: URL, to dests: [URL], buffer: UnsafeMutableRawPointer,
                      progress: (Int64) -> Void) throws -> UInt64 {
        let inFD = open(src.path, O_RDONLY)
        guard inFD >= 0 else { throw CopyError.open(src.lastPathComponent) }
        defer { close(inFD) }
        _ = fcntl(inFD, F_NOCACHE, 1)
        var outFDs: [Int32] = []
        defer { outFDs.forEach { close($0) } }
        for d in dests {
            let fd = open(d.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { throw CopyError.open(d.lastPathComponent) }
            _ = fcntl(fd, F_NOCACHE, 1)
            outFDs.append(fd)
        }
        var hasher = XXH64()
        while true {
            if isCancelled { throw CopyError.cancelled }
            let n = read(inFD, buffer, Self.chunk)
            if n < 0 { throw CopyError.read(src.lastPathComponent) }
            if n == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: n))
            for (fd, d) in zip(outFDs, dests) {
                var off = 0
                while off < n {
                    let w = write(fd, buffer + off, n - off)
                    if w <= 0 { throw CopyError.write(d.lastPathComponent) }
                    off += w
                }
            }
            progress(Int64(n))
        }
        for (fd, d) in zip(outFDs, dests) where fsync(fd) != 0 { throw CopyError.write(d.lastPathComponent) }
        return hasher.digest()
    }

    private func hash(_ url: URL, buffer: UnsafeMutableRawPointer, progress: (Int64) -> Void) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CopyError.open(url.lastPathComponent) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = XXH64()
        while true {
            if isCancelled { throw CopyError.cancelled }
            let n = read(fd, buffer, Self.chunk)
            if n < 0 { throw CopyError.read(url.lastPathComponent) }
            if n == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: n))
            progress(Int64(n))
        }
        return hasher.digest()
    }
}
