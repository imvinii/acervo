// Relatórios de cada importação: PDF para guardar/enviar ao cliente e ASC MHL,
// a lista de checksums no padrão do mercado (lida por Silverstack, ShotPut, OffShoot e pela
// ferramenta oficial `ascmhl`).

import AppKit
import CryptoKit

enum Reports {
    /// Escreve o PDF e o ASC MHL conforme os Ajustes. Devolve avisos (nunca interrompe a importação).
    static func write(_ r: ImportReport, cfg: Config) -> [String] {
        guard !r.entries.isEmpty || !r.plan.duplicates.isEmpty || !r.failures.isEmpty else { return [] }
        var warnings: [String] = []
        let stamp = Self.stamp(r.start)
        if cfg.mhl {
            for (i, root) in r.plan.roots.enumerated() where FileManager.default.fileExists(atPath: root.path) && !r.entries.isEmpty {
                do { try MHL.addGeneration(root: root, entries: r.entries, index: i, date: r.end) }
                catch { warnings.append(L("ASC MHL em {0}: {1}", Volume.name(of: root), error.localizedDescription)) }
            }
        }
        if cfg.reportPDF {
            let name = "\(stamp) - \(r.plan.capture).pdf"
            let targets: [URL] = cfg.reportFolder.isEmpty
                ? r.plan.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
                    .map { $0.appendingPathComponent(L("Relatórios")).appendingPathComponent(name) }
                : [URL(fileURLWithPath: cfg.reportFolder).appendingPathComponent(name)]
            for t in targets {
                do {
                    try FileManager.default.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try PDFReport.write(r, to: t)
                } catch {
                    warnings.append(L("Relatório em {0}: {1}", t.deletingLastPathComponent().path, error.localizedDescription))
                }
            }
        }
        return warnings
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH'h'mm"
        return f.string(from: d)
    }

    /// Discos diferentes que têm uma cópia conferida de tudo (para o aviso "seguro para formatar").
    static func verifiedDisks(_ r: ImportReport) -> [String] {
        guard r.failures.isEmpty, !r.cancelled else { return [] }
        var out: [String] = []
        for root in r.plan.roots {
            let d = Volume.name(of: root)
            if !out.contains(d) { out.append(d) }
        }
        return out
    }
}

// MARK: - ASC MHL

/// Histórico ASC MHL v2.0 (https://theasc.com/asc/asc-media-hash-list): cada importação
/// acrescenta uma "geração" em <captação>/ascmhl/ com o xxHash64 dos arquivos que entraram,
/// e o ascmhl_chain.xml encadeia as gerações (cada uma com a sua impressão C4).
enum MHL {
    static func addGeneration(root: URL, entries: [FileEntry], index: Int, date: Date) throws {
        let dir = root.appendingPathComponent("ascmhl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let seq = (existing.compactMap { n -> Int? in
            guard n.hasSuffix(".mhl") else { return nil }
            return Int(n.prefix(4))
        }.max() ?? 0) + 1

        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd_HHmmss"
        let fileName = String(format: "%04d", seq) + "_\(root.lastPathComponent)_\(utc.string(from: date))Z.mhl"

        let rootPath = root.standardizedFileURL.path + "/"
        var hashes = ""
        for e in entries where e.targets.count > index {
            let full = e.targets[index].standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            let rel = String(full.dropFirst(rootPath.count))
            hashes += """
                <hash>
                  <path size="\(e.size)" lastmodificationdate="\(iso(e.modified))">\(xml(rel))</path>
                  <xxh64 action="original" hashdate="\(iso(e.hashDate))">\(e.hash)</xxh64>
                </hash>

            """
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(iso(date))</creationdate>
            <hostname>\(xml(ProcessInfo.processInfo.hostName))</hostname>
            <tool version="\(xml(version))">\(xml(AppInfo.name))</tool>
          </creatorinfo>
          <processinfo>
            <process>in-place</process>
            <ignore>
              <pattern>.DS_Store</pattern>
              <pattern>ascmhl</pattern>
              <pattern>ascmhl/</pattern>
            </ignore>
          </processinfo>
          <hashes>
        \(hashes)  </hashes>
        </hashlist>

        """
        let data = Data(manifest.utf8)
        try data.write(to: dir.appendingPathComponent(fileName), options: .withoutOverwriting)

        // Corrente: acrescenta esta geração
        let chainURL = dir.appendingPathComponent("ascmhl_chain.xml")
        let entry = """
          <hashlist sequencenr="\(seq)">
            <path>\(xml(fileName))</path>
            <c4>\(c4(data))</c4>
          </hashlist>

        """
        var chain = (try? String(contentsOf: chainURL, encoding: .utf8)) ?? """
        <?xml version="1.0" encoding="UTF-8"?>
        <ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">
        </ascmhldirectory>

        """
        guard let end = chain.range(of: "</ascmhldirectory>") else { throw CocoaError(.fileReadCorruptFile) }
        chain.insert(contentsOf: entry, at: end.lowerBound)
        try Data(chain.utf8).write(to: chainURL, options: .atomic)
    }

    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: d)
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Impressão C4 (SMPTE ST 2114): SHA-512 em base58, com o prefixo "c4", 90 caracteres.
    static func c4(_ data: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var num = Array(SHA512.hash(data: data))
        var out: [Character] = []
        while num.contains(where: { $0 != 0 }) {
            var rem = 0
            var next: [UInt8] = []
            for b in num {
                let acc = rem * 256 + Int(b)
                let q = acc / 58
                rem = acc % 58
                if !next.isEmpty || q != 0 { next.append(UInt8(q)) }
            }
            out.append(alphabet[rem])
            num = next
        }
        let body = String(out.reversed())
        return "c4" + String(repeating: "1", count: max(0, 88 - body.count)) + body
    }
}

// MARK: - PDF

enum PDFReport {
    static func write(_ r: ImportReport, to url: URL) throws {
        guard let w = PDFWriter(url: url) else { throw CocoaError(.fileWriteUnknown) }
        let bold = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let body = NSFont.systemFont(ofSize: 10)
        let small = NSFont.systemFont(ofSize: 8)
        let mono = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .regular)
        let gray = NSColor(white: 0.4, alpha: 1)
        let accent = NSColor(red: 0.91, green: 0.36, blue: 0.20, alpha: 1)
        let ok = r.failures.isEmpty && !r.cancelled
        let df = DateFormatter()
        df.locale = Lang.locale
        df.dateStyle = .long
        df.timeStyle = .short

        w.text(L("Relatório de importação"), font: .systemFont(ofSize: 20, weight: .bold))
        w.text("\(AppInfo.name) · \(df.string(from: r.end))", font: body, color: gray)
        w.space(10)
        w.text(r.plan.capture, font: .systemFont(ofSize: 14, weight: .semibold), color: accent)
        w.space(8)

        // Resumo
        let disks = Reports.verifiedDisks(r)
        let status: String
        if !ok { status = r.cancelled ? L("Importação cancelada") : L("Terminou com erros") }
        else if disks.count >= 2 { status = L("Seguro para formatar: cada arquivo está conferido em {0} discos ({1}).", disks.count, disks.joined(separator: ", ")) }
        else { status = L("Concluído com 1 cópia ({0}). Para formatar com segurança, tenha uma segunda cópia em outro disco.", disks.first ?? "") }
        let statusColor = !ok ? NSColor.systemRed : (disks.count >= 2 ? NSColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1) : NSColor(red: 0.85, green: 0.45, blue: 0.0, alpha: 1))
        w.text(status, font: bold, color: statusColor)
        w.space(8)
        let rows: [(String, String)] = [
            (L("Início"), df.string(from: r.start)),
            (L("Fim"), df.string(from: r.end)),
            (L("Duração"), Fmt.duration(r.seconds)),
            (L("Copiados e conferidos"), "\(Fmt.files(r.verified)) · \(Fmt.bytes(r.bytes))"),
            (L("Já importados antes (não copiados)"), Fmt.files(r.skipped)),
            (L("Com problema"), Fmt.files(r.failures.count)),
            (L("Conferência"), L("xxHash64; cada cópia é relida do disco e comparada com o original")),
        ]
        for (k, v) in rows { w.pair(k, v, font: body, keyColor: gray) }
        w.space(10)

        // Cartões
        w.heading(L("Cartões"), font: bold)
        let byCard = Dictionary(grouping: r.entries, by: \.cardName)
        let cardNames = Array(Set(r.entries.map(\.cardName) + r.plan.duplicates.map(\.source.cardName))).sorted()
        for c in cardNames {
            let e = byCard[c] ?? []
            w.pair(c, "\(Fmt.files(e.count)) · \(Fmt.bytes(e.reduce(0) { $0 + $1.size }))", font: body, keyColor: .black)
        }
        w.space(10)

        // Destinos
        w.heading(L("Destinos"), font: bold)
        for (i, root) in r.plan.roots.enumerated() {
            w.pair(i == 0 ? L("Disco principal") : L("Redundância"),
                   "\(Volume.name(of: root)) · \(root.path)", font: body, keyColor: gray)
        }
        w.space(10)

        // Arquivos
        w.heading(L("Arquivos copiados"), font: bold)
        let cols: [(String, CGFloat)] = [(L("Nome final"), 0.40), (L("Original no cartão"), 0.24), (L("Tamanho"), 0.1), ("xxHash64", 0.26)]
        let root = (r.plan.roots.first?.standardizedFileURL.path ?? "") + "/"
        w.tableHeader(cols, font: NSFont.systemFont(ofSize: 7.5, weight: .semibold), color: gray)
        for e in r.entries {
            // Caminho dentro da captação (mostra a subpasta, ex.: Vídeos/CAM A/…)
            let full = e.targets.first?.standardizedFileURL.path ?? ""
            let rel = full.hasPrefix(root) ? String(full.dropFirst(root.count)) : (e.targets.first?.lastPathComponent ?? "")
            w.tableRow([rel, "\(e.cardName)/\(e.source.lastPathComponent)", Fmt.bytes(e.size), e.hash],
                       widths: cols.map(\.1), font: mono)
        }
        if r.entries.isEmpty { w.text("—", font: body, color: gray) }

        if !r.plan.duplicates.isEmpty {
            w.space(10)
            w.heading(L("Já estavam no disco (não copiados de novo)"), font: bold)
            for d in r.plan.duplicates {
                w.tableRow(["\(d.source.cardName)/\(d.source.url.lastPathComponent)", "= \(d.capture)/\(d.existing.lastPathComponent)"],
                           widths: [0.35, 0.65], font: mono)
            }
        }
        if !r.failures.isEmpty {
            w.space(10)
            w.heading(L("Com problema"), font: bold, color: .systemRed)
            for f in r.failures { w.text(f, font: mono) }
        }
        w.space(14)
        w.text(L("Gerado pelo {0}. O registro ASC MHL (pasta ascmhl, dentro da captação) guarda os mesmos checksums no padrão do mercado.", AppInfo.name),
               font: small, color: gray)
        w.finish()
    }
}

/// Desenho simples de PDF em várias páginas (A4), com texto que quebra linha e tabela.
final class PDFWriter {
    private let ctx: CGContext
    private var page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let margin: CGFloat = 42
    private var y: CGFloat = 0
    private var pageNumber = 0
    private var open = false

    init?(url: URL) {
        guard let c = CGContext(url as CFURL, mediaBox: &page, nil) else { return nil }
        ctx = c
        newPage()
    }

    private var width: CGFloat { page.width - margin * 2 }

    private func attributed(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
    }

    private func newPage() {
        if open { footer(); ctx.endPDFPage() }
        ctx.beginPDFPage(nil)
        open = true
        pageNumber += 1
        y = page.height - margin
    }

    private func footer() {
        let line = CTLineCreateWithAttributedString(attributed("\(AppInfo.name) · \(pageNumber)", .systemFont(ofSize: 7), .gray))
        ctx.textPosition = CGPoint(x: margin, y: margin / 2)
        CTLineDraw(line, ctx)
    }

    private func ensure(_ h: CGFloat) { if y - h < margin + 10 { newPage() } }

    func space(_ h: CGFloat) { y -= h }

    func text(_ s: String, font: NSFont, color: NSColor = .black, x: CGFloat = 0, w: CGFloat? = nil) {
        let a = attributed(s, font, color)
        let fs = CTFramesetterCreateWithAttributedString(a)
        let width = w ?? self.width - x
        let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let h = ceil(size.height)
        ensure(h)
        let path = CGPath(rect: CGRect(x: margin + x, y: y - h, width: width, height: h), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(), path, nil), ctx)
        y -= h + 2
    }

    func heading(_ s: String, font: NSFont, color: NSColor = .black) {
        ensure(30)
        text(s, font: font, color: color)
        ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: y))
        ctx.addLine(to: CGPoint(x: page.width - margin, y: y))
        ctx.strokePath()
        y -= 4
    }

    func pair(_ k: String, _ v: String, font: NSFont, keyColor: NSColor) {
        let top = y
        text(k, font: font, color: keyColor, x: 0, w: 170)
        let afterKey = y
        y = top
        text(v, font: font, x: 175)
        y = min(y, afterKey)
    }

    func tableHeader(_ cols: [(String, CGFloat)], font: NSFont, color: NSColor) {
        tableRow(cols.map(\.0), widths: cols.map(\.1), font: font, color: color)
    }

    /// Uma linha da tabela; cada célula é cortada com "…" se não couber.
    func tableRow(_ cells: [String], widths: [CGFloat], font: NSFont, color: NSColor = .black) {
        let h = ceil(font.ascender - font.descender + font.leading) + 3
        ensure(h)
        var x = margin
        for (cell, fraction) in zip(cells, widths) {
            let w = width * fraction - 6
            let line = CTLineCreateWithAttributedString(attributed(cell, font, color))
            let ellipsis = CTLineCreateWithAttributedString(attributed("…", font, color))
            let fit = CTLineCreateTruncatedLine(line, Double(w), .middle, ellipsis) ?? line
            ctx.textPosition = CGPoint(x: x, y: y - font.ascender)
            CTLineDraw(fit, ctx)
            x += width * fraction
        }
        y -= h
    }

    func finish() {
        footer()
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
