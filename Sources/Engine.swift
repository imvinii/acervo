// Motor do app: lista as captações, lê o cartão e copia com verificação.
// Nada aqui apaga, move ou renomeia arquivo do cartão: ele só é lido.

import Foundation
import CryptoKit

// MARK: - Caminhos (podem ser trocados para teste: -inbox <pasta> -backup <pasta>)

enum Paths {
    static var inbox: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: "inbox") ?? "/Volumes/Mídias/Inbox")
    }
    static var backup: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: "backup") ?? "/Volumes/Projetos/Inbox (BACKUP)")
    }
    /// Subpastas criadas numa captação nova (as mesmas do atalho "Criar projeto").
    static let captureSubfolders = ["Vídeos", "Fotos/Brutas", "Fotos/Seleção", "Lapela"]
}

// MARK: - Tipos de arquivo

enum Kind: String, CaseIterable, Identifiable, Sendable {
    case videos, fotos, lapela
    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: "Vídeos"
        case .fotos: "Fotos RAW"
        case .lapela: "Áudios de lapela"
        }
    }
    func label(_ n: Int) -> String {
        switch self {
        case .videos: n == 1 ? "1 vídeo" : "\(n) vídeos"
        case .fotos: n == 1 ? "1 foto RAW" : "\(n) fotos RAW"
        case .lapela: n == 1 ? "1 áudio de lapela" : "\(n) áudios de lapela"
        }
    }
    var symbol: String {
        switch self {
        case .videos: "video.fill"
        case .fotos: "camera.fill"
        case .lapela: "mic.fill"
        }
    }
    var extensions: Set<String> {
        switch self {
        case .videos: ["mp4", "mov"]
        case .fotos: ["cr2", "cr3", "arw"]
        case .lapela: ["wav"]
        }
    }
    /// Pasta de destino dentro da captação.
    var subpath: String {
        switch self {
        case .videos: "Vídeos"
        case .fotos: "Fotos/Brutas"
        case .lapela: "Lapela"
        }
    }
    /// Vídeos e fotos: "NOME - 001.MP4" (padrão dos atalhos).
    /// Lapela: "NOME.1.WAV" (padrão usado na organização das lapelas em 10/10/2026).
    func fileName(capture: String, number: Int, ext: String) -> String {
        switch self {
        case .lapela: "\(capture).\(number).\(ext)"
        default: "\(capture) - \(String(format: "%03d", number)).\(ext)"
        }
    }
    /// Lê o número de um arquivo já existente no destino, se seguir o padrão.
    func number(in fileName: String, capture: String) -> Int? {
        let stem = (fileName as NSString).deletingPathExtension
        let prefix = self == .lapela ? "\(capture)." : "\(capture) - "
        guard stem.hasPrefix(prefix) else { return nil }
        return Int(stem.dropFirst(prefix.count))
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

    init(name: String) {
        self.name = name
        // "20261020 - CC BEB Atividade Extra" (aceita também "20260925- ...")
        if let m = name.firstMatch(of: /^(\d{8})\s*-?\s*(.*)$/) {
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

    static func list(in inbox: URL) -> [Capture] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return sorted(dirs.map { Capture(name: $0.lastPathComponent) })
    }

    static func folderName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(f.string(from: date)) - \(title.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Cria a pasta da captação com as subpastas padrão. Não mexe em nada que já exista.
    static func create(named name: String, in inbox: URL) throws -> URL {
        let root = inbox.appendingPathComponent(name)
        for sub in Paths.captureSubfolders {
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
    let targets: [URL]      // Mídias (e, se marcado, o backup no Projetos)
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

    static func make(files: [SourceFile], kinds: Set<Kind>, capture: String,
                     inbox: URL, backup: URL?) -> ImportPlan {
        var plan = ImportPlan(capture: capture)
        let index = InboxIndex(inbox: inbox, kinds: kinds, preferring: capture)
        for kind in Kind.allCases where kinds.contains(kind) {
            let dest = inbox.appendingPathComponent(capture).appendingPathComponent(kind.subpath)
            let backupDest = backup?.appendingPathComponent(capture).appendingPathComponent(kind.subpath)
            let existing = names(in: dest)
            var used = Set(existing).union(names(in: backupDest))
            var number = (existing.compactMap { kind.number(in: $0, capture: capture) }.max() ?? 0) + 1

            for file in files where file.kind == kind {
                if let dup = index.match(file) {
                    plan.duplicates.append(dup)
                    continue
                }
                let ext = file.url.pathExtension.uppercased()
                var name = kind.fileName(capture: capture, number: number, ext: ext)
                while used.contains(name) {
                    number += 1
                    name = kind.fileName(capture: capture, number: number, ext: ext)
                }
                used.insert(name)
                number += 1
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

    init(inbox: URL, kinds: Set<Kind>, preferring capture: String) {
        let fm = FileManager.default
        let captures = (try? fm.contentsOfDirectory(atPath: inbox.path).filter { !$0.hasPrefix(".") }) ?? []
        // A captação escolhida vem primeiro, para o aviso apontar para ela quando o arquivo estiver nas duas.
        for c in captures.sorted(by: { a, _ in a == capture }) {
            for kind in kinds {
                let dir = inbox.appendingPathComponent(c).appendingPathComponent(kind.subpath)
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
