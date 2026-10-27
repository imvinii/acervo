// Janela principal: 1 · Cartão, 2 · Captação, 3 · Importar (igual ao app do Mac).

using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using static Acervo.Loc;
using static Acervo.Ui;

namespace Acervo;

public record Card(string Root, string Name, bool IsFolder);

public class MainWindow : Window
{
    Config cfg;
    List<Capture> captures = [];
    Capture? selectedCapture;
    string search = "";
    List<Card> cards = [];
    readonly List<Card> selectedCards = [];
    List<SourceFile> files = [];
    bool scanning;
    HashSet<Guid> selected = [];
    readonly HashSet<string> backupsOff = Prefs.BackupsOff;
    ImportPlan? plan;
    bool planning;
    int planGen, scanGen;
    string driveSignature = "";

    enum Phase { Idle, Copying, Done, Cleaning, Cleaned }
    Phase phase = Phase.Idle;
    ImportReport? report;
    CleanupReport? cleanup;
    Progress? progress;
    double speed;
    (DateTime, long)? speedSample;
    Copier? copier;
    public static bool IsWorking;
    /// <summary>Pastas que já entram na lista de cartões ao abrir (--pasta).</summary>
    public static readonly List<string> StartupFolders = [];

    // Partes da tela que são remontadas quando algo muda
    readonly StackPanel cardList = new() { Spacing = 8 };
    readonly ContentControl cardSummary = new();
    readonly TextBlock cardHint = Caption("");
    readonly ListBox captureList = new() { Background = Brushes.Transparent };
    readonly ContentControl captureEmpty = new();
    readonly Button newCaptureBtn;
    readonly ContentControl importBody = new();
    readonly ContentControl importFooter = new();
    readonly Panel overlay = new() { IsVisible = false };
    readonly Grid columns = new();
    bool updatingList;

    public MainWindow()
    {
        Title = "Acervo";
        Width = 1100; Height = 780; MinWidth = 980; MinHeight = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var saved = Config.Load();
        cfg = saved ?? Config.Simple();

        // 1 · Cartão
        var col1 = new DockPanel { Margin = new Thickness(14, 18, 14, 14) };
        var chooseFolder = Link(L("Escolher outra pasta…"), () => _ = ChooseFolder());
        DockPanel.SetDock(chooseFolder, Dock.Bottom);
        DockPanel.SetDock(cardSummary, Dock.Bottom);
        var top1 = Col(12, Step(1, L("Cartão")), cardList, cardHint);
        DockPanel.SetDock(top1, Dock.Top);
        col1.Children.Add(chooseFolder);
        col1.Children.Add(cardSummary);
        col1.Children.Add(top1);
        col1.Children.Add(new Panel());

        // 2 · Captação
        newCaptureBtn = Btn("+ " + L("Nova captação"), () => _ = NewCapture());
        var head2 = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        DockPanel.SetDock(newCaptureBtn, Dock.Right);
        head2.Children.Add(newCaptureBtn);
        head2.Children.Add(Step(2, L("Captação")));
        var searchBox = new TextBox { Watermark = "🔍  " + L("Buscar captação"), Margin = new Thickness(0, 0, 0, 10) };
        searchBox.TextChanged += (_, _) => { search = searchBox.Text ?? ""; FillCaptures(); };
        captureList.SelectionChanged += (_, _) =>
        {
            if (updatingList) return;
            selectedCapture = captureList.SelectedItem is ListBoxItem { Tag: Capture c } ? c : null;
            RefreshPlan();
        };
        var col2 = new DockPanel { Margin = new Thickness(20, 18, 20, 14) };
        DockPanel.SetDock(head2, Dock.Top);
        DockPanel.SetDock(searchBox, Dock.Top);
        col2.Children.Add(head2);
        col2.Children.Add(searchBox);
        col2.Children.Add(new Panel { Children = { captureList, captureEmpty } });

        // 3 · Importar
        var gear = Btn("⚙  " + L("Ajustes"), () => _ = OpenSettings(false));
        var head3 = new DockPanel { Margin = new Thickness(20, 18, 20, 12) };
        DockPanel.SetDock(gear, Dock.Right);
        head3.Children.Add(gear);
        head3.Children.Add(Step(3, L("Importar")));
        var col3 = new DockPanel();
        DockPanel.SetDock(head3, Dock.Top);
        DockPanel.SetDock(importFooter, Dock.Bottom);
        col3.Children.Add(head3);
        col3.Children.Add(importFooter);
        col3.Children.Add(new ScrollViewer { Content = importBody, Padding = new Thickness(20, 0, 20, 12) });

        columns.ColumnDefinitions = new ColumnDefinitions("290,1,*,1,350");
        void Add(Control c, int col) { Grid.SetColumn(c, col); columns.Children.Add(c); }
        Add(new Border { Background = Subtle, Child = col1 }, 0);
        Add(new Border { Background = Line }, 1);
        Add(col2, 2);
        Add(new Border { Background = Line }, 3);
        Add(new Border { Background = Subtle, Child = col3 }, 4);

        Content = new Panel { Children = { columns, overlay } };

        ReloadCaptures();
        foreach (var f in StartupFolders.Where(Directory.Exists))
        {
            var card = new Card(Path.GetFullPath(f), Path.GetFileName(f.TrimEnd('/', '\\')), true);
            cards.Add(card);
            selectedCards.Add(card);
        }
        ReloadCards();
        if (StartupFolders.Count > 0) Rescan();
        Render();

        // Discos conectados/desconectados: confere a cada 2 s
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) =>
        {
            var sig = string.Join("|", Volume.Mounted().Select(v => v.Root));
            if (sig == driveSignature) return;
            driveSignature = sig;
            ReloadCaptures(); ReloadCards(); RefreshPlan(); Render();
        };
        timer.Start();

        Closing += OnClosing;
        if (saved == null) Opened += (_, _) => _ = OpenSettings(true);
    }

    // MARK: Estado

    bool InboxAvailable => cfg.Inbox.Length > 0 && Directory.Exists(cfg.Inbox);
    string InboxDisk => Volume.NameOf(cfg.Inbox);
    List<string> ActiveBackups => cfg.BackupPaths.Where(b => Directory.Exists(b) && !backupsOff.Contains(b)).ToList();
    List<Card> RealCards => selectedCards.Where(c => !c.IsFolder).ToList();
    int Count(Subfolder f) => files.Count(x => x.Folder == f.Id);
    long Bytes(Subfolder f) => files.Where(x => x.Folder == f.Id).Sum(x => x.Size);

    void ReloadCaptures()
    {
        captures = InboxAvailable ? Capture.List(cfg) : [];
        if (selectedCapture != null && !captures.Contains(selectedCapture)) selectedCapture = null;
        FillCaptures();
    }

    /// <summary>Cartões: discos removíveis, menos os de destino e os ignorados.</summary>
    void ReloadCards()
    {
        var work = new[] { cfg.Inbox }.Concat(cfg.BackupPaths).Where(p => p.Length > 0).Select(Volume.RootOf).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var system = Volume.RootOf(Environment.SystemDirectory.Length > 0 ? Environment.SystemDirectory : "/");
        var found = Volume.Mounted()
            .Where(v => v.Removable && !work.Contains(Volume.RootOf(v.Root)) && !v.Root.Equals(system, StringComparison.OrdinalIgnoreCase)
                        && !cfg.IgnoredVolumes.Any(n => v.Name.Equals(n, StringComparison.OrdinalIgnoreCase) || v.Name.StartsWith(n + " (", StringComparison.OrdinalIgnoreCase)))
            .Select(v => new Card(v.Root, v.Name, false)).ToList();
        found.AddRange(cards.Where(c => c.IsFolder));
        cards = found;
        var kept = selectedCards.Where(cards.Contains).ToList();
        var changed = kept.Count != selectedCards.Count;
        selectedCards.Clear(); selectedCards.AddRange(kept);
        if (selectedCards.Count == 0)
        {
            // Marca sozinho os cartões de câmera conectados (vários leitores = vários cartões)
            var cams = cards.Where(c => !c.IsFolder && CardScanner.LooksLikeCard(c.Root)).ToList();
            selectedCards.AddRange(cams.Count > 0 ? cams : cards.Take(1));
            changed = true;
        }
        if (changed) Rescan();
    }

    void Toggle(Card c)
    {
        if (!selectedCards.Remove(c)) selectedCards.Add(c);
        Rescan();
        Render();
    }

    /// <summary>Lê todos os cartões marcados e junta os arquivos, em ordem de gravação.</summary>
    void Rescan()
    {
        var gen = ++scanGen;
        files = [];
        if (selectedCards.Count == 0) { scanning = false; RefreshPlan(); return; }
        scanning = true;
        var roots = selectedCards.Select(c => c.Root).ToList();
        var c = cfg;
        Task.Run(() =>
        {
            var found = CardScanner.Scan(roots, c);
            var present = found.Select(f => f.Folder).ToHashSet();
            var marked = c.ReceivingFolders.Where(f => f.OnByDefault && present.Contains(f.Id)).Select(f => f.Id).ToHashSet();
            Dispatcher.UIThread.Post(() =>
            {
                if (gen != scanGen) return;
                selected = marked;
                files = found;
                scanning = false;
                RefreshPlan();
                Render();
            });
        });
    }

    void RefreshPlan()
    {
        var gen = ++planGen;
        if (selectedCapture is not { } cap || files.Count == 0) { plan = null; planning = false; Render(); return; }
        planning = true;
        var (f, s, c, b) = (files, selected.ToHashSet(), cfg, ActiveBackups);
        Task.Run(() =>
        {
            var p = ImportPlan.Make(f, s, cap, c, b);
            Dispatcher.UIThread.Post(() =>
            {
                if (gen != planGen) return;
                plan = p;
                planning = false;
                Render();
            });
        });
        Render();
    }

    string? SpaceProblem
    {
        get
        {
            if (plan is not { } p || p.Bytes == 0) return null;
            if (Volume.FreeSpace(cfg.Inbox) < p.Bytes) return L("Não há espaço suficiente no disco {0}.", InboxDisk);
            foreach (var b in ActiveBackups)
                if (Volume.FreeSpace(b) < p.Bytes) return L("Não há espaço suficiente no disco de redundância {0}.", Volume.NameOf(b));
            return null;
        }
    }

    // MARK: Ações

    async Task ChooseFolder()
    {
        var r = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = L("Escolha a pasta com os arquivos da gravação") });
        if (r.FirstOrDefault()?.TryGetLocalPath() is not { } path) return;
        var card = new Card(path, Path.GetFileName(path.TrimEnd('/', '\\')), true);
        if (!cards.Contains(card)) cards.Add(card);
        if (!selectedCards.Contains(card)) selectedCards.Add(card);
        Rescan();
        Render();
    }

    async Task OpenSettings(bool firstRun)
    {
        var w = new SetupWindow(cfg, firstRun);
        var result = await w.ShowDialog<Config?>(this);
        if (result == null) { if (firstRun) Close(); return; }
        cfg = result;
        cfg.Save();
        selected.RemoveWhere(id => !cfg.ReceivingFolders.Any(f => f.Id == id));
        ReloadCaptures(); ReloadCards(); Rescan(); Render();
    }

    async Task NewCapture()
    {
        var date = files.Count > 0 ? files.Min(f => f.Date).Date : DateTime.Today;
        var w = new NewCaptureWindow(cfg, captures, date);
        if (await w.ShowDialog<string?>(this) is not { } name) return;
        try
        {
            Capture.Create(name, cfg);
            ReloadCaptures();
            selectedCapture = captures.FirstOrDefault(c => c.Name == name);
            FillCaptures();
            RefreshPlan();
        }
        catch (Exception e) { await Dialogs.Alert(this, L("Nova captação"), e.Message); }
    }

    async Task RequestStart()
    {
        if (plan is not { } p || planning) return;
        if (p.Duplicates.Count == 0) { Start(); return; }
        var ok = await Dialogs.Confirm(this, DuplicateTitle(p), DuplicateMessage(p),
            p.Jobs.Count > 0 ? L("Importar só os novos ({0})", p.Jobs.Count) : L("Continuar"));
        if (ok) Start();
    }

    void Start()
    {
        if (plan is not { } p || planning) return;
        var c = new Copier();
        copier = c;
        SetPhase(Phase.Copying);
        progress = null; speed = 0; speedSample = null;
        var conf = cfg;
        Task.Run(() =>
        {
            var r = c.Run(p, pr => Dispatcher.UIThread.Post(() => Update(pr)));
            r.Warnings = Reports.Write(r, conf);
            Dispatcher.UIThread.Post(() =>
            {
                report = r;
                SetPhase(Phase.Done);
                ReloadCaptures();
                Activate();
            });
        });
    }

    List<VerifiedCopy> CleanupItems(ImportReport r) =>
        [.. r.Copies, .. r.Plan.Duplicates.Select(d => new VerifiedCopy(d.Source.Path, d.Existing, d.Source.Size))];

    async Task CleanCards()
    {
        if (report is not { } r || RealCards.Count == 0) return;
        var roots = RealCards.Select(c => c.Root).ToList();
        var items = CleanupItems(r).Where(i => roots.Any(root => Path.GetFullPath(i.Source).StartsWith(Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase))).ToList();
        var ok = await Dialogs.Confirm(this, L("Apagar {0} do cartão {1}?", Fmt.Files(items.Count), string.Join(", ", RealCards.Select(x => x.Name))),
            L("Só são apagados os arquivos que baterem byte a byte com a cópia em {0}. Isso não pode ser desfeito.", selectedCapture?.Name ?? ""),
            L("Conferir e apagar"), destructive: true);
        if (!ok) return;
        var c = new Copier();
        copier = c;
        SetPhase(Phase.Cleaning);
        progress = null; speed = 0; speedSample = null;
        _ = Task.Run(() =>
        {
            var res = c.CleanCards(roots, items, pr => Dispatcher.UIThread.Post(() => Update(pr)));
            Dispatcher.UIThread.Post(() => { cleanup = res; SetPhase(Phase.Cleaned); });
        });
    }

    void Update(Progress p)
    {
        if (phase is not (Phase.Copying or Phase.Cleaning)) return;
        progress = p;
        var now = DateTime.Now;
        if (speedSample is { } s)
        {
            var dt = (now - s.Item1).TotalSeconds;
            if (dt > 1)
            {
                var v = (p.Done - s.Item2) / dt;
                speed = speed == 0 ? v : speed * 0.7 + v * 0.3;
                speedSample = (now, p.Done);
            }
        }
        else speedSample = (now, p.Done);
        RenderOverlay();
    }

    void Finish() { SetPhase(Phase.Idle); Rescan(); }

    void Eject()
    {
        var roots = RealCards.Select(c => c.Root).ToList();
        if (roots.Count == 0) return;
        Task.Run(() =>
        {
            foreach (var r in roots)
            {
                try
                {
                    if (OperatingSystem.IsWindows())
                    {
                        // "Ejetar" do Explorador (o mesmo do clique com o botão direito no disco)
                        var letter = r.TrimEnd('\\');
                        Process.Start(new ProcessStartInfo("powershell", $"-NoProfile -Command \"(New-Object -comObject Shell.Application).Namespace(17).ParseName('{letter}').InvokeVerb('Eject')\"")
                            { CreateNoWindow = true, UseShellExecute = false })?.WaitForExit(15000);
                    }
                    else Process.Start("diskutil", $"eject \"{r}\"")?.WaitForExit(15000);
                }
                catch { }
            }
            Dispatcher.UIThread.Post(() => { SetPhase(Phase.Idle); ReloadCards(); Render(); });
        });
    }

    void RevealCapture()
    {
        if (selectedCapture is not { } c) return;
        var path = Path.Combine(cfg.Inbox, c.Name);
        Process.Start(new ProcessStartInfo(OperatingSystem.IsWindows() ? "explorer.exe" : "open", $"\"{path}\"") { UseShellExecute = false });
    }

    void Hide(Card c)
    {
        if (c.IsFolder || cfg.IgnoredVolumes.Contains(c.Name)) return;
        cfg.IgnoredVolumes.Add(c.Name.Contains(" (") ? c.Name[..c.Name.LastIndexOf(" (", StringComparison.Ordinal)] : c.Name);
        cfg.Save();
        ReloadCards(); Render();
    }

    void SetPhase(Phase p)
    {
        phase = p;
        IsWorking = p is Phase.Copying or Phase.Cleaning;
        columns.IsEnabled = p == Phase.Idle;
        columns.Effect = p == Phase.Idle ? null : new BlurEffect { Radius = 6 };
        RenderOverlay();
    }

    async void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (!IsWorking) return;
        e.Cancel = true;
        var quit = await Dialogs.Confirm(this, L("Há uma cópia em andamento"),
            L("Se sair agora, ela é interrompida. O que já foi copiado e conferido fica salvo; importar de novo continua de onde parou."),
            L("Sair mesmo assim"), destructive: true, cancel: L("Continuar a cópia"));
        if (quit) { copier?.Cancel(); IsWorking = false; Close(); }
    }

    // MARK: Telas

    void Render()
    {
        RenderCards();
        RenderCaptureColumn();
        RenderImport();
    }

    void RenderCards()
    {
        cardList.Children.Clear();
        if (cards.Count == 0)
            cardList.Children.Add(Col(10, T("💾", 30, opacity: 0.4), T(L("Coloque o cartão no leitor"), opacity: 0.6)).Also(s => { s.HorizontalAlignment = HorizontalAlignment.Center; s.Margin = new Thickness(0, 30); }));
        foreach (var card in cards)
        {
            var on = selectedCards.Contains(card);
            var row = new Border
            {
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(10),
                Background = on ? AccentBrush : Subtle,
                Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
                Child = new Grid
                {
                    ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
                    ColumnSpacing = 10,
                    Children =
                    {
                        T(card.IsFolder ? "📁" : "💾", 18).Also(t => t.VerticalAlignment = VerticalAlignment.Center),
                        Col(1, T(card.Name, 14, FontWeight.SemiBold, color: on ? Brushes.White : null),
                               T(card.IsFolder ? card.Root : L("Cartão de memória"), 11, opacity: 0.75, color: on ? Brushes.White : null)
                                   .Also(t => t.TextTrimming = TextTrimming.PrefixCharacterEllipsis))
                            .Also(c => Grid.SetColumn(c, 1)),
                        T(on ? "✔" : "○", 15, color: on ? Brushes.White : null).Also(t => { Grid.SetColumn(t, 2); t.VerticalAlignment = VerticalAlignment.Center; }),
                    },
                },
            };
            row.PointerPressed += (_, _) => Toggle(card);
            if (!card.IsFolder)
            {
                var hide = new MenuItem { Header = L("Não mostrar este disco") };
                hide.Click += (_, _) => Hide(card);
                row.ContextMenu = new ContextMenu { Items = { hide } };
            }
            cardList.Children.Add(row);
        }
        cardHint.Text = cards.Count > 1 ? L("Clique para marcar ou desmarcar. Os cartões marcados vão para a mesma captação e são copiados ao mesmo tempo.") : "";

        if (selectedCards.Count == 0) { cardSummary.Content = null; return; }
        var sum = Col(8, Label(selectedCards.Count > 1 ? L("NOS {0} CARTÕES", selectedCards.Count) : L("NO CARTÃO")));
        if (scanning) sum.Children.Add(T(L("Lendo o cartão…"), opacity: 0.6));
        else
        {
            // Todas as subpastas que recebem arquivos aparecem, para ficar claro o que o app importa.
            foreach (var f in cfg.ReceivingFolders)
            {
                var n = Count(f);
                var line = new DockPanel { Opacity = n > 0 ? 1 : 0.45 };
                var size = T(n > 0 ? Fmt.Bytes(Bytes(f)) : "", opacity: 0.6);
                DockPanel.SetDock(size, Dock.Right);
                line.Children.Add(size);
                line.Children.Add(Row(8, T(f.Symbol), Col(1, T(f.TrimmedPath), T(n > 0 ? Fmt.Files(n) : L("nenhum") + " · " + f.ExtensionsLabel, 11, opacity: 0.6))));
                sum.Children.Add(line);
            }
            if (files.Count == 0) sum.Children.Add(Caption(L("Nada para importar neste cartão.")));
            else
            {
                var first = files.Min(f => f.Date); var last = files.Max(f => f.Date);
                sum.Children.Add(Caption(Fmt.Day(first) == Fmt.Day(last) ? L("Gravado em {0}", Fmt.Day(first)) : L("De {0} a {1}", Fmt.Day(first), Fmt.Day(last))));
            }
        }
        cardSummary.Content = Box(sum).Also(b => b.Margin = new Thickness(0, 10));
    }

    void RenderCaptureColumn()
    {
        newCaptureBtn.IsEnabled = InboxAvailable;
        captureList.IsVisible = InboxAvailable;
        captureEmpty.Content = InboxAvailable ? null : Col(10,
            T("🗄", 30, opacity: 0.4).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
            cfg.Inbox.Length == 0
                ? Col(8, T(L("Escolha onde guardar as captações"), 15, FontWeight.SemiBold), Btn(L("Abrir Ajustes…"), () => _ = OpenSettings(false)))
                : Col(4, T(L("Conecte o disco {0}", InboxDisk), 15, FontWeight.SemiBold), Caption(cfg.Inbox)))
            .Also(s => { s.HorizontalAlignment = HorizontalAlignment.Center; s.VerticalAlignment = VerticalAlignment.Center; });
    }

    void FillCaptures()
    {
        updatingList = true;
        var q = search.Trim();
        var list = q.Length == 0 ? captures : captures.Where(c => c.Name.Contains(q, StringComparison.CurrentCultureIgnoreCase)).ToList();
        captureList.Items.Clear();
        ListBoxItem? sel = null;
        foreach (var c in list)
        {
            var dateCol = c.Date is { } d
                ? Col(0, T(d.Day.ToString(), 18, FontWeight.Bold).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                         T(Fmt.MonthYear(d), 9, FontWeight.Medium, 0.6).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center))
                : Col(0, T("📁", 16, opacity: 0.6).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center));
            dateCol.Width = 56;
            var item = new ListBoxItem
            {
                Tag = c,
                Padding = new Thickness(6, 6),
                Content = Row(12, dateCol, Col(2, T(c.Title, 14, FontWeight.Medium), T(c.Name, 11, opacity: 0.6))),
            };
            captureList.Items.Add(item);
            if (c == selectedCapture) sel = item;
        }
        captureList.SelectedItem = sel;
        sel?.BringIntoView();
        updatingList = false;
    }

    void RenderImport()
    {
        var body = Col(16);
        // O que importar
        var what = Col(8, Label(L("O QUE IMPORTAR")));
        foreach (var f in cfg.ReceivingFolders)
        {
            var n = Count(f);
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 8 };
            line.Children.Add(T(f.Symbol));
            line.Children.Add(Col(1, T(f.TrimmedPath), T(f.ExtensionsLabel, 11, opacity: 0.6)).Also(c => Grid.SetColumn(c, 1)));
            line.Children.Add(T(n == 0 ? L("nenhum") : n.ToString(), opacity: 0.6).Also(t => Grid.SetColumn(t, 2)));
            var cb = new CheckBox
            {
                IsChecked = selected.Contains(f.Id),
                IsEnabled = n > 0,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = line,
            };
            cb.IsCheckedChanged += (_, _) => { if (cb.IsChecked == true) selected.Add(f.Id); else selected.Remove(f.Id); RefreshPlan(); };
            what.Children.Add(cb);
        }
        body.Children.Add(what);

        // Redundância
        var red = Col(8, Label(L("REDUNDÂNCIA")));
        foreach (var b in cfg.BackupPaths)
        {
            var connected = Directory.Exists(b);
            var cb = new CheckBox
            {
                IsChecked = connected && !backupsOff.Contains(b),
                IsEnabled = connected,
                Content = Col(2, T(L("Também copiar para {0}", Volume.NameOf(b))),
                    Caption(connected ? L("{0}, mesma pasta e mesmos nomes", Path.GetFileName(b.TrimEnd('/', '\\'))) : L("Disco não conectado: a cópia fica de fora."), connected ? null : Orange)),
            };
            cb.IsCheckedChanged += (_, _) => { if (cb.IsChecked == true) backupsOff.Remove(b); else backupsOff.Add(b); Prefs.BackupsOff = backupsOff; RefreshPlan(); };
            red.Children.Add(cb);
        }
        red.Children.Add(Link(cfg.Backups.Count == 0 ? L("Adicionar um disco de redundância…") : L("Editar discos…"), () => _ = OpenSettings(false)));
        body.Children.Add(red);
        body.Children.Add(new Border { Height = 1, Background = Line });

        // Destino
        var dest = Col(8, Label(L("DESTINO")));
        if (selectedCapture is { } cap)
        {
            dest.Children.Add(T(cap.Name, 14, FontWeight.SemiBold, wrap: true));
            if (planning) dest.Children.Add(Caption(L("Comparando o cartão com o que já foi importado…")));
            else if (plan is { } p)
            {
                foreach (var f in cfg.ReceivingFolders.Where(f => selected.Contains(f.Id)))
                {
                    var jobs = p.Jobs.Where(j => j.Source.Folder == f.Id).ToList();
                    if (jobs.Count == 0) continue;
                    dest.Children.Add(Col(1, T($"{f.TrimmedPath} · {Fmt.Files(jobs.Count)}", 11.5, FontWeight.SemiBold),
                        T(jobs.Count == 1 ? jobs[0].Name : $"{jobs[0].Name}  …  {jobs[^1].Name}", 11, opacity: 0.6, wrap: true).Also(t => t.FontFamily = new FontFamily("Consolas, Menlo, monospace"))));
                }
                if (p.Duplicates.Count > 0)
                {
                    var dup = Col(4, T("⚠ " + (p.Duplicates.Count == 1 ? L("1 arquivo do cartão já foi importado") : L("{0} arquivos do cartão já foram importados", p.Duplicates.Count)), 13, FontWeight.SemiBold, color: Orange, wrap: true));
                    if (p.AlreadyHere.Any()) dup.Children.Add(Caption(L("{0} nesta pasta", p.AlreadyHere.Count())));
                    foreach (var g in p.Elsewhere.GroupBy(d => d.Capture).OrderByDescending(g => g.Key))
                        dup.Children.Add(Caption(L("{0} em outra captação: {1}", g.Count(), g.Key)));
                    dup.Children.Add(Caption(L("Não vão ser copiados de novo nem sobrescritos.")));
                    dest.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(30, 224, 138, 0)), CornerRadius = new CornerRadius(8), Padding = new Thickness(10), Child = dup });
                }
            }
            else if (selectedCards.Count == 0) dest.Children.Add(Caption(L("Escolha o cartão.")));
        }
        else dest.Children.Add(Caption(L("Escolha uma captação na lista ou crie uma nova.")));
        body.Children.Add(dest);
        importBody.Content = body;

        // Rodapé: botão Importar
        var foot = Col(10);
        foot.Margin = new Thickness(20, 0, 20, 20);
        if (SpaceProblem is { } sp) foot.Children.Add(T("⚠ " + sp, color: Red, wrap: true));
        var btn = new Button
        {
            Content = T(ButtonTitle(), 15, FontWeight.SemiBold).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(10, 10),
            IsEnabled = plan != null && !planning && (plan.Jobs.Count > 0 || plan.Duplicates.Count > 0) && SpaceProblem == null,
        };
        btn.Classes.Add("accent");
        btn.Click += (_, _) => _ = RequestStart();
        foot.Children.Add(btn);
        foot.Children.Add(Caption(L("Nada é sobrescrito. Cada arquivo é relido depois da cópia e comparado com o original. O cartão só é limpo se você pedir, no fim.")));
        importFooter.Content = foot;
    }

    string ButtonTitle()
    {
        if (planning) return L("Comparando com o que já foi importado…");
        if (plan is not { } p) return L("Importar");
        if (p.Jobs.Count == 0) return p.Duplicates.Count == 0 ? L("Nada para importar") : L("Tudo já importado · ver opções");
        return L("Importar {0} · {1}", Fmt.Files(p.Jobs.Count), Fmt.Bytes(p.Bytes));
    }

    static string DuplicateTitle(ImportPlan p)
    {
        if (p.Jobs.Count == 0) return L("Tudo deste cartão já foi importado");
        return p.Duplicates.Count == 1 ? L("1 arquivo deste cartão já foi importado") : L("{0} arquivos deste cartão já foram importados", p.Duplicates.Count);
    }

    static string DuplicateMessage(ImportPlan p)
    {
        var lines = new List<string>();
        if (p.AlreadyHere.Any()) lines.Add(L("{0} já em {1}.", Fmt.Files(p.AlreadyHere.Count()), p.Capture));
        foreach (var g in p.Elsewhere.GroupBy(d => d.Capture).OrderByDescending(g => g.Key))
            lines.Add(L("{0} já em OUTRA captação: {1}.", Fmt.Files(g.Count()), g.Key));
        lines.Add("\n" + L("Ex.:") + " " + string.Join("\n", p.Duplicates.Take(3).Select(d => $"{Path.GetFileName(d.Source.Path)} = {Path.GetFileName(d.Existing)}")) + (p.Duplicates.Count > 3 ? "\n…" : ""));
        lines.Add("\n" + L("Esses arquivos NÃO vão ser copiados de novo nem sobrescritos.") + (p.Jobs.Count == 0 ? "" : " " + L("Os outros {0} vão ser importados normalmente.", p.Jobs.Count)));
        return string.Join("\n", lines);
    }

    // MARK: Progresso e resultado

    void RenderOverlay()
    {
        overlay.IsVisible = phase != Phase.Idle;
        if (phase == Phase.Idle) { overlay.Children.Clear(); return; }
        Control content = phase switch
        {
            Phase.Copying => ProgressCard(L("Fazendo o backup…")),
            Phase.Cleaning => ProgressCard(L("Conferindo e limpando o cartão…")),
            Phase.Done => DoneCard(),
            _ => CleanedCard(),
        };
        overlay.Children.Clear();
        overlay.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(60, 0, 0, 0)) });
        overlay.Children.Add(new Border
        {
            Width = 540,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(30),
            Background = (IBrush?)this.FindResource("SystemControlBackgroundAltHighBrush") ?? Brushes.White,
            BoxShadow = BoxShadows.Parse("0 10 30 0 #40000000"),
            Child = content,
        });
    }

    Control ProgressCard(string title)
    {
        var p = progress;
        var fraction = p is { Total: > 0 } ? (double)p.Done / p.Total : 0;
        var right = Col(2);
        if (p != null)
        {
            right.Children.Add(T(L("Arquivo {0} de {1}", Math.Min(p.FileIndex + 1, p.FileCount), p.FileCount)));
            if (p.Cards > 1) right.Children.Add(T(L("{0} cartões ao mesmo tempo", p.Cards), opacity: 0.6));
            if (speed > 0) right.Children.Add(T(L("{0}/s · faltam {1}", Fmt.Bytes((long)speed), Fmt.Duration((p.Total - p.Done) / speed)), opacity: 0.6));
        }
        right.HorizontalAlignment = HorizontalAlignment.Right;
        var mid = new DockPanel { Children = { right.Also(r => DockPanel.SetDock(r, Dock.Right)), T($"{(int)(fraction * 100)}%", 28, FontWeight.Bold) } };
        var col = Col(16,
            Row(12, T("🗄", 26), Col(2, T(title, 18, FontWeight.Bold), T(selectedCapture?.Name ?? "", opacity: 0.6))),
            new ProgressBar { Value = fraction * 100, Height = 8 },
            mid);
        if (p is { FileName.Length: > 0 }) col.Children.Add(T($"{p.Phase}: {p.FileName}", 11, opacity: 0.6));
        col.Children.Add(Btn(L("Cancelar"), () => copier?.Cancel()).Also(b => b.HorizontalAlignment = HorizontalAlignment.Right));
        return col;
    }

    Control DoneCard()
    {
        var r = report!;
        var ok = r.Failures.Count == 0 && !r.Cancelled;
        var col = Col(14, Row(14,
            T(ok ? "✅" : r.Cancelled ? "⏹" : "⚠", 34),
            Col(2, T(ok ? L("Backup concluído") : r.Cancelled ? L("Importação cancelada") : L("Terminou com erros"), 20, FontWeight.Bold),
                   T(selectedCapture?.Name ?? "", opacity: 0.6))));
        var lines = Col(6);
        foreach (var f in cfg.ReceivingFolders)
            if (r.Copied.TryGetValue(f.Id, out var n) && n > 0) lines.Children.Add(T($"{f.Symbol}  {L("{0} em {1}", Fmt.Files(n), f.TrimmedPath)}"));
        if (r.Verified > 0) lines.Children.Add(T("🛡  " + L("{0} conferidos byte a byte com o original", r.Verified)));
        if (r.Skipped > 0) lines.Children.Add(T("↪  " + L("{0} já tinham sido importados (não copiados de novo)", Fmt.Files(r.Skipped))));
        lines.Children.Add(T("🕒  " + L("{0} em {1}", Fmt.Bytes(r.Bytes), Fmt.Duration(r.Seconds)), opacity: 0.6));
        col.Children.Add(lines);

        if (r.Failures.Count > 0)
            col.Children.Add(Col(4, T(L("{0} com problema. Não formate nem limpe o cartão antes de resolver:", r.Failures.Count), 13, FontWeight.SemiBold, color: Red, wrap: true),
                new ScrollViewer { MaxHeight = 100, Content = Col(2, r.Failures.Select(f => (Control)T(f, 11, wrap: true)).ToArray()) }));
        if (ok && r.Verified > 0)
        {
            // Só é seguro formatar com 2 cópias conferidas em discos diferentes
            var disks = Reports.VerifiedDisks(r);
            var safe = disks.Count >= 2;
            col.Children.Add(T((safe ? "🛡 " : "⚠ ") + (safe
                ? L("Seguro para formatar: cada arquivo está conferido em {0} discos ({1}).", disks.Count, string.Join(", ", disks))
                : L("Concluído com 1 cópia ({0}). Para formatar com segurança, tenha uma segunda cópia em outro disco.", disks.FirstOrDefault() ?? "")),
                13, FontWeight.SemiBold, wrap: true, color: safe ? Green : Orange));
        }
        if ((cfg.ReportPDF || cfg.Mhl) && r.Verified > 0)
            col.Children.Add(Caption(cfg.ReportPDF
                ? (cfg.ReportFolder.Length == 0 ? L("Relatório salvo na pasta Relatórios da captação.") : L("Relatório salvo em {0}.", cfg.ReportFolder))
                : L("Checksums salvos no registro ASC MHL da captação.")));
        foreach (var w in r.Warnings) col.Children.Add(Caption("⚠ " + w, Orange));
        if (r.Cancelled) col.Children.Add(Caption(L("Os arquivos que terminaram ficaram na pasta. Importar de novo continua de onde parou.")));

        // Limpar o cartão: só quando tudo deu certo e são cartões de verdade (não pastas escolhidas)
        var items = CleanupItems(r);
        if (ok && RealCards.Count > 0 && items.Count > 0)
        {
            var bytes = items.Sum(i => i.Size);
            var clean = new DockPanel();
            var b = Btn(L("Limpar cartão…"), () => _ = CleanCards());
            b.Foreground = Red;
            b.VerticalAlignment = VerticalAlignment.Top;
            DockPanel.SetDock(b, Dock.Right);
            clean.Children.Add(b);
            clean.Children.Add(Col(4, T(L("Limpar o cartão"), 13, FontWeight.SemiBold),
                Caption(L("Apaga do cartão {0} ({1}) que já estão no disco principal. Antes, cada um é relido inteiro e comparado de novo com a cópia; o que não bater fica no cartão.", Fmt.Files(items.Count), Fmt.Bytes(bytes))))
                .Also(c => c.Margin = new Thickness(0, 0, 12, 0)));
            col.Children.Add(Box(clean));
        }

        var buttons = new DockPanel();
        var show = Btn(L("Mostrar no Explorador"), RevealCapture);
        DockPanel.SetDock(show, Dock.Left);
        buttons.Children.Add(show);
        var right = Row(8);
        right.HorizontalAlignment = HorizontalAlignment.Right;
        if (ok && RealCards.Count > 0) right.Children.Add(Btn(RealCards.Count > 1 ? L("Ejetar cartões") : L("Ejetar cartão"), Eject));
        right.Children.Add(Btn(L("Concluir"), Finish, primary: true));
        buttons.Children.Add(right);
        col.Children.Add(buttons);
        return new ScrollViewer { MaxHeight = 640, Content = col };
    }

    Control CleanedCard()
    {
        var r = cleanup!;
        var ok = r.Problems.Count == 0 && !r.Cancelled;
        var col = Col(14, Row(14, T(ok ? "✨" : "⚠", 32),
            Col(2, T(ok ? L("Cartão limpo") : r.Cancelled ? L("Limpeza interrompida") : L("Limpeza com avisos"), 20, FontWeight.Bold),
                   T(string.Join(", ", selectedCards.Select(c => c.Name)), opacity: 0.6))));
        col.Children.Add(T("🛡  " + L("{0} conferidos e apagados ({1})", Fmt.Files(r.Deleted), Fmt.Bytes(r.Bytes))));
        if (r.Leftovers > 0)
            col.Children.Add(Caption("ℹ " + L("{0} que não eram da importação ficaram no cartão (JPG, proxies, arquivos da câmera). Para zerar, formate o cartão na câmera.", Fmt.Files(r.Leftovers))));
        if (r.Problems.Count > 0)
            col.Children.Add(Col(4, T(L("{0} não foram apagados porque a conferência falhou:", r.Problems.Count), 13, FontWeight.SemiBold, color: Red),
                new ScrollViewer { MaxHeight = 100, Content = Col(2, r.Problems.Select(p => (Control)T(p, 11, wrap: true)).ToArray()) }));
        var right = Row(8, Btn(L("Ejetar cartão"), Eject), Btn(L("Concluir"), Finish, primary: true));
        right.HorizontalAlignment = HorizontalAlignment.Right;
        col.Children.Add(right);
        return col;
    }
}

/// <summary>Pequenas preferências que não são Ajustes (ex.: redundâncias desligadas na hora de importar).</summary>
public static class Prefs
{
    static string FilePath => Path.Combine(Path.GetDirectoryName(Config.FilePath)!, "prefs.txt");
    public static HashSet<string> BackupsOff
    {
        get { try { return File.Exists(FilePath) ? File.ReadAllLines(FilePath).Where(l => l.Length > 0).ToHashSet() : []; } catch { return []; } }
        set { try { Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!); File.WriteAllLines(FilePath, value); } catch { } }
    }
}

public static class Extensions
{
    /// <summary>Ajusta um controle e devolve ele mesmo (para montar a tela em código).</summary>
    public static T Also<T>(this T c, Action<T> a) { a(c); return c; }
}
