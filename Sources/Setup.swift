// Ajustes: disco principal, discos de redundância, pastas e padrões de nome.
// Aparece sozinho na primeira abertura; depois, pela engrenagem ou em Ajustes… (⌘,).

import SwiftUI
import AppKit

struct SetupView: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Config
    @State private var volumes = Volume.mounted()
    let firstRun: Bool

    init(config: Config, firstRun: Bool) {
        _draft = State(initialValue: config)
        self.firstRun = firstRun
    }

    /// Captação de exemplo para as prévias.
    var sample: Capture {
        Capture(name: Capture.folderName(draft, date: Date(), title: L("CASAMENTO ANA")), matcher: Pattern.Matcher(draft.folderPattern))
    }

    var problem: String? {
        if draft.inbox.isEmpty { return L("Escolha o disco principal.") }
        if Capture.folderName(draft, date: Date(), title: "X").isEmpty { return L("O nome da pasta da captação não pode ficar vazio.") }
        if draft.backups.contains(draft.inbox) { return L("A redundância precisa ser uma pasta diferente da do disco principal.") }
        if draft.receivingFolders.isEmpty { return L("Pelo menos uma subpasta precisa receber arquivos.") }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(firstRun ? L("Bem-vindo ao {0}", AppInfo.name) : L("Ajustes")).font(.title2.bold())
                Text(firstRun
                     ? L("Antes de começar, diga onde guardar as gravações e como organizar as pastas e os arquivos. Dá para mudar tudo depois em Ajustes (⌘,).")
                     : L("As mudanças valem para as próximas importações. Nada que já foi importado é renomeado."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)

            Form {
                mainDiskSection
                backupSection
                foldersSection
                filesSection
                ignoredSection
            }
            .formStyle(.grouped)

            HStack {
                Menu(L("Começar de um modelo")) {
                    Button(L("Simples (Vídeos, Fotos, Áudios, Documentos)")) { apply(.simple) }
                    Button(L("Vértice (Vídeos, Fotos/Brutas, Fotos/Seleção, Áudios, Documentos)")) { apply(.vertice) }
                }
                .fixedSize()
                Spacer()
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                if firstRun {
                    // A tela de boas-vindas não fecha sozinha; sem isto não daria para sair do app.
                    Button(L("Sair")) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                    }
                } else {
                    Button(L("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Button(firstRun ? L("Começar") : L("Salvar")) {
                    model.config = draft
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(problem != nil)
            }
            .padding(20)
        }
        .frame(width: 780, height: 740)
        .interactiveDismissDisabled(firstRun)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in volumes = Volume.mounted() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in volumes = Volume.mounted() }
    }

    /// Aplica pastas e nomes de um modelo, mantendo os discos já escolhidos.
    func apply(_ preset: Config) {
        var c = preset
        let fm = FileManager.default
        // Discos do modelo só entram se ainda não houver um escolhido e eles existirem neste Mac.
        c.inbox = draft.inbox.isEmpty && fm.fileExists(atPath: preset.inbox) ? preset.inbox : draft.inbox
        c.backups = draft.backups.isEmpty ? preset.backups.filter { fm.fileExists(atPath: $0) } : draft.backups
        c.ignoredVolumes = Array(Set(draft.ignoredVolumes + preset.ignoredVolumes.filter { n in volumes.contains { $0.name == n } }))
        draft = c
    }

    // MARK: Disco principal

    var mainDiskSection: some View {
        Section {
            HStack(alignment: .center) {
                DiskInfo(path: draft.inbox, empty: L("Nenhum disco escolhido"))
                Spacer()
                DiskMenu(title: draft.inbox.isEmpty ? L("Escolher disco") : L("Trocar disco"), volumes: volumes,
                         purpose: L("do disco principal")) { draft.inbox = $0 }
            }
        } header: {
            SectionHeader(L("Disco principal"),
                          L("Onde o backup é feito. Cada gravação vira uma pasta aqui dentro, com os arquivos do cartão já organizados."))
        }
    }

    // MARK: Redundância

    var backupSection: some View {
        Section {
            ForEach(draft.backups, id: \.self) { b in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        DiskInfo(path: b, empty: "")
                        Spacer()
                        Button { draft.backups.removeAll { $0 == b } } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.red).help(L("Remover"))
                    }
                    if !draft.inbox.isEmpty, Volume.name(of: URL(fileURLWithPath: b)) == Volume.name(of: URL(fileURLWithPath: draft.inbox)) {
                        Label(L("Está no mesmo disco do principal: se esse disco falhar, as duas cópias se perdem."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            DiskMenu(title: L("Adicionar disco de redundância"), systemImage: "plus.circle.fill", volumes: volumes,
                     purpose: L("da redundância")) { path in
                if !draft.backups.contains(path) { draft.backups.append(path) }
            }
        } header: {
            SectionHeader(L("Discos de redundância (opcional)"),
                          L("Cópias idênticas em outros discos, com a mesma pasta e os mesmos nomes. Se um disco falhar, os arquivos continuam seguros no outro. Na hora de importar dá para ligar ou desligar cada um."))
        }
    }

    // MARK: Pastas

    var foldersSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Nome da pasta:")).fixedSize().frame(minWidth: 110, alignment: .leading)
                    TextField("", text: $draft.folderPattern, prompt: Text("\(Tok.year){MM}{DD} - \(Tok.name)"))
                        .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading).font(.body.monospaced())
                    PresetMenu(presets: [
                        ("20261027 - \(L("NOME"))", "\(Tok.year){MM}{DD} - \(Tok.name)"),
                        ("2026-10-27 \(L("NOME"))", "\(Tok.year)-{MM}-{DD} \(Tok.name)"),
                        ("\(L("NOME")) - 27.10.2026", "\(Tok.name) - {DD}.{MM}.\(Tok.year)"),
                        ("261027_\(L("NOME"))", "\(Tok.shortYear){MM}{DD}_\(Tok.name)"),
                        (L("Só o nome"), Tok.name),
                    ]) { draft.folderPattern = $0 }
                }
                ExampleLine(sample.name)
                Text(L("Escreva como quiser: o texto fica igual e as etiquetas entre chaves são trocadas na hora. {0} é o nome que você digita ao criar a captação; {1} {MM} {DD}, a data da gravação.", Tok.name, Tok.year))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            // Cada linha acessa a subpasta pelo id (não pela posição na lista): assim, apagar
            // uma linha não faz as outras lerem uma posição que deixou de existir.
            ForEach(draft.folders.map(\.id), id: \.self) { id in
                SubfolderRow(folder: folderBinding(id)) { removeFolder(id) }
            }
            Button { draft.folders.append(Subfolder("", nil)) } label: {
                Label(L("Adicionar subpasta"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
        } header: {
            SectionHeader(L("Pasta de cada captação"),
                          L("Como o app cria a pasta de cada gravação e as subpastas que vão dentro dela. Cada subpasta recebe os tipos de arquivo que você escolher."))
        } footer: {
            Text(L("Em “recebe”, escreva a extensão dos arquivos que vão para essa subpasta, que são as letras depois do ponto no nome (ex.: Arte.psd → psd). Siga o formato das outras linhas: só as letras, separadas por vírgula (ex.: psd, ai). Ou escolha um tipo pronto na lista ao lado. Sem extensões, a subpasta é criada vazia. Arquivos de tipos que não estão em nenhuma subpasta ficam no cartão. Use / para uma subpasta dentro de outra (ex.: Fotos/Brutas). Clique no ícone para trocá-lo."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Arquivos

    var filesSection: some View {
        Section {
            Toggle(isOn: $draft.rename) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Renomear os arquivos ao importar"))
                    Text(L("Usa o nome da pasta da captação (ou o padrão que você definir abaixo). Desmarcado, cada arquivo mantém o nome que veio do cartão, ex.: C0001.MP4."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Group {
                ForEach(draft.receivingFolders) { f in
                    NamingRow(folder: f, own: ownPattern(f), config: draft, sample: sample)
                }
            }
            .disabled(!draft.rename)
            .opacity(draft.rename ? 1 : 0.45)
        } header: {
            SectionHeader(L("Nome dos arquivos"),
                          L("Como os arquivos ficam depois de importados. Com Renomear marcado, todos levam o nome da pasta da captação e um número. Para um tipo de arquivo seguir outro padrão, ligue “Padrão próprio” na linha dele."))
        } footer: {
            Text(L("Etiquetas: {0} nome da pasta da captação · {1} só o nome · {2} {MM} {DD} data · {NNN} número com 3 dígitos (use {N}, {NN}, {NNNN}… para outros tamanhos; continua de onde a pasta parou) · {ORIGINAL} nome do arquivo no cartão. A extensão (.MP4, .WAV…) entra sozinha.", Tok.folder, Tok.name, Tok.year))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func folderBinding(_ id: UUID) -> Binding<Subfolder> {
        Binding(
            get: { draft.folders.first { $0.id == id } ?? Subfolder("", nil) },
            set: { f in if let i = draft.folders.firstIndex(where: { $0.id == id }) { draft.folders[i] = f } })
    }

    func removeFolder(_ id: UUID) {
        draft.rules.removeAll { $0.folder == id }
        draft.folders.removeAll { $0.id == id }
    }

    /// Padrão próprio de uma subpasta (nil = segue o padrão geral).
    func ownPattern(_ f: Subfolder) -> Binding<String?> {
        Binding(
            get: { draft.rules.first { $0.folder == f.id }?.pattern },
            set: { p in
                if let p {
                    if let i = draft.rules.firstIndex(where: { $0.folder == f.id }) { draft.rules[i].pattern = p }
                    else { draft.rules.append(NamingRule(folder: f.id, pattern: p)) }
                } else {
                    draft.rules.removeAll { $0.folder == f.id }
                }
            })
    }

    // MARK: Discos ignorados

    var ignoredSection: some View {
        Section {
            ForEach(draft.ignoredVolumes, id: \.self) { v in
                HStack {
                    Label(v, systemImage: "externaldrive.fill")
                    Spacer()
                    Button { draft.ignoredVolumes.removeAll { $0 == v } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.red).help(L("Remover"))
                }
            }
            let candidates = volumes.filter { $0.url.path != "/" && !draft.ignoredVolumes.contains($0.name) }
            Menu {
                ForEach(candidates) { v in
                    Button("\(v.name)  ·  \(L("{0} livres", Fmt.bytes(v.free)))") { draft.ignoredVolumes.append(v.name) }
                }
                if candidates.isEmpty { Text(L("Nenhum outro disco conectado")) }
            } label: {
                Label(L("Adicionar disco"), systemImage: "plus.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            SectionHeader(L("Discos que não aparecem como cartão"),
                          L("O app mostra como cartão todo disco removível que for conectado. Para não correr o risco de importar (ou limpar) os arquivos de um disco de trabalho, coloque aqui os discos que são seguros e nunca são cartões, como SSDs e HDs de backup. Os discos principal e de redundância já ficam de fora sozinhos."))
        } footer: {
            Text(L("Dica: na lista de cartões, clique num disco com o botão direito para escondê-lo."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Peças

struct SectionHeader: View {
    let title: String
    let subtitle: String
    init(_ title: String, _ subtitle: String) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

struct ExampleLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 4) {
            Text(L("Exemplo:")).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
    }
}

/// Disco e pasta escolhidos, com o espaço livre.
struct DiskInfo: View {
    let path: String
    let empty: String

    var body: some View {
        let url = URL(fileURLWithPath: path)
        let connected = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        HStack(spacing: 10) {
            Image(systemName: path.isEmpty ? "externaldrive.badge.questionmark" : "externaldrive.fill")
                .font(.system(size: 22))
                .foregroundStyle(path.isEmpty ? Color.secondary : (connected ? Color.accentColor : Color.orange))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                if path.isEmpty {
                    Text(empty).foregroundStyle(.secondary)
                } else {
                    Text(Volume.name(of: url)).font(.body.weight(.semibold))
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(connected ? L("{0} livres", Fmt.bytes(Int64(free))) : L("Não está conectado agora"))
                        .font(.caption).foregroundStyle(connected ? Color.secondary : Color.orange)
                }
            }
        }
    }
}

/// Lista dos discos conectados; ao escolher um, abre a janela para escolher (ou criar) a pasta dentro dele.
struct DiskMenu: View {
    let title: String
    var systemImage: String? = nil
    let volumes: [Volume]
    let purpose: String
    let onPick: (String) -> Void

    var body: some View {
        if systemImage == nil { menu.menuStyle(.button) } else { menu.menuStyle(.borderlessButton) }
    }

    var menu: some View {
        Menu {
            Section(L("Discos conectados")) {
                ForEach(volumes) { v in
                    Button("\(v.name)  ·  \(L("{0} livres", Fmt.bytes(v.free)))") { choose(in: v) }
                }
            }
            Divider()
            Button(L("Outra pasta…")) { choose(in: nil) }
        } label: {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .fixedSize()
    }

    func choose(in volume: Volume?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Usar esta pasta")
        panel.message = volume.map { L("Escolha ou crie, no disco {0}, a pasta {1}. Ex.: uma pasta “Inbox”.", $0.name, purpose) }
            ?? L("Escolha ou crie a pasta {0}.", purpose)
        if let volume { panel.directoryURL = volume.url }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(url.standardizedFileURL.path)
    }
}

/// Modelos prontos para um campo de padrão.
struct PresetMenu: View {
    let presets: [(String, String)]
    let onPick: (String) -> Void
    var body: some View {
        Menu {
            ForEach(presets, id: \.1) { p in
                Button("\(p.0)    \(p.1)") { onPick(p.1) }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Modelos prontos"))
    }
}

/// Linha "Subpasta: [nome]  recebe: [extensões] [modelos] [–]".
struct SubfolderRow: View {
    @Binding var folder: Subfolder
    let onRemove: () -> Void
    @State private var extText: String

    init(folder: Binding<Subfolder>, onRemove: @escaping () -> Void) {
        _folder = folder
        self.onRemove = onRemove
        _extText = State(initialValue: folder.wrappedValue.extensions.joined(separator: ", "))
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L("Automático (pelo tipo de arquivo)")) { folder.icon = nil }
                Divider()
                ForEach(Subfolder.icons, id: \.0) { icon in
                    Button { folder.icon = icon.0 } label: { Label(icon.1, systemImage: icon.0) }
                }
            } label: {
                Image(systemName: folder.symbol)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Escolher ícone"))
            Text(L("Subpasta:")).fixedSize().frame(minWidth: 70, alignment: .leading)
            TextField("", text: $folder.path, prompt: Text(L("nome da subpasta")))
                .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
            Text(L("recebe:")).foregroundStyle(.secondary)
            TextField("", text: $extText, prompt: Text(L("extensões, ex.: psd, ai")))
                .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
                .frame(width: 230)
                .onChange(of: extText) { _, t in folder.extensions = Subfolder.parse(t) }
            Menu {
                ForEach(FileType.allCases, id: \.self) { t in
                    Button("\(t.name)  (\(t.extensions.joined(separator: ", ")))") {
                        extText = t.extensions.joined(separator: ", ")
                        if folder.trimmedPath.isEmpty { folder.path = t.name }
                    }
                }
                Divider()
                Button(L("Nada (pasta vazia)")) { extText = "" }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Tipos de arquivo"))
            Button(action: onRemove) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.red).help(L("Remover subpasta"))
        }
    }
}

/// Linha de uma subpasta em "Nome dos arquivos": segue o padrão geral ou, com
/// "Padrão próprio" ligado, mostra o campo para escrever outro padrão.
struct NamingRow: View {
    let folder: Subfolder
    @Binding var own: String?
    let config: Config
    let sample: Capture

    init(folder: Subfolder, own: Binding<String?>, config: Config, sample: Capture) {
        self.folder = folder
        _own = own
        self.config = config
        self.sample = sample
    }

    static var presets: [(String, String)] {[
        ("\(L("CAPTAÇÃO")) - 001", "\(Tok.folder) - {NNN}"),
        ("\(L("CAPTAÇÃO")).1", "\(Tok.folder).{N}"),
        ("\(L("NOME"))_0001", "\(Tok.name)_{NNNN}"),
        ("20261027_001", "\(Tok.year){MM}{DD}_{NNN}"),
        ("\(L("CAPTAÇÃO")) - \(L("nome original"))", "\(Tok.folder) - {ORIGINAL}"),
        (L("Nome original da câmera"), "{ORIGINAL}"),
    ]}

    /// Nome de arquivo de exemplo para os tipos da subpasta.
    static func sampleFile(_ f: Subfolder) -> URL {
        let name: String
        switch FileType.matching(f.extensions) {
        case .videos: name = "C0001.MP4"
        case .raw: name = "IMG_0001.CR3"
        case .jpg: name = "IMG_0001.JPG"
        case .audios: name = "ZOOM0001.WAV"
        case .documentos: name = "Roteiro.pdf"
        case .design: name = "Arte.psd"
        case nil: name = "ARQUIVO.\((f.extensions.first ?? "dat").uppercased())"
        }
        return URL(fileURLWithPath: name)
    }

    var pattern: String { own ?? Config.defaultFilePattern }

    var example: String {
        var c = config
        c.rename = true
        c.rules = own.map { [NamingRule(folder: folder.id, pattern: $0)] } ?? []
        let src = Self.sampleFile(folder)
        let first = Naming.fileName(c, folder: folder, capture: sample, number: 1, source: src, date: Date())
        guard Pattern.hasNumber(pattern) else { return "\(src.lastPathComponent) → \(first)" }
        let second = Naming.fileName(c, folder: folder, capture: sample, number: 2, source: src, date: Date())
        return "\(first), \(second)…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: folder.symbol).foregroundStyle(.secondary).frame(width: 18)
                Text(folder.trimmedPath).font(.body.weight(.medium))
                Spacer()
                Text(L("Padrão próprio")).font(.callout).foregroundStyle(.secondary)
                Toggle(L("Padrão próprio"), isOn: Binding(
                    get: { own != nil },
                    set: { on in own = on ? "\(Tok.folder) - {NNN}" : nil }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            if own != nil {
                HStack(spacing: 8) {
                    TextField("", text: Binding(get: { own ?? "" }, set: { own = $0 }), prompt: Text("\(Tok.folder) - {NNN}"))
                        .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading).font(.body.monospaced())
                    PresetMenu(presets: Self.presets) { own = $0 }
                }
                .padding(.leading, 26)
            }
            ExampleLine(example).padding(.leading, 26)
            if let own, !own.isEmpty, !Pattern.hasNumber(own), !Pattern.hasOriginal(own) {
                Text(L("Sem número nem {ORIGINAL}, os arquivos vão ganhar (2), (3)… no fim.")).font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }
}
