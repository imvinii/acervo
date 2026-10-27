// Importar Cartão: backup dos cartões depois de uma gravação.
// Substitui os atalhos "Criar projeto" e "Importar SD".

import SwiftUI
import AppKit
import UserNotifications

enum AppInfo {
    static let name = "Importar Cartão"
}

@main
struct ImportarCartaoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()
    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Ajustes…")) { model.showSetup = true }.keyboardShortcut(",")
            }
        }
    }
}

/// O app é uma janela só: fechar a janela encerra o app (antes ele ficava aberto, sem janela).
/// Durante uma cópia ou limpeza, pede confirmação antes de sair.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Model.isWorking else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Há uma cópia em andamento")
        alert.informativeText = L("Se sair agora, ela é interrompida. O que já foi copiado e conferido fica salvo; importar de novo continua de onde parou.")
        alert.addButton(withTitle: L("Continuar a cópia"))
        alert.addButton(withTitle: L("Sair mesmo assim"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

// MARK: - Estado

struct Card: Identifiable, Hashable {
    let url: URL
    let name: String
    let isFolder: Bool   // escolhida à mão, em vez de um cartão montado
    var id: URL { url }
}

@MainActor
final class Model: ObservableObject {
    /// Discos, pastas e padrões de nome. Sem configuração salva, abre os Ajustes na primeira abertura.
    @Published var config: Config {
        didSet {
            if oldValue != config {
                config.save()
                selected = selected.filter { id in config.receivingFolders.contains { $0.id == id } }
                reloadCaptures(); reloadCards()
                if let c = selectedCard { select(card: c) }
            }
        }
    }
    @Published var showSetup = false

    @Published var captures: [Capture] = []
    @Published var inboxAvailable = false
    @Published var selectedCapture: Capture? { didSet { if oldValue != selectedCapture { refreshPlan() } } }
    @Published var search = ""

    @Published var cards: [Card] = []
    @Published var selectedCard: Card?
    @Published var files: [SourceFile] = [] { didSet { refreshPlan() } }
    @Published var scanning = false

    /// Subpastas marcadas para importar.
    @Published var selected: Set<UUID> = [] { didSet { if oldValue != selected { refreshPlan() } } }
    /// Discos de redundância desmarcados na hora de importar (lembrados entre aberturas).
    @Published var backupsOff: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "redundanciasDesligadas") ?? []) {
        didSet { UserDefaults.standard.set(Array(backupsOff), forKey: "redundanciasDesligadas"); refreshPlan() }
    }

    /// O que vai ser copiado e o que já está no disco principal. Calculado em segundo plano,
    /// porque compara o cartão com os arquivos já importados.
    @Published var plan: ImportPlan?
    @Published var planning = false
    private var planGeneration = 0

    @Published var showDuplicateAlert = false
    @Published var showCleanConfirm = false

    enum Phase { case idle, copying, done(ImportReport), cleaning(ImportReport), cleaned(Copier.CleanupReport) }
    @Published var phase: Phase = .idle {
        didSet {
            switch phase { case .copying, .cleaning: Model.isWorking = true; default: Model.isWorking = false }
        }
    }
    static var isWorking = false
    @Published var progress: Copier.Progress?
    @Published var speed: Double = 0          // bytes/s
    private var copier: Copier?
    private var speedSample: (Date, Int64)?

    init() {
        let saved = Config.load()
        config = saved ?? Config.suggested
        showSetup = saved == nil
        reloadCaptures()
        reloadCards()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadCaptures(); self?.reloadCards(); self?.refreshPlan() }
            }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var filteredCaptures: [Capture] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return captures }
        return captures.filter { $0.name.localizedStandardContains(q) }
    }

    func reloadCaptures() {
        var isDir: ObjCBool = false
        inboxAvailable = !config.inbox.isEmpty && FileManager.default.fileExists(atPath: config.inbox, isDirectory: &isDir) && isDir.boolValue
        captures = inboxAvailable ? Capture.list(config) : []
        if let s = selectedCapture, !captures.contains(s) { selectedCapture = nil }
    }

    var inboxDisk: String { Volume.name(of: config.inboxURL) }
    func isConnected(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    /// Discos de redundância que vão receber a cópia agora (conectados e marcados).
    var activeBackups: [URL] { config.backupURLs.filter { isConnected($0) && !backupsOff.contains($0.path) } }

    /// Pastas que os cartões das câmeras costumam ter.
    static let cameraFolders = ["DCIM", "PRIVATE", "CLIP", "M4ROOT", "XDROOT", "AVCHD", "Blackmagic RAW"]
    static func looksLikeCard(_ url: URL) -> Bool {
        cameraFolders.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    // Cartões: volumes removíveis/ejetáveis, menos os discos de destino e os ignorados.
    func reloadCards() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
        let workDisks = Set(([config.inboxURL] + config.backupURLs)
            .filter { $0.path.hasPrefix("/Volumes/") }.map { norm($0.pathComponents.prefix(3).joined(separator: "/")) })
        let ignored = Set(config.ignoredVolumes.map(norm))
        var found: [Card] = []
        for v in vols {
            guard let r = try? v.resourceValues(forKeys: Set(keys)), v.path.hasPrefix("/Volumes/") else { continue }
            let root = norm(v.pathComponents.prefix(3).joined(separator: "/"))
            if workDisks.contains(root) || ignored.contains(norm(v.lastPathComponent)) { continue }
            if r.volumeIsRemovable == true || r.volumeIsEjectable == true || r.volumeIsInternal == false {
                found.append(Card(url: v, name: r.volumeName ?? v.lastPathComponent, isFolder: false))
            }
        }
        // Pastas escolhidas à mão continuam na lista
        found += cards.filter { $0.isFolder }
        cards = found
        if let s = selectedCard, !cards.contains(s) { selectedCard = nil; files = [] }
        if selectedCard == nil, let first = cards.first(where: { !$0.isFolder && Self.looksLikeCard($0.url) }) ?? cards.first {
            select(card: first)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Usar esta pasta")
        panel.message = L("Escolha a pasta (ou o cartão) com os arquivos da gravação")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let card = Card(url: url, name: url.lastPathComponent, isFolder: true)
        if !cards.contains(card) { cards.append(card) }
        select(card: card)
    }

    func select(card: Card) {
        selectedCard = card
        files = []
        scanning = true
        let (url, cfg) = (card.url, config)
        Task.detached {
            let found = CardScanner.scan(url, cfg)
            await MainActor.run {
                guard self.selectedCard?.url == url else { return }
                self.selected = Set(cfg.receivingFolders.filter { f in f.onByDefault && found.contains { $0.folder == f.id } }.map(\.id))
                self.files = found
                self.scanning = false
            }
        }
    }

    func count(_ f: Subfolder) -> Int { files.filter { $0.folder == f.id }.count }
    func bytes(_ f: Subfolder) -> Int64 { files.filter { $0.folder == f.id }.reduce(0) { $0 + $1.size } }

    func refreshPlan() {
        planGeneration += 1
        let gen = planGeneration
        guard let c = selectedCapture, !files.isEmpty else { plan = nil; planning = false; return }
        planning = true
        let (files, selected, cfg, backups) = (files, selected, config, activeBackups)
        Task.detached(priority: .userInitiated) {
            let p = ImportPlan.make(files: files, selected: selected, capture: c, cfg: cfg, backups: backups)
            await MainActor.run {
                guard gen == self.planGeneration else { return }
                self.plan = p
                self.planning = false
            }
        }
    }

    func freeSpace(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0)
    }

    var spaceProblem: String? {
        guard let plan, plan.bytes > 0 else { return nil }
        if freeSpace(at: config.inboxURL) < plan.bytes { return L("Não há espaço suficiente no disco {0}.", inboxDisk) }
        for b in activeBackups where freeSpace(at: b) < plan.bytes {
            return L("Não há espaço suficiente no disco de redundância {0}.", Volume.name(of: b))
        }
        return nil
    }

    func createCapture(date: Date, title: String) throws {
        let name = Capture.folderName(config, date: date, title: title)
        _ = try Capture.create(named: name, config)
        reloadCaptures()
        selectedCapture = captures.first { $0.name == name }
        search = ""
    }

    /// Botão Importar: se algo do cartão já estiver no disco principal, avisa antes.
    func requestStart() {
        guard let plan, !planning else { return }
        if plan.duplicates.isEmpty { start() } else { showDuplicateAlert = true }
    }

    func start() {
        guard let plan, !planning else { return }
        let copier = Copier()
        self.copier = copier
        phase = .copying
        progress = nil
        speed = 0
        speedSample = nil
        Task.detached(priority: .userInitiated) {
            let report = copier.run(plan) { p in
                Task { @MainActor in self.update(p) }
            }
            await MainActor.run {
                self.phase = .done(report)
                self.reloadCaptures()
                let ok = report.failures.isEmpty && !report.cancelled
                NSSound(named: report.failures.isEmpty ? "Glass" : "Basso")?.play()
                NSApp.requestUserAttention(report.failures.isEmpty ? .informationalRequest : .criticalRequest)
                if report.failures.isEmpty {
                    self.notify(ok ? L("Backup concluído") : L("Importação cancelada"),
                                L("{0}: {1} copiados e conferidos.", plan.capture, Fmt.files(report.verified)) +
                                (report.skipped > 0 ? " " + L("{0} já estavam lá.", report.skipped) : ""))
                } else {
                    self.notify(L("Backup com erro"), L("{0} arquivo(s) não foram copiados. Não limpe o cartão.", report.failures.count))
                }
            }
        }
    }

    /// Tudo que pode sair do cartão: o que foi copiado agora e o que já estava no disco.
    func cleanupItems(_ report: ImportReport) -> [VerifiedCopy] {
        report.copies + report.plan.duplicates.map { VerifiedCopy(source: $0.source.url, copy: $0.existing, size: $0.source.size) }
    }

    func cleanCard() {
        guard case .done(let report) = phase, let card = selectedCard, !card.isFolder else { return }
        let items = cleanupItems(report)
        let copier = Copier()
        self.copier = copier
        phase = .cleaning(report)
        progress = nil
        speed = 0
        speedSample = nil
        Task.detached(priority: .userInitiated) {
            let result = copier.cleanCard(root: card.url, items: items) { p in
                Task { @MainActor in self.update(p) }
            }
            await MainActor.run {
                self.phase = .cleaned(result)
                NSSound(named: result.problems.isEmpty ? "Glass" : "Basso")?.play()
                self.notify(result.problems.isEmpty ? L("Cartão limpo") : L("Limpeza com avisos"),
                            result.problems.isEmpty
                                ? L("{0} arquivos apagados do cartão.", result.deleted)
                                : L("{0} arquivos apagados do cartão; {1} ficaram porque não bateram com a cópia.", result.deleted, result.problems.count))
            }
        }
    }

    private func update(_ p: Copier.Progress) {
        switch phase { case .copying, .cleaning: break; default: return }
        progress = p
        let now = Date()
        if let (t, b) = speedSample {
            let dt = now.timeIntervalSince(t)
            if dt > 1 {
                let s = Double(p.done - b) / dt
                speed = speed == 0 ? s : speed * 0.7 + s * 0.3
                speedSample = (now, p.done)
            }
        } else { speedSample = (now, p.done) }
    }

    /// Notificação do macOS (aparece mesmo com o app atrás de outras janelas).
    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func cancel() { copier?.cancel() }

    func finish() {
        phase = .idle
        if let c = selectedCard { select(card: c) }
    }

    func eject() {
        guard let c = selectedCard, !c.isFolder else { return }
        let url = c.url
        Task.detached {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
            await MainActor.run { self.phase = .idle; self.reloadCards() }
        }
    }

    func revealCapture() {
        guard let c = selectedCapture else { return }
        NSWorkspace.shared.open(config.inboxURL.appendingPathComponent(c.name))
    }

    func hide(card: Card) {
        guard !card.isFolder, !config.ignoredVolumes.contains(card.name) else { return }
        config.ignoredVolumes.append(card.name)
    }
}

// MARK: - Formatação

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

// MARK: - Telas

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                CardColumn().frame(width: 290)
                Divider()
                CaptureColumn().frame(minWidth: 330)
                Divider()
                ImportColumn().frame(width: 340)
            }
            .disabled(isBusy)
            .blur(radius: isBusy ? 6 : 0)

            switch model.phase {
            case .idle: EmptyView()
            case .copying: CopyingOverlay()
            case .done(let r): DoneOverlay(report: r)
            case .cleaning: CopyingOverlay(title: L("Conferindo e limpando o cartão…"))
            case .cleaned(let r): CleanedOverlay(report: r)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isBusy)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showSetup = true } label: { Label(L("Ajustes"), systemImage: "gearshape") }
                    .help(L("Discos, pastas e padrões de nome"))
                    .disabled(isBusy)
            }
        }
        .sheet(isPresented: $model.showSetup) {
            SetupView(config: model.config, firstRun: Config.load() == nil)
        }
    }

    var isBusy: Bool { if case .idle = model.phase { false } else { true } }
}

struct StepHeader: View {
    let number: Int
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

// 1 · Cartão
struct CardColumn: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(number: 1, title: L("Cartão"))
            ScrollView {
                VStack(spacing: 8) {
                    if model.cards.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "sdcard").font(.system(size: 34)).foregroundStyle(.tertiary)
                            Text(L("Coloque o cartão no leitor")).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    ForEach(model.cards) { card in
                        CardRow(card: card, selected: model.selectedCard == card)
                            .onTapGesture { model.select(card: card) }
                            .contextMenu {
                                if !card.isFolder {
                                    Button(L("Não mostrar este disco")) { model.hide(card: card) }
                                }
                            }
                    }
                }
                .padding(.horizontal, 14)
            }
            Spacer(minLength: 0)
            if model.selectedCard != nil {
                CardSummary().padding(14)
            }
            Button {
                model.chooseFolder()
            } label: {
                Label(L("Escolher outra pasta…"), systemImage: "folder")
            }
            .buttonStyle(.link)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }
}

struct CardRow: View {
    let card: Card
    let selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: card.isFolder ? "folder.fill" : "sdcard.fill")
                .font(.system(size: 20))
                .foregroundStyle(selected ? .white : .accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(card.isFolder ? card.url.deletingLastPathComponent().path : L("Cartão de memória"))
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
        }
        .padding(10)
        .foregroundStyle(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }
}

struct CardSummary: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("NO CARTÃO")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if model.scanning {
                HStack { ProgressView().controlSize(.small); Text(L("Lendo o cartão…")).foregroundStyle(.secondary) }
            } else {
                // Todas as subpastas que recebem arquivos aparecem, para ficar claro o que o app importa.
                ForEach(model.config.receivingFolders) { f in
                    let n = model.count(f)
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: f.symbol).frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.trimmedPath)
                            Text(n > 0 ? Fmt.files(n) : L("nenhum") + " · " + f.extensionsLabel)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if n > 0 { Text(Fmt.bytes(model.bytes(f))).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .font(.callout)
                    .opacity(n > 0 ? 1 : 0.45)
                }
                if model.files.isEmpty {
                    Text(L("Nada para importar neste cartão.")).foregroundStyle(.secondary).font(.caption)
                }
                if let first = model.files.map(\.date).min(), let last = model.files.map(\.date).max() {
                    Text(Fmt.day.string(from: first) == Fmt.day.string(from: last)
                         ? L("Gravado em {0}", Fmt.day.string(from: first))
                         : L("De {0} a {1}", Fmt.day.string(from: first), Fmt.day.string(from: last)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

// 2 · Captação
struct CaptureColumn: View {
    @EnvironmentObject var model: Model
    @State private var showingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                StepHeader(number: 2, title: L("Captação"))
                Button {
                    showingNew = true
                } label: {
                    Label(L("Nova captação"), systemImage: "plus")
                }
                .controlSize(.large)
                .disabled(!model.inboxAvailable)
                .padding(.trailing, 20)
                .padding(.top, 6)
            }
            if !model.inboxAvailable {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 34)).foregroundStyle(.tertiary)
                    if model.config.inbox.isEmpty {
                        Text(L("Escolha onde guardar as captações")).font(.headline)
                        Button(L("Abrir Ajustes…")) { model.showSetup = true }
                    } else {
                        Text(L("Conecte o disco {0}", model.inboxDisk)).font(.headline)
                        Text(model.config.inbox).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Buscar captação"), text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

                ScrollViewReader { proxy in
                    List(model.filteredCaptures, selection: Binding(
                        get: { model.selectedCapture },
                        set: { model.selectedCapture = $0 })
                    ) { c in
                        CaptureRow(capture: c).tag(c)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selectedCapture) { _, c in
                        if let c { withAnimation { proxy.scrollTo(c.id) } }
                    }
                }
            }
        }
        .sheet(isPresented: $showingNew) { NewCaptureSheet() }
    }
}

struct CaptureRow: View {
    let capture: Capture
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                if let d = capture.date {
                    Text(d.formatted(.dateTime.day())).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(Fmt.monthYear(d))
                        .font(.system(size: 9, weight: .medium)).textCase(.uppercase).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(capture.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .id(capture.id)
    }
}

struct NewCaptureSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var title = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var folderName: String { Capture.folderName(model.config, date: date, title: trimmed) }
    var invalid: Bool { trimmed.isEmpty || trimmed.contains("/") || trimmed.contains(":") || folderName.isEmpty }
    var exists: Bool { model.captures.contains { $0.name == folderName } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Nova captação")).font(.title2.bold())
            Form {
                TextField(L("Nome"), text: $title, prompt: Text(L("ex.: CASAMENTO ANA E JOÃO")))
                    .focused($nameFocused)
                    .onSubmit(create)
                DatePicker(L("Data da gravação"), selection: $date, displayedComponents: .date)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 130)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("VAI CRIAR")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Label(Capture.folderName(model.config, date: date, title: trimmed.isEmpty ? "…" : trimmed), systemImage: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                if !model.config.captureFolders.isEmpty {
                    Text(L("com {0}", ListFormatter.localizedString(byJoining: model.config.captureFolders)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if exists { Text(L("Essa pasta já existe; ela só vai ser selecionada.")).font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(exists ? L("Selecionar") : L("Criar pasta"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(invalid)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            // Data da gravação: a do cartão, se houver; senão, hoje.
            if let first = model.files.map(\.date).min() { date = first }
            nameFocused = true
        }
    }

    func create() {
        guard !invalid else { return }
        do { try model.createCapture(date: date, title: trimmed); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

// 3 · Importar
struct ImportColumn: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(number: 3, title: L("Importar"))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("O QUE IMPORTAR")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(model.config.receivingFolders) { f in
                            let n = model.count(f)
                            Toggle(isOn: Binding(
                                get: { model.selected.contains(f.id) },
                                set: { on in if on { model.selected.insert(f.id) } else { model.selected.remove(f.id) } })
                            ) {
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: f.symbol).frame(width: 18).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.trimmedPath)
                                        Text(f.extensionsLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(n == 0 ? L("nenhum") : "\(n)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(n == 0)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("REDUNDÂNCIA")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(model.config.backupURLs, id: \.self) { b in
                            let connected = model.isConnected(b)
                            Toggle(isOn: Binding(
                                get: { connected && !model.backupsOff.contains(b.path) },
                                set: { on in if on { model.backupsOff.remove(b.path) } else { model.backupsOff.insert(b.path) } })
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Também copiar para {0}", Volume.name(of: b)))
                                    Text(connected ? L("{0}, mesma pasta e mesmos nomes", b.lastPathComponent) : L("Disco não conectado: a cópia fica de fora."))
                                        .font(.caption).foregroundStyle(connected ? Color.secondary : Color.orange)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!connected)
                        }
                        Button(model.config.backups.isEmpty ? L("Adicionar um disco de redundância…") : L("Editar discos…")) { model.showSetup = true }
                            .buttonStyle(.link).font(.callout)
                    }

                    Divider()

                    PlanPreview()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 12) {
                if let problem = model.spaceProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }

                let plan = model.plan
                Button {
                    model.requestStart()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(buttonTitle(plan))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || model.planning || (plan!.jobs.isEmpty && plan!.duplicates.isEmpty) || model.spaceProblem != nil)
                .alert(duplicateTitle(plan), isPresented: $model.showDuplicateAlert) {
                    if let plan, !plan.jobs.isEmpty {
                        Button(L("Importar só os novos ({0})", plan.jobs.count)) { model.start() }
                    } else {
                        Button(L("Continuar")) { model.start() }
                    }
                    Button(L("Cancelar"), role: .cancel) {}
                } message: {
                    Text(duplicateMessage(plan))
                }

                Text(L("Nada é sobrescrito. Cada arquivo é relido depois da cópia e comparado com o original. O cartão só é limpo se você pedir, no fim."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    func duplicateTitle(_ plan: ImportPlan?) -> String {
        guard let plan else { return "" }
        let n = plan.duplicates.count
        if plan.jobs.isEmpty { return L("Tudo deste cartão já foi importado") }
        return n == 1 ? L("1 arquivo deste cartão já foi importado") : L("{0} arquivos deste cartão já foram importados", n)
    }

    func duplicateMessage(_ plan: ImportPlan?) -> String {
        guard let plan else { return "" }
        var lines: [String] = []
        if !plan.alreadyHere.isEmpty { lines.append(L("{0} já em {1}.", Fmt.files(plan.alreadyHere.count), plan.capture)) }
        for (capture, group) in Dictionary(grouping: plan.elsewhere, by: \.capture).sorted(by: { $0.key > $1.key }) {
            lines.append(L("{0} já em OUTRA captação: {1}.", Fmt.files(group.count), capture))
        }
        let examples = plan.duplicates.prefix(3).map { "\($0.source.url.lastPathComponent) = \($0.existing.lastPathComponent)" }
        lines.append("\n" + L("Ex.:") + " " + examples.joined(separator: "\n") + (plan.duplicates.count > 3 ? "\n…" : ""))
        lines.append("\n" + L("Esses arquivos NÃO vão ser copiados de novo nem sobrescritos.") +
                     (plan.jobs.isEmpty ? "" : " " + L("Os outros {0} vão ser importados normalmente.", plan.jobs.count)))
        return lines.joined(separator: "\n")
    }

    func buttonTitle(_ plan: ImportPlan?) -> String {
        if model.planning { return L("Comparando com o que já foi importado…") }
        guard let plan else { return L("Importar") }
        if plan.jobs.isEmpty { return plan.duplicates.isEmpty ? L("Nada para importar") : L("Tudo já importado · ver opções") }
        return L("Importar {0} · {1}", Fmt.files(plan.jobs.count), Fmt.bytes(plan.bytes))
    }
}

struct PlanPreview: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("DESTINO")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let c = model.selectedCapture {
                Text(c.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if model.planning {
                    HStack { ProgressView().controlSize(.small); Text(L("Comparando o cartão com o que já foi importado…")).font(.caption).foregroundStyle(.secondary) }
                } else if let plan = model.plan {
                    ForEach(model.config.receivingFolders.filter { model.selected.contains($0.id) }) { f in
                        let jobs = plan.jobs.filter { $0.source.folder == f.id }
                        if let first = jobs.first {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(f.trimmedPath) · \(Fmt.files(jobs.count))").font(.caption.weight(.semibold))
                                Text(jobs.count == 1 ? first.name : "\(first.name)  …  \(jobs.last!.name)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    if !plan.duplicates.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(plan.duplicates.count == 1 ? L("1 arquivo do cartão já foi importado") : L("{0} arquivos do cartão já foram importados", plan.duplicates.count),
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                            if !plan.alreadyHere.isEmpty {
                                Text(L("{0} nesta pasta", plan.alreadyHere.count)).font(.caption)
                            }
                            ForEach(Array(Set(plan.elsewhere.map(\.capture))).sorted(by: >), id: \.self) { c in
                                Text(L("{0} em outra captação: {1}", plan.elsewhere.filter { $0.capture == c }.count, c)).font(.caption)
                            }
                            Text(L("Não vão ser copiados de novo nem sobrescritos.")).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    }
                } else if model.selectedCard == nil {
                    Text(L("Escolha o cartão.")).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(L("Escolha uma captação na lista ou crie uma nova.")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Progresso e resultado

struct OverlayCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            content
                .padding(32)
                .frame(width: 520)
                .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
                .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
        }
        .transition(.opacity)
    }
}

struct CopyingOverlay: View {
    @EnvironmentObject var model: Model
    var title = L("Fazendo o backup…")
    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "externaldrive.fill.badge.timemachine").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(title).font(.title3.bold())
                        Text(model.selectedCapture?.name ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                let p = model.progress
                let fraction = p.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 } ?? 0
                ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.large)
                HStack {
                    Text("\(Int(fraction * 100))%").font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let p { Text(L("Arquivo {0} de {1}", min(p.fileIndex + 1, p.fileCount), p.fileCount)).monospacedDigit() }
                        if model.speed > 0, let p {
                            Text(L("{0}/s · faltam {1}", Fmt.bytes(Int64(model.speed)), Fmt.duration(Double(p.total - p.done) / model.speed)))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .font(.callout)
                }
                if let p, !p.fileName.isEmpty {
                    Text("\(p.phase): \(p.fileName)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button(L("Cancelar"), role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

struct DoneOverlay: View {
    @EnvironmentObject var model: Model
    let report: ImportReport

    var ok: Bool { report.failures.isEmpty && !report.cancelled }
    /// Só oferece limpar quando tudo deu certo e é um cartão de verdade (não uma pasta escolhida).
    var canClean: Bool {
        ok && model.selectedCard.map { !$0.isFolder } == true && !model.cleanupItems(report).isEmpty
    }

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: ok ? "checkmark.seal.fill" : (report.cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill"))
                        .font(.system(size: 40))
                        .foregroundStyle(ok ? .green : (report.cancelled ? .orange : .red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ok ? L("Backup concluído") : (report.cancelled ? L("Importação cancelada") : L("Terminou com erros")))
                            .font(.title2.bold())
                        Text(model.selectedCapture?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.config.receivingFolders) { f in
                        if let n = report.copied[f.id], n > 0 {
                            Label(L("{0} em {1}", Fmt.files(n), f.trimmedPath), systemImage: f.symbol)
                        }
                    }
                    if report.verified > 0 {
                        Label(L("{0} conferidos byte a byte com o original", report.verified), systemImage: "checkmark.shield")
                    }
                    if report.skipped > 0 {
                        Label(L("{0} já tinham sido importados (não copiados de novo)", Fmt.files(report.skipped)), systemImage: "arrow.uturn.forward")
                    }
                    Label(L("{0} em {1}", Fmt.bytes(report.bytes), Fmt.duration(report.seconds)), systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                if !report.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("{0} com problema. Não formate nem limpe o cartão antes de resolver:", report.failures.count))
                            .font(.callout.weight(.semibold)).foregroundStyle(.red)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(report.failures, id: \.self) { Text($0).font(.caption.monospaced()) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                    }
                }
                if report.cancelled {
                    Text(L("Os arquivos que terminaram ficaram na pasta. Importar de novo continua de onde parou."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if canClean {
                    let items = model.cleanupItems(report)
                    let bytes = items.reduce(Int64(0)) { $0 + $1.size }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sdcard").font(.system(size: 22)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Limpar o cartão")).font(.callout.weight(.semibold))
                            Text(L("Apaga do cartão {0} ({1}) que já estão no disco principal. Antes, cada um é relido inteiro e comparado de novo com a cópia; o que não bater fica no cartão.", Fmt.files(items.count), Fmt.bytes(bytes)))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(L("Limpar cartão…"), role: .destructive) { model.showCleanConfirm = true }
                            .tint(.red)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .confirmationDialog(L("Apagar {0} do cartão {1}?", Fmt.files(items.count), model.selectedCard?.name ?? ""),
                                        isPresented: $model.showCleanConfirm) {
                        Button(L("Conferir e apagar"), role: .destructive) { model.cleanCard() }
                        Button(L("Cancelar"), role: .cancel) {}
                    } message: {
                        Text(L("Só são apagados os arquivos que baterem byte a byte com a cópia em {0}. Isso não pode ser desfeito.", model.selectedCapture?.name ?? ""))
                    }
                }

                HStack {
                    Button(L("Mostrar no Finder")) { model.revealCapture() }
                    Spacer()
                    if ok, let card = model.selectedCard, !card.isFolder {
                        Button(L("Ejetar cartão")) { model.eject() }
                    }
                    Button(L("Concluir")) { model.finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct CleanedOverlay: View {
    @EnvironmentObject var model: Model
    let report: Copier.CleanupReport

    var ok: Bool { report.problems.isEmpty && !report.cancelled }

    var body: some View {
        OverlayCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: ok ? "sparkles" : "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(ok ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ok ? L("Cartão limpo") : (report.cancelled ? L("Limpeza interrompida") : L("Limpeza com avisos")))
                            .font(.title2.bold())
                        Text(model.selectedCard?.name ?? "").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("{0} conferidos e apagados ({1})", Fmt.files(report.deleted), Fmt.bytes(report.bytes)), systemImage: "checkmark.shield")
                    if report.leftovers > 0 {
                        Label(L("{0} que não eram da importação ficaram no cartão (JPG, proxies, arquivos da câmera). Para zerar, formate o cartão na câmera.", Fmt.files(report.leftovers)),
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
                if !report.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("{0} não foram apagados porque a conferência falhou:", report.problems.count))
                            .font(.callout.weight(.semibold)).foregroundStyle(.red)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(report.problems, id: \.self) { Text($0).font(.caption.monospaced()) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                    }
                }
                HStack {
                    Spacer()
                    Button(L("Ejetar cartão")) { model.eject() }
                    Button(L("Concluir")) { model.finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
