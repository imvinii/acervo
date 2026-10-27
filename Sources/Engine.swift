// Motor do app: lista as captações, lê o cartão e copia com verificação.
// Nada aqui apaga, move ou renomeia arquivo do cartão: ele só é lido.

import Foundation
import CryptoKit

// MARK: - Configuração (escolhida na primeira abertura, muda em Ajustes)

struct Config: Codable, Equatable, Sendable {
    /// Destino principal: a pasta onde ficam as captações.
    var inbox: String
    /// Cópia de redundância em outro disco ("" = sem redundância).
    var backup: String
    /// Nome da pasta de cada captação, ex.: "{AAAA}{MM}{DD} - {NOME}".
    var folderPattern: String
    /// Subpasta de cada tipo dentro da captação (chave = Kind.rawValue).
    var subpaths: [String: String]
    /// Pastas criadas vazias em toda captação nova, ex.: "Fotos/Seleção".
    var extraFolders: [String]
    /// Nome de cada arquivo, ex.: "{PASTA} - {NNN}" (a extensão entra sozinha).
    var filePatterns: [String: String]
    /// Discos que nunca aparecem na lista de cartões.
    var ignoredVolumes: [String]

    var inboxURL: URL { URL(fileURLWithPath: inbox) }
    var backupURL: URL? { backup.isEmpty ? nil : URL(fileURLWithPath: backup) }
    func subpath(_ k: Kind) -> String {
        let s = (subpaths[k.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? k.defaultSubpath : s
    }
    func filePattern(_ k: Kind) -> String {
        let s = (filePatterns[k.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "{ORIGINAL}" : s
    }
    /// Subpastas criadas numa captação nova (documentos só quando houver algum).
    var captureFolders: [String] {
        var out: [String] = []
        for f in Kind.allCases.filter({ $0 != .documentos }).map(subpath) + extraFolders where !out.contains(f) && !f.isEmpty {
            out.append(f)
        }
        return out
    }

    /// Modelo para quem está começando.
    static let simple = Config(
        inbox: "", backup: "", folderPattern: "{AAAA}{MM}{DD} - {NOME}",
        subpaths: ["videos": "Vídeos", "fotos": "Fotos", "audios": "Áudios", "documentos": "Documentos"],
        extraFolders: [],
        filePatterns: ["videos": "{PASTA} - {NNN}", "fotos": "{PASTA} - {NNN}", "audios": "{PASTA} - {NNN}", "documentos": "{ORIGINAL}"],
        ignoredVolumes: [])

    /// Padrão da Vértice (o mesmo dos atalhos "Criar projeto" e "Importar SD").
    static let vertice = Config(
        inbox: "/Volumes/Mídias/Inbox", backup: "/Volumes/Projetos/Inbox (BACKUP)", folderPattern: "{AAAA}{MM}{DD} - {NOME}",
        subpaths: ["videos": "Vídeos", "fotos": "Fotos/Brutas", "audios": "Lapela", "documentos": "Documentos"],
        extraFolders: ["Fotos/Seleção"],
        filePatterns: ["videos": "{PASTA} - {NNN}", "fotos": "{PASTA} - {NNN}", "audios": "{PASTA}.{N}", "documentos": "{ORIGINAL}"],
        ignoredVolumes: ["Elements"])

    /// Sugestão da primeira abertura: o padrão da Vértice se os SSDs dela estiverem neste Mac.
    static var suggested: Config {
        FileManager.default.fileExists(atPath: vertice.inbox) ? vertice : simple
    }

    static let key = "config"
    static func load() -> Config? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: d)
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

// MARK: - Padrões de nome

/// Etiquetas: {PASTA} nome da pasta da captação, {NOME} só o nome (sem a data),
/// {AAAA} {AA} {MM} {DD} data da captação, {N} {NN} {NNN}… número com esse tanto
/// de dígitos, {ORIGINAL} nome do arquivo no cartão.
enum Pattern {
    static let token = /\{([A-Z]+)\}/

    static func render(_ pattern: String, folder: String = "", title: String = "", date: Date?,
                       original: String = "", number: Int = 1) -> String {
        let c = date.map { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0) }
        let out = pattern.replacing(token) { m -> String in
            let name = String(m.1)
            switch name {
            case "PASTA": return folder
            case "NOME": return title
            case "ORIGINAL": return original
            case "AAAA": return c.map { String(format: "%04d", $0.year ?? 0) } ?? name
            case "AA": return c.map { String(format: "%02d", ($0.year ?? 0) % 100) } ?? name
            case "MM": return c.map { String(format: "%02d", $0.month ?? 0) } ?? name
            case "DD": return c.map { String(format: "%02d", $0.day ?? 0) } ?? name
            case _ where name.allSatisfy({ $0 == "N" }): return String(format: "%0\(name.count)d", number)
            default: return "{\(name)}"
            }
        }
        // "/" e ":" não podem entrar em nome de arquivo no Mac
        return out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    static func hasNumber(_ pattern: String) -> Bool { pattern.contains(/\{N+\}/) }

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
                let name = String(m.1)
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

// MARK: - Tipos de arquivo

enum Kind: String, CaseIterable, Identifiable, Sendable {
    case videos, fotos, audios, documentos
    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: "Vídeos"
        case .fotos: "Fotos RAW"
        case .audios: "Áudios (MP3 e WAV)"
        case .documentos: "Documentos (PDF e Word)"
        }
    }
    var shortTitle: String {
        switch self {
        case .videos: "Vídeos"
        case .fotos: "Fotos"
        case .audios: "Áudios"
        case .documentos: "Documentos"
        }
    }
    func label(_ n: Int) -> String {
        switch self {
        case .videos: n == 1 ? "1 vídeo" : "\(n) vídeos"
        case .fotos: n == 1 ? "1 foto RAW" : "\(n) fotos RAW"
        case .audios: n == 1 ? "1 áudio" : "\(n) áudios"
        case .documentos: n == 1 ? "1 documento" : "\(n) documentos"
        }
    }
    var symbol: String {
        switch self {
        case .videos: "video.fill"
        case .fotos: "camera.fill"
        case .audios: "waveform"
        case .documentos: "doc.text.fill"
        }
    }
    var extensions: Set<String> {
        switch self {
        case .videos: ["mp4", "mov", "mxf", "braw"]
        case .fotos: ["cr2", "cr3", "arw", "nef", "raf", "rw2", "orf", "dng"]
        case .audios: ["wav", "mp3"]
        case .documentos: ["pdf", "doc", "docx", "pages", "rtf", "odt"]
        }
    }
    var defaultSubpath: String { shortTitle }
    /// Já vem marcado quando aparece no cartão; documentos só se a pessoa marcar.
    var onByDefault: Bool { self != .documentos }

    /// Nome final do arquivo, conforme o padrão escolhido para este tipo.
    func fileName(_ cfg: Config, capture: Capture, number: Int, source: URL, date: Date) -> String {
        let pattern = cfg.filePattern(self)
        let original = source.deletingPathExtension().lastPathComponent
        // Com {ORIGINAL} a extensão fica como veio; nos outros, em maiúsculas (padrão dos atalhos).
        let ext = pattern.contains("{ORIGINAL}") ? source.pathExtension : source.pathExtension.uppercased()
        var stem = Pattern.render(pattern, folder: capture.name, title: capture.title,
                                  date: capture.date ?? date, original: original, number: number)
        if stem.isEmpty { stem = original }
        return "\(stem).\(ext)"
    }

    /// Lê o número dos arquivos que já estão no destino, para continuar a numeração.
    func numberMatcher(_ cfg: Config, capture: Capture) -> Pattern.Matcher? {
        var fixed = ["PASTA": capture.name, "NOME": capture.title]
        if let d = capture.date {
            for t in ["AAAA", "AA", "MM", "DD"] { fixed[t] = Pattern.render("{\(t)}", date: d) }
        }
        return Pattern.Matcher(cfg.filePattern(self), fixed: fixed)
    }

    static func of(_ url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }
}

// MARK: - Captações da Inbox

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
    let kind: Kind
}

enum CardScanner {
    /// Pastas que o cartão tem e não interessam (proxies da Sony, lixo do macOS).
    static let skippedFolders: Set<String> = [".Spotlight-V100", ".Trashes", ".fseventsd", "SUB", "THMBNL"]

    static func scan(_ root: URL) -> [SourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [SourceFile] = []
        for case let url as URL in e {
            if skippedFolders.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard let kind = Kind.of(url),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append(SourceFile(
                url: url, size: Int64(v.fileSize ?? 0),
                date: [v.creationDate, v.contentModificationDate].compactMap { $0 }.min() ?? .distantPast, kind: kind))
        }
        // Ordem de gravação: assim o 001 é sempre o primeiro clipe/foto do dia.
        return out.sorted { $0.date == $1.date ? $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending : $0.date < $1.date }
    }
}

// MARK: - Plano de importação

struct CopyJob: Sendable {
    let source: SourceFile
    let targets: [URL]      // destino principal (e, se marcado, a redundância)
    var name: String { targets[0].lastPathComponent }
}

/// Arquivo do cartão que já está na Inbox (mesmo tamanho e mesmo conteúdo).
struct Duplicate: Sendable {
    let source: SourceFile
    let existing: URL
    let capture: String     // pasta da captação onde ele já está
}

struct ImportPlan: Sendable {
    var capture = ""
    var jobs: [CopyJob] = []
    var duplicates: [Duplicate] = []
    var bytes: Int64 { jobs.reduce(0) { $0 + $1.source.size } }
    var alreadyHere: [Duplicate] { duplicates.filter { $0.capture == capture } }
    var elsewhere: [Duplicate] { duplicates.filter { $0.capture != capture } }

    static func make(files: [SourceFile], kinds: Set<Kind>, capture: Capture,
                     cfg: Config, backup: Bool) -> ImportPlan {
        var plan = ImportPlan(capture: capture.name)
        let index = InboxIndex(cfg, kinds: kinds, preferring: capture.name)
        let root = cfg.inboxURL.appendingPathComponent(capture.name)
        let backupRoot = backup ? cfg.backupURL?.appendingPathComponent(capture.name) : nil
        for kind in Kind.allCases where kinds.contains(kind) {
            let dest = root.appendingPathComponent(cfg.subpath(kind))
            let backupDest = backupRoot?.appendingPathComponent(cfg.subpath(kind))
            let existing = names(in: dest)
            var used = Set(existing).union(names(in: backupDest))
            let matcher = kind.numberMatcher(cfg, capture: capture)
            let numbered = Pattern.hasNumber(cfg.filePattern(kind))
            var number = (existing.compactMap { name -> Int? in
                let stem = (name as NSString).deletingPathExtension
                return matcher?.match(stem)?["N"].flatMap(Int.init)
            }.max() ?? 0) + 1

            for file in files where file.kind == kind {
                if let dup = index.match(file) {
                    plan.duplicates.append(dup)
                    continue
                }
                var name = kind.fileName(cfg, capture: capture, number: number, source: file.url, date: file.date)
                if numbered {
                    while used.contains(name) {
                        number += 1
                        name = kind.fileName(cfg, capture: capture, number: number, source: file.url, date: file.date)
                    }
                    number += 1
                } else {
                    // Padrão sem número (ex.: nome original): nomes repetidos ganham " (2)", " (3)"…
                    let base = name as NSString
                    var k = 2
                    while used.contains(name) {
                        name = "\(base.deletingPathExtension) (\(k)).\(base.pathExtension)"
                        k += 1
                    }
                }
                used.insert(name)
                var targets = [dest.appendingPathComponent(name)]
                if let backupDest { targets.append(backupDest.appendingPathComponent(name)) }
                plan.jobs.append(CopyJob(source: file, targets: targets))
            }
        }
        return plan
    }

    static func names(in dir: URL?) -> [String] {
        guard let dir else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }) ?? []
    }
}

/// Todos os arquivos já importados na Inbox, por tamanho. Serve para achar o que
/// já foi copiado antes, inclusive pelos atalhos antigos (que não guardavam a data
/// original): mesmo tamanho + mesmo começo e fim do arquivo = mesmo arquivo.
struct InboxIndex {
    struct Entry { let url: URL; let capture: String }
    private var bySize: [Int64: [Entry]] = [:]

    init(_ cfg: Config, kinds: Set<Kind>, preferring capture: String) {
        let fm = FileManager.default
        let inbox = cfg.inboxURL
        let captures = (try? fm.contentsOfDirectory(atPath: inbox.path).filter { !$0.hasPrefix(".") }) ?? []
        // A captação escolhida vem primeiro, para o aviso apontar para ela quando o arquivo estiver nas duas.
        for c in captures.sorted(by: { a, _ in a == capture }) {
            for kind in kinds {
                let dir = inbox.appendingPathComponent(c).appendingPathComponent(cfg.subpath(kind))
                let items = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                for url in items where kind.extensions.contains(url.pathExtension.lowercased()) {
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                    bySize[Int64(size), default: []].append(Entry(url: url, capture: c))
                }
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

/// Original do cartão e a cópia já conferida no SSD.
struct VerifiedCopy: Sendable {
    let source: URL
    let copy: URL
    let size: Int64
}

struct ImportReport: Sendable {
    var plan = ImportPlan()
    var copies: [VerifiedCopy] = []
    var copied: [Kind: Int] = [:]
    var verified = 0
    var skipped = 0
    var failures: [String] = []
    var cancelled = false
    var bytes: Int64 = 0
    var seconds: Double = 0
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
    }

    static let chunk = 8 * 1024 * 1024

    /// Copia cada arquivo para um temporário oculto, relê a cópia do disco (sem cache),
    /// compara o SHA-256 com o do original e só então dá o nome final.
    func run(_ plan: ImportPlan, onProgress: @escaping @Sendable (Progress) -> Void) -> ImportReport {
        var report = ImportReport()
        report.plan = plan
        report.skipped = plan.duplicates.count
        let start = Date()
        let total = plan.jobs.reduce(Int64(0)) { $0 + $1.source.size * Int64(1 + $1.targets.count) }
        var done: Int64 = 0
        var lastReport = Date.distantPast
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
        defer { buffer.deallocate() }

        func tick(_ i: Int, _ name: String, _ phase: String, force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                onProgress(Progress(done: done, total: total, fileIndex: i, fileCount: plan.jobs.count,
                                    fileName: name, phase: phase))
            }
        }

        for (i, job) in plan.jobs.enumerated() {
            if isCancelled { report.cancelled = true; break }
            tick(i, job.name, "Copiando", force: true)
            let temps = job.targets.map { $0.deletingLastPathComponent().appendingPathComponent(".\($0.lastPathComponent).importando") }
            do {
                for t in job.targets {
                    try FileManager.default.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: t.path) { throw CopyError.exists(t.lastPathComponent) }
                }
                let digest = try copy(job.source.url, to: temps, buffer: buffer) { n in
                    done += n; tick(i, job.name, "Copiando")
                }
                for (t, final) in zip(temps, job.targets) {
                    tick(i, job.name, "Conferindo", force: true)
                    let check = try hash(t, buffer: buffer) { n in done += n; tick(i, job.name, "Conferindo") }
                    guard check == digest else { throw CopyError.mismatch(final.lastPathComponent) }
                    try FileManager.default.setAttributes(
                        [.creationDate: job.source.date,
                         .modificationDate: (try? job.source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? job.source.date],
                        ofItemAtPath: t.path)
                    try FileManager.default.moveItem(at: t, to: final)
                }
                report.copies.append(VerifiedCopy(source: job.source.url, copy: job.targets[0], size: job.source.size))
                report.copied[job.source.kind, default: 0] += 1
                report.verified += 1
                report.bytes += job.source.size
            } catch CopyError.cancelled {
                for t in temps { try? FileManager.default.removeItem(at: t) }   // só a cópia incompleta
                report.cancelled = true
                break
            } catch {
                for t in temps { try? FileManager.default.removeItem(at: t) }   // só a cópia que falhou
                report.failures.append("\(job.source.url.lastPathComponent) → \(job.name): \(error.localizedDescription)")
            }
        }
        report.seconds = Date().timeIntervalSince(start)
        tick(plan.jobs.count, "", "Pronto", force: true)
        return report
    }

    struct CleanupReport: Sendable {
        var deleted = 0
        var bytes: Int64 = 0
        var problems: [String] = []
        var leftovers = 0
        var cancelled = false
    }

    /// Limpa o cartão: relê o original e a cópia no SSD inteiros, compara o SHA-256
    /// e só então apaga o original. O que não bater (ou sumir do SSD) fica no cartão.
    func cleanCard(root: URL, items: [VerifiedCopy], onProgress: @escaping @Sendable (Progress) -> Void) -> CleanupReport {
        var report = CleanupReport()
        let total = items.reduce(Int64(0)) { $0 + $1.size * 2 }
        var done: Int64 = 0
        var lastReport = Date.distantPast
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
        defer { buffer.deallocate() }

        func tick(_ i: Int, _ name: String, _ phase: String, force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                onProgress(Progress(done: done, total: total, fileIndex: i, fileCount: items.count,
                                    fileName: name, phase: phase))
            }
        }

        let rootPath = root.standardizedFileURL.path + "/"
        for (i, item) in items.enumerated() {
            if isCancelled { report.cancelled = true; break }
            let name = item.source.lastPathComponent
            tick(i, name, "Conferindo", force: true)
            do {
                // Segurança: só apaga dentro do cartão escolhido.
                guard item.source.standardizedFileURL.path.hasPrefix(rootPath) else { throw CopyError.outside(name) }
                guard FileManager.default.fileExists(atPath: item.copy.path) else { throw CopyError.missing(item.copy.lastPathComponent) }
                let original = try hash(item.source, buffer: buffer) { n in done += n; tick(i, name, "Conferindo") }
                let copy = try hash(item.copy, buffer: buffer) { n in done += n; tick(i, name, "Conferindo") }
                guard original == copy else { throw CopyError.mismatch(item.copy.lastPathComponent) }
                try FileManager.default.removeItem(at: item.source)
                report.deleted += 1
                report.bytes += item.size
            } catch CopyError.cancelled {
                report.cancelled = true
                break
            } catch {
                report.problems.append("\(name): \(error.localizedDescription). Ficou no cartão.")
            }
        }
        // O que sobrou no cartão (JPG, proxies, arquivos da câmera…)
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                report.leftovers += 1
            }
        }
        tick(items.count, "", "Pronto", force: true)
        return report
    }

    enum CopyError: LocalizedError {
        case open(String), read(String), write(String), mismatch(String), exists(String), missing(String), outside(String), cancelled
        var errorDescription: String? {
            switch self {
            case .open(let s): "não foi possível abrir \(s)"
            case .read(let s): "erro de leitura em \(s)"
            case .write(let s): "erro de gravação em \(s) (disco cheio?)"
            case .mismatch(let s): "a cópia de \(s) não bate com o original"
            case .exists(let s): "já existe um arquivo chamado \(s)"
            case .missing(let s): "a cópia \(s) não está mais no SSD"
            case .outside(let s): "\(s) não está no cartão"
            case .cancelled: "cancelado"
            }
        }
    }

    private func copy(_ src: URL, to dests: [URL], buffer: UnsafeMutableRawPointer,
                      progress: (Int64) -> Void) throws -> SHA256.Digest {
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
        var hasher = SHA256()
        while true {
            if isCancelled { throw CopyError.cancelled }
            let n = read(inFD, buffer, Self.chunk)
            if n < 0 { throw CopyError.read(src.lastPathComponent) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
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
        return hasher.finalize()
    }

    private func hash(_ url: URL, buffer: UnsafeMutableRawPointer, progress: (Int64) -> Void) throws -> SHA256.Digest {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CopyError.open(url.lastPathComponent) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        while true {
            if isCancelled { throw CopyError.cancelled }
            let n = read(fd, buffer, Self.chunk)
            if n < 0 { throw CopyError.read(url.lastPathComponent) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            progress(Int64(n))
        }
        return hasher.finalize()
    }
}
