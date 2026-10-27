// Importar Cartão: backup dos cartões depois de uma gravação.
// Substitui os atalhos "Criar projeto" e "Importar SD".

import SwiftUI
import AppKit
import UserNotifications

@main
struct ImportarCartaoApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Importar Cartão", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1060, height: 700)
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
    @Published var captures: [Capture] = []
    @Published var inboxAvailable = false
    @Published var selectedCapture: Capture? { didSet { if oldValue != selectedCapture { refreshPlan() } } }
    @Published var search = ""

    @Published var cards: [Card] = []
    @Published var selectedCard: Card?
    @Published var files: [SourceFile] = [] { didSet { refreshPlan() } }
    @Published var scanning = false

    @Published var kinds: Set<Kind> = Set(Kind.allCases) { didSet { if oldValue != kinds { refreshPlan() } } }
    @Published var alsoBackup = UserDefaults.standard.bool(forKey: "fazerBackup") {
        didSet { UserDefaults.standard.set(alsoBackup, forKey: "fazerBackup"); refreshPlan() }
    }

    /// O que vai ser copiado e o que já está na Inbox. Calculado em segundo plano,
    /// porque compara o cartão com os arquivos já importados.
    @Published var plan: ImportPlan?
    @Published var planning = false
    private var planGeneration = 0

    @Published var showDuplicateAlert = false
    @Published var showCleanConfirm = false

    enum Phase { case idle, copying, done(ImportReport), cleaning(ImportReport), cleaned(Copier.CleanupReport) }
    @Published var phase: Phase = .idle
    @Published var progress: Copier.Progress?
    @Published var speed: Double = 0          // bytes/s
    private var copier: Copier?
    private var speedSample: (Date, Int64)?

    init() {
        reloadCaptures()
        reloadCards()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadCaptures(); self?.reloadCards() }
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
        inboxAvailable = FileManager.default.fileExists(atPath: Paths.inbox.path, isDirectory: &isDir) && isDir.boolValue
        captures = inboxAvailable ? Capture.list(in: Paths.inbox) : []
        if let s = selectedCapture, !captures.contains(s) { selectedCapture = nil }
    }

    var backupAvailable: Bool { FileManager.default.fileExists(atPath: Paths.backup.path) }

    // Cartões: volumes removíveis/ejetáveis, menos os SSDs de trabalho.
    func reloadCards() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
        let workDisks = Set([Paths.inbox, Paths.backup].map { norm($0.pathComponents.prefix(3).joined(separator: "/")) })
        let workNames: Set<String> = ["Mídias", "Projetos", "Elements"]
        var found: [Card] = []
        for v in vols {
            guard let r = try? v.resourceValues(forKeys: Set(keys)), v.path.hasPrefix("/Volumes/") else { continue }
            let root = norm(v.pathComponents.prefix(3).joined(separator: "/"))
            if workDisks.contains(root) || workNames.contains(norm(v.lastPathComponent)) { continue }
            if r.volumeIsRemovable == true || r.volumeIsEjectable == true || r.volumeIsInternal == false {
                found.append(Card(url: v, name: r.volumeName ?? v.lastPathComponent, isFolder: false))
            }
        }
        // Pastas escolhidas à mão continuam na lista
        found += cards.filter { $0.isFolder }
        cards = found
        if let s = selectedCard, !cards.contains(s) { selectedCard = nil; files = [] }
        if selectedCard == nil, let first = cards.first(where: { ["Untitled", "EOS_DIGITAL"].contains($0.name) }) ?? cards.first {
            select(card: first)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Usar esta pasta"
        panel.message = "Escolha a pasta (ou o cartão) com os arquivos da gravação"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let card = Card(url: url, name: url.lastPathComponent, isFolder: true)
        if !cards.contains(card) { cards.append(card) }
        select(card: card)
    }

    func select(card: Card) {
        selectedCard = card
        files = []
        scanning = true
        let url = card.url
        Task.detached {
            let found = CardScanner.scan(url)
            await MainActor.run {
                guard self.selectedCard?.url == url else { return }
                self.kinds = Set(Kind.allCases.filter { k in found.contains { $0.kind == k } })
                self.files = found
                self.scanning = false
            }
        }
    }

    func count(_ k: Kind) -> Int { files.filter { $0.kind == k }.count }
    func bytes(_ k: Kind) -> Int64 { files.filter { $0.kind == k }.reduce(0) { $0 + $1.size } }

    func refreshPlan() {
        planGeneration += 1
        let gen = planGeneration
        guard let c = selectedCapture, !files.isEmpty else { plan = nil; planning = false; return }
        planning = true
        let (files, kinds, name) = (files, kinds, c.name)
        let backup = alsoBackup && backupAvailable ? Paths.backup : nil
        Task.detached(priority: .userInitiated) {
            let p = ImportPlan.make(files: files, kinds: kinds, capture: name, inbox: Paths.inbox, backup: backup)
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
        if freeSpace(at: Paths.inbox) < plan.bytes { return "Não há espaço suficiente no SSD Mídias." }
        if alsoBackup && backupAvailable && freeSpace(at: Paths.backup) < plan.bytes { return "Não há espaço suficiente no SSD Projetos." }
        return nil
    }

    func createCapture(date: Date, title: String) throws {
        let name = Capture.folderName(date: date, title: title)
        _ = try Capture.create(named: name, in: Paths.inbox)
        reloadCaptures()
        selectedCapture = captures.first { $0.name == name }
        search = ""
    }

    /// Botão Importar: se algo do cartão já estiver na Inbox, avisa antes.
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
                    self.notify(ok ? "Backup concluído" : "Importação cancelada",
                                "\(plan.capture): \(Fmt.files(report.verified)) copiados e conferidos" +
                                (report.skipped > 0 ? ", \(report.skipped) já estavam lá." : "."))
                } else {
                    self.notify("Backup com erro", "\(report.failures.count) arquivo(s) não foram copiados. Não limpe o cartão.")
                }
            }
        }
    }

    /// Tudo que pode sair do cartão: o que foi copiado agora e o que já estava na Inbox.
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
                self.notify(result.problems.isEmpty ? "Cartão limpo" : "Limpeza com avisos",
                            "\(result.deleted) arquivos apagados do cartão" +
                            (result.problems.isEmpty ? "." : "; \(result.problems.count) ficaram porque não bateram com a cópia."))
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
        NSWorkspace.shared.open(Paths.inbox.appendingPathComponent(c.name))
    }
}

// MARK: - Formatação

enum Fmt {
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM yyyy"; return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEEE"; return f
    }()
    static func duration(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60, sec = Int(s) % 60
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return m > 0 ? "\(m) min \(sec) s" : "\(sec) s"
    }
    static func files(_ n: Int) -> String { n == 1 ? "1 arquivo" : "\(n) arquivos" }
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
            case .cleaning: CopyingOverlay(title: "Conferindo e limpando o cartão…")
            case .cleaned(let r): CleanedOverlay(report: r)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isBusy)
        .background(.background)
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
            StepHeader(number: 1, title: "Cartão")
            ScrollView {
                VStack(spacing: 8) {
                    if model.cards.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "sdcard").font(.system(size: 34)).foregroundStyle(.tertiary)
                            Text("Coloque o cartão no leitor").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    ForEach(model.cards) { card in
                        CardRow(card: card, selected: model.selectedCard == card)
                            .onTapGesture { model.select(card: card) }
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
                Label("Escolher outra pasta…", systemImage: "folder")
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
                Text(card.isFolder ? card.url.deletingLastPathComponent().path : "Cartão de memória")
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
            Text("NO CARTÃO").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if model.scanning {
                HStack { ProgressView().controlSize(.small); Text("Lendo o cartão…").foregroundStyle(.secondary) }
            } else if model.files.isEmpty {
                Text("Nenhum vídeo, foto RAW ou áudio encontrado.").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(Kind.allCases) { k in
                    if model.count(k) > 0 {
                        HStack {
                            Image(systemName: k.symbol).frame(width: 20).foregroundStyle(.secondary)
                            Text(k.label(model.count(k)))
                            Spacer()
                            Text(Fmt.bytes(model.bytes(k))).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                if let first = model.files.map(\.date).min(), let last = model.files.map(\.date).max() {
                    Text(Fmt.day.string(from: first) == Fmt.day.string(from: last)
                         ? "Gravado em \(Fmt.day.string(from: first))"
                         : "De \(Fmt.day.string(from: first)) a \(Fmt.day.string(from: last))")
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
                StepHeader(number: 2, title: "Captação")
                Button {
                    showingNew = true
                } label: {
                    Label("Nova captação", systemImage: "plus")
                }
                .controlSize(.large)
                .disabled(!model.inboxAvailable)
                .padding(.trailing, 20)
                .padding(.top, 6)
            }
            if !model.inboxAvailable {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Conecte o SSD Mídias").font(.headline)
                    Text(Paths.inbox.path).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar captação", text: $model.search).textFieldStyle(.plain)
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
                    Text(Fmt.day.string(from: d).split(separator: " ").dropFirst().joined(separator: " "))
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
    var invalid: Bool { trimmed.isEmpty || trimmed.contains("/") || trimmed.contains(":") }
    var exists: Bool { model.captures.contains { $0.name == Capture.folderName(date: date, title: trimmed) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nova captação").font(.title2.bold())
            Form {
                TextField("Nome", text: $title, prompt: Text("ex.: CC BEB ELETRICA"))
                    .focused($nameFocused)
                    .onSubmit(create)
                DatePicker("Data da gravação", selection: $date, displayedComponents: .date)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 130)

            VStack(alignment: .leading, spacing: 6) {
                Text("VAI CRIAR").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Label(Capture.folderName(date: date, title: trimmed.isEmpty ? "…" : trimmed), systemImage: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("com Vídeos, Fotos/Brutas, Fotos/Seleção e Lapela")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if exists { Text("Essa pasta já existe; ela só vai ser selecionada.").font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(exists ? "Selecionar" : "Criar pasta", action: create)
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
            StepHeader(number: 3, title: "Importar")
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("O QUE IMPORTAR").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Kind.allCases) { k in
                        let n = model.count(k)
                        Toggle(isOn: Binding(
                            get: { model.kinds.contains(k) },
                            set: { on in if on { model.kinds.insert(k) } else { model.kinds.remove(k) } })
                        ) {
                            HStack {
                                Label(k.title, systemImage: k.symbol)
                                Spacer()
                                Text(n == 0 ? "nenhum" : "\(n)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(n == 0)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $model.alsoBackup) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Também copiar para o SSD Projetos")
                            Text("Inbox (BACKUP), mesma pasta e mesmos nomes")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!model.backupAvailable)
                    if model.alsoBackup && !model.backupAvailable {
                        Text("SSD Projetos não conectado: a cópia extra fica de fora.").font(.caption).foregroundStyle(.orange)
                    }
                }

                Divider()

                PlanPreview()

                Spacer(minLength: 0)

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
                        Button("Importar só os novos (\(plan.jobs.count))") { model.start() }
                    } else {
                        Button("Continuar") { model.start() }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text(duplicateMessage(plan))
                }

                Text("Nada é sobrescrito. Cada arquivo é relido depois da cópia e comparado com o original. O cartão só é limpo se você pedir, no fim.")
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
        if plan.jobs.isEmpty { return "Tudo deste cartão já foi importado" }
        return n == 1 ? "1 arquivo deste cartão já foi importado" : "\(n) arquivos deste cartão já foram importados"
    }

    func duplicateMessage(_ plan: ImportPlan?) -> String {
        guard let plan else { return "" }
        var lines: [String] = []
        if !plan.alreadyHere.isEmpty { lines.append("\(Fmt.files(plan.alreadyHere.count)) já \(plan.alreadyHere.count == 1 ? "está" : "estão") em \(plan.capture).") }
        for (capture, group) in Dictionary(grouping: plan.elsewhere, by: \.capture).sorted(by: { $0.key > $1.key }) {
            lines.append("\(Fmt.files(group.count)) já \(group.count == 1 ? "está" : "estão") em OUTRA captação: \(capture).")
        }
        let examples = plan.duplicates.prefix(3).map { "\($0.source.url.lastPathComponent) = \($0.existing.lastPathComponent)" }
        lines.append("\nEx.: " + examples.joined(separator: "\n") + (plan.duplicates.count > 3 ? "\n…" : ""))
        lines.append("\nEsses arquivos NÃO vão ser copiados de novo nem sobrescritos." +
                     (plan.jobs.isEmpty ? "" : " Os outros \(plan.jobs.count) vão ser importados normalmente."))
        return lines.joined(separator: "\n")
    }

    func buttonTitle(_ plan: ImportPlan?) -> String {
        if model.planning { return "Comparando com a Inbox…" }
        guard let plan else { return "Importar" }
        if plan.jobs.isEmpty { return plan.duplicates.isEmpty ? "Nada para importar" : "Tudo já importado · ver opções" }
        return "Importar \(Fmt.files(plan.jobs.count)) · \(Fmt.bytes(plan.bytes))"
    }
}

struct PlanPreview: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DESTINO").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let c = model.selectedCapture {
                Text(c.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if model.planning {
                    HStack { ProgressView().controlSize(.small); Text("Comparando o cartão com o que já está na Inbox…").font(.caption).foregroundStyle(.secondary) }
                } else if let plan = model.plan {
                    ForEach(Kind.allCases.filter { model.kinds.contains($0) }) { k in
                        let jobs = plan.jobs.filter { $0.source.kind == k }
                        if let first = jobs.first {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(k.subpath).font(.caption.weight(.semibold))
                                Text(jobs.count == 1 ? first.name : "\(first.name)  …  \(jobs.last!.name.split(separator: " - ").last.map(String.init) ?? jobs.last!.name)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    if !plan.duplicates.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(Fmt.files(plan.duplicates.count)) do cartão já \(plan.duplicates.count == 1 ? "foi importado" : "foram importados")",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                            if !plan.alreadyHere.isEmpty {
                                Text("\(plan.alreadyHere.count) nesta pasta").font(.caption)
                            }
                            ForEach(Array(Set(plan.elsewhere.map(\.capture))).sorted(by: >), id: \.self) { c in
                                Text("\(plan.elsewhere.filter { $0.capture == c }.count) em outra captação: \(c)").font(.caption)
                            }
                            Text("Não vão ser copiados de novo nem sobrescritos.").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    }
                } else if model.selectedCard == nil {
                    Text("Escolha o cartão.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Escolha uma captação na lista ou crie uma nova.").font(.callout).foregroundStyle(.secondary)
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
    var title = "Fazendo o backup…"
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
                        if let p { Text("Arquivo \(min(p.fileIndex + 1, p.fileCount)) de \(p.fileCount)").monospacedDigit() }
                        if model.speed > 0, let p {
                            Text("\(Fmt.bytes(Int64(model.speed)))/s · faltam \(Fmt.duration(Double(p.total - p.done) / model.speed))")
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
                    Button("Cancelar", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
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
                        Text(ok ? "Backup concluído" : (report.cancelled ? "Importação cancelada" : "Terminou com erros"))
                            .font(.title2.bold())
                        Text(model.selectedCapture?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Kind.allCases) { k in
                        if let n = report.copied[k], n > 0 {
                            Label("\(k.label(n)) \(k == .fotos ? "copiada" : "copiado")\(n == 1 ? "" : "s")", systemImage: k.symbol)
                        }
                    }
                    if report.verified > 0 {
                        Label("\(report.verified) conferidos byte a byte com o original", systemImage: "checkmark.shield")
                    }
                    if report.skipped > 0 {
                        Label("\(Fmt.files(report.skipped)) já tinham sido importados (não copiados de novo)", systemImage: "arrow.uturn.forward")
                    }
                    Label("\(Fmt.bytes(report.bytes)) em \(Fmt.duration(report.seconds))", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                if !report.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.failures.count) com problema. Não formate nem limpe o cartão antes de resolver:")
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
                    Text("Os arquivos que terminaram ficaram na pasta. Importar de novo continua de onde parou.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if canClean {
                    let items = model.cleanupItems(report)
                    let bytes = items.reduce(Int64(0)) { $0 + $1.size }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sdcard").font(.system(size: 22)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Limpar o cartão").font(.callout.weight(.semibold))
                            Text("Apaga do cartão \(Fmt.files(items.count)) (\(Fmt.bytes(bytes))) que já estão no SSD. Antes, cada um é relido inteiro e comparado de novo com a cópia; o que não bater fica no cartão.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Limpar cartão…", role: .destructive) { model.showCleanConfirm = true }
                            .tint(.red)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .confirmationDialog("Apagar \(Fmt.files(items.count)) do cartão \(model.selectedCard?.name ?? "")?",
                                        isPresented: $model.showCleanConfirm) {
                        Button("Conferir e apagar", role: .destructive) { model.cleanCard() }
                        Button("Cancelar", role: .cancel) {}
                    } message: {
                        Text("Só são apagados os arquivos que baterem byte a byte com a cópia em \(model.selectedCapture?.name ?? "Inbox"). Isso não pode ser desfeito.")
                    }
                }

                HStack {
                    Button("Mostrar no Finder") { model.revealCapture() }
                    Spacer()
                    if ok, let card = model.selectedCard, !card.isFolder {
                        Button("Ejetar cartão") { model.eject() }
                    }
                    Button("Concluir") { model.finish() }
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
                        Text(ok ? "Cartão limpo" : (report.cancelled ? "Limpeza interrompida" : "Limpeza com avisos"))
                            .font(.title2.bold())
                        Text(model.selectedCard?.name ?? "").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(Fmt.files(report.deleted)) conferidos e apagados (\(Fmt.bytes(report.bytes)))", systemImage: "checkmark.shield")
                    if report.leftovers > 0 {
                        Label("\(Fmt.files(report.leftovers)) que não eram da importação ficaram no cartão (JPG, proxies, arquivos da câmera). Para zerar, formate o cartão na câmera.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
                if !report.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.problems.count) não foram apagados porque a conferência falhou:")
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
                    Button("Ejetar cartão") { model.eject() }
                    Button("Concluir") { model.finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
