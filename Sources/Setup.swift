// Ajustes: discos de destino e de redundância, pastas e padrões de nome.
// Aparece sozinho na primeira abertura; depois, em Importar Cartão > Ajustes… (⌘,).

import SwiftUI
import AppKit

struct SetupView: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Config
    let firstRun: Bool

    init(config: Config, firstRun: Bool) {
        _draft = State(initialValue: config)
        self.firstRun = firstRun
    }

    /// Captação de exemplo para as prévias.
    var sample: Capture { Capture(name: Capture.folderName(draft, date: Date(), title: "CASAMENTO ANA"), matcher: Pattern.Matcher(draft.folderPattern)) }

    var problem: String? {
        if draft.inbox.isEmpty { return "Escolha o destino principal." }
        if Capture.folderName(draft, date: Date(), title: "X").isEmpty { return "O nome da pasta da captação não pode ficar vazio." }
        if !draft.backup.isEmpty, draft.backup == draft.inbox { return "A redundância precisa ser uma pasta diferente do destino principal." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(firstRun ? "Bem-vindo ao Importar Cartão" : "Ajustes").font(.title2.bold())
                Text(firstRun
                     ? "Antes de começar, diga onde guardar as gravações e como nomear as pastas e os arquivos. Dá para mudar tudo depois em Ajustes (⌘,)."
                     : "Mudanças valem para as próximas importações. Nada que já foi importado é renomeado.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)

            Form {
                disksSection
                foldersSection
                filesSection
                if !draft.ignoredVolumes.isEmpty { hiddenSection }
            }
            .formStyle(.grouped)

            HStack {
                Menu("Começar de um modelo") {
                    Button("Simples (Vídeos, Fotos, Áudios, Documentos)") { apply(.simple) }
                    Button("Vértice (Vídeos, Fotos/Brutas, Fotos/Seleção, Lapela)") { apply(.vertice) }
                }
                .fixedSize()
                Spacer()
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                if !firstRun { Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button(firstRun ? "Começar" : "Salvar") {
                    model.config = draft
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(problem != nil)
            }
            .padding(20)
        }
        .frame(width: 680, height: 720)
        .interactiveDismissDisabled(firstRun)
    }

    /// Aplica pastas e nomes de um modelo, mantendo os discos já escolhidos.
    func apply(_ preset: Config) {
        var c = preset
        let fm = FileManager.default
        // Discos do modelo só entram se ainda não houver um escolhido e eles existirem neste Mac.
        c.inbox = draft.inbox.isEmpty && fm.fileExists(atPath: preset.inbox) ? preset.inbox : draft.inbox
        c.backup = draft.backup.isEmpty && fm.fileExists(atPath: preset.backup) ? preset.backup : draft.backup
        c.ignoredVolumes = draft.ignoredVolumes
        draft = c
    }

    // MARK: Discos

    var disksSection: some View {
        Section {
            FolderPicker(title: "Destino principal",
                         help: "Onde ficam as pastas das captações. Ex.: o SSD de mídias.",
                         path: $draft.inbox, optional: false)
            FolderPicker(title: "Redundância (opcional)",
                         help: "Um segundo disco que recebe uma cópia idêntica, para proteção. Na hora de importar dá para ligar ou desligar.",
                         path: $draft.backup, optional: true)
            if !draft.backup.isEmpty, !draft.inbox.isEmpty,
               Model.diskName(URL(fileURLWithPath: draft.backup)) == Model.diskName(URL(fileURLWithPath: draft.inbox)) {
                Label("A redundância está no mesmo disco do destino principal: se esse disco falhar, as duas cópias se perdem.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Discos")
        }
    }

    // MARK: Pastas

    var foldersSection: some View {
        Section {
            PatternField(label: "Nome da pasta", text: $draft.folderPattern, presets: [
                ("20261027 - NOME", "{AAAA}{MM}{DD} - {NOME}"),
                ("2026-10-27 NOME", "{AAAA}-{MM}-{DD} {NOME}"),
                ("NOME - 27.10.2026", "{NOME} - {DD}.{MM}.{AAAA}"),
                ("261027_NOME", "{AA}{MM}{DD}_{NOME}"),
                ("Só o nome", "{NOME}"),
            ], example: sample.name)
            ForEach(Kind.allCases) { k in
                TextField("Subpasta de \(k.shortTitle.lowercased())", text: Binding(
                    get: { draft.subpaths[k.rawValue] ?? k.defaultSubpath },
                    set: { draft.subpaths[k.rawValue] = $0 }), prompt: Text(k.defaultSubpath))
            }
            TextField("Pastas extras (vazias)", text: Binding(
                get: { draft.extraFolders.joined(separator: ", ") },
                set: { draft.extraFolders = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                prompt: Text("ex.: Fotos/Seleção, Projeto"))
        } header: {
            Text("Pasta de cada captação")
        } footer: {
            Text("Use / para criar subpastas (ex.: Fotos/Brutas). A pasta de documentos só é criada quando houver documentos. Etiquetas: {NOME} nome que você digita, {AAAA} {AA} {MM} {DD} data da gravação.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Arquivos

    static let filePresets: [(String, String)] = [
        ("CAPTAÇÃO - 001", "{PASTA} - {NNN}"),
        ("CAPTAÇÃO.1", "{PASTA}.{N}"),
        ("NOME_0001", "{NOME}_{NNNN}"),
        ("20261027_001", "{AAAA}{MM}{DD}_{NNN}"),
        ("CAPTAÇÃO - nome original", "{PASTA} - {ORIGINAL}"),
        ("Nome original da câmera", "{ORIGINAL}"),
    ]
    static let sampleOriginals: [Kind: String] = [.videos: "C0001.MP4", .fotos: "IMG_0001.CR3", .audios: "ZOOM0001.WAV", .documentos: "Roteiro.pdf"]

    var filesSection: some View {
        Section {
            ForEach(Kind.allCases) { k in
                let pattern = Binding(get: { draft.filePatterns[k.rawValue] ?? "{ORIGINAL}" },
                                      set: { draft.filePatterns[k.rawValue] = $0 })
                let src = URL(fileURLWithPath: Self.sampleOriginals[k]!)
                let first = k.fileName(draft, capture: sample, number: 1, source: src, date: Date())
                let second = k.fileName(draft, capture: sample, number: 2, source: src, date: Date())
                PatternField(label: k.shortTitle, text: pattern, presets: Self.filePresets,
                             example: Pattern.hasNumber(draft.filePattern(k)) ? "\(first), \(second)…" : first,
                             warning: Pattern.hasNumber(pattern.wrappedValue) || pattern.wrappedValue.contains("{ORIGINAL}")
                                ? nil : "Sem número nem {ORIGINAL}, os arquivos vão ganhar (2), (3)… no fim.")
            }
        } header: {
            Text("Nome dos arquivos")
        } footer: {
            Text("Etiquetas: {PASTA} nome da pasta da captação · {NOME} só o nome · {AAAA} {MM} {DD} data · {NNN} número com 3 dígitos (use {N}, {NN}, {NNNN}… para outros tamanhos; continua de onde a pasta parou) · {ORIGINAL} nome do arquivo no cartão. A extensão (.MP4, .CR3…) entra sozinha.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Discos ocultos

    var hiddenSection: some View {
        Section {
            ForEach(draft.ignoredVolumes, id: \.self) { v in
                HStack {
                    Label(v, systemImage: "externaldrive")
                    Spacer()
                    Button("Mostrar de novo") { draft.ignoredVolumes.removeAll { $0 == v } }
                }
            }
        } header: {
            Text("Discos que não aparecem como cartão")
        } footer: {
            Text("Para esconder um disco da lista de cartões, clique nele com o botão direito.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Escolha de uma pasta, com o disco e o espaço livre.
struct FolderPicker: View {
    let title: String
    let help: String
    @Binding var path: String
    let optional: Bool

    var info: (String, Color) {
        guard !path.isEmpty else { return (optional ? "Sem redundância" : "Nenhuma pasta escolhida", .secondary) }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return ("Disco \(Model.diskName(url)) não está conectado agora", .orange)
        }
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return ("Disco \(Model.diskName(url)) · \(Fmt.bytes(Int64(free))) livres", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if optional && !path.isEmpty { Button("Remover") { path = "" } }
                Button("Escolher…", action: choose)
            }
            HStack(spacing: 6) {
                Image(systemName: path.isEmpty ? "externaldrive.badge.questionmark" : "externaldrive.fill")
                    .foregroundStyle(path.isEmpty ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    if !path.isEmpty { Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                    Text(info.0).font(.caption).foregroundStyle(info.1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Usar esta pasta"
        panel.message = "\(title): escolha (ou crie) a pasta onde as captações vão ficar"
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.standardizedFileURL.path
    }
}

/// Campo de padrão com modelos prontos e prévia do resultado.
struct PatternField: View {
    let label: String
    @Binding var text: String
    let presets: [(String, String)]
    let example: String
    var warning: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(label, text: $text)
                    .font(.body.monospaced())
                Menu {
                    ForEach(presets, id: \.1) { p in
                        Button("\(p.0)    \(p.1)") { text = p.1 }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Modelos prontos")
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                Text(example).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
        }
    }
}
