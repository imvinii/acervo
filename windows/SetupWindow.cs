// Ajustes: disco principal, discos de redundância, pastas, nomes, relatórios e discos ignorados.
// Aparece sozinho na primeira abertura; depois, pelo botão Ajustes.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using static Acervo.Loc;
using static Acervo.Ui;

namespace Acervo;

public class SetupWindow : Window
{
    Config draft;
    readonly bool firstRun;
    readonly ScrollViewer scroll = new();
    readonly TextBlock problemText = Caption("", Orange);
    readonly Button saveBtn;
    /// <summary>Atualizam os exemplos sem remontar a tela (para não perder o cursor do campo).</summary>
    readonly List<Action> refreshers = [];

    public SetupWindow(Config cfg, bool firstRun)
    {
        draft = cfg.Clone();
        this.firstRun = firstRun;
        Title = firstRun ? L("Bem-vindo ao {0}", "Acervo") : L("Ajustes");
        Width = 820; Height = 760; MinWidth = 700; MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var intro = Col(4,
            T(firstRun ? L("Bem-vindo ao {0}", "Acervo") : L("Ajustes"), 22, FontWeight.Bold),
            Caption(firstRun
                ? L("Antes de começar, diga onde guardar as gravações e como organizar as pastas e os arquivos. Dá para mudar tudo depois em Ajustes (⌘,).")
                : L("As mudanças valem para as próximas importações. Nada que já foi importado é renomeado.")));
        intro.Margin = new Thickness(24, 20, 24, 8);

        saveBtn = Btn(firstRun ? L("Começar") : L("Salvar"), () => Close(draft), primary: true);
        var templates = Menu(L("Começar de um modelo") + "  ▾", [
            (L("Simples (Vídeos, Fotos, Áudios, Documentos)"), () => Apply(Config.Simple())),
            (L("Vértice (Vídeos, Fotos/Brutas, Fotos/Seleção, Áudios, Documentos)"), () => Apply(Config.Vertice())),
        ]);
        var right = Row(8, problemText, Btn(firstRun ? L("Sair") : L("Cancelar"), () => Close(null)), saveBtn);
        problemText.VerticalAlignment = VerticalAlignment.Center;
        problemText.MaxWidth = 260;
        var bottom = new DockPanel { Margin = new Thickness(20) };
        DockPanel.SetDock(templates, Dock.Left);
        right.HorizontalAlignment = HorizontalAlignment.Right;
        bottom.Children.Add(templates);
        bottom.Children.Add(right);

        var root = new DockPanel();
        DockPanel.SetDock(intro, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(intro);
        root.Children.Add(bottom);
        root.Children.Add(scroll);
        Content = root;
        Build();
    }

    Capture Sample => Capture.From(Capture.FolderName(draft, DateTime.Today, L("CASAMENTO ANA")), new Pattern.Matcher(draft.FolderPattern));

    string? Problem()
    {
        if (draft.Inbox.Length == 0) return L("Escolha o disco principal.");
        if (Capture.FolderName(draft, DateTime.Today, "X").Length == 0) return L("O nome da pasta da captação não pode ficar vazio.");
        if (draft.Backups.Contains(draft.Inbox)) return L("A redundância precisa ser uma pasta diferente da do disco principal.");
        if (!draft.ReceivingFolders.Any()) return L("Pelo menos uma subpasta precisa receber arquivos.");
        return null;
    }

    void Refresh()
    {
        foreach (var r in refreshers) r();
        var p = Problem();
        problemText.Text = p ?? "";
        saveBtn.IsEnabled = p == null;
    }

    /// <summary>Aplica pastas e nomes de um modelo, mantendo os discos já escolhidos.</summary>
    void Apply(Config preset)
    {
        preset.Inbox = draft.Inbox;
        preset.Backups = draft.Backups;
        preset.IgnoredVolumes = draft.IgnoredVolumes;
        preset.ReportPDF = draft.ReportPDF; preset.ReportFolder = draft.ReportFolder; preset.Mhl = draft.Mhl;
        draft = preset;
        Build();
    }

    void Build()
    {
        var offset = scroll.Offset;
        refreshers.Clear();
        var body = Col(4);
        body.Margin = new Thickness(24, 0, 24, 24);
        MainDisk(body);
        Backups(body);
        Folders(body);
        Files(body);
        ReportsSection(body);
        Ignored(body);
        scroll.Content = body;
        scroll.Offset = offset;
        Refresh();
    }

    // MARK: Discos

    Control DiskInfo(string path, string empty)
    {
        if (path.Length == 0) return Row(10, T("💽", 20, opacity: 0.5), T(empty, opacity: 0.6).Also(t => t.VerticalAlignment = VerticalAlignment.Center));
        var connected = Directory.Exists(path);
        return Row(10, T("💽", 20),
            Col(1, T(Volume.NameOf(path), 13, FontWeight.SemiBold), T(path, 11, opacity: 0.6),
                connected ? Caption(L("{0} livres", Fmt.Bytes(Volume.FreeSpace(path)))) : Caption(L("Não está conectado agora"), Orange)));
    }

    /// <summary>Lista dos discos conectados; ao escolher um, abre a janela para escolher (ou criar) a pasta dentro dele.</summary>
    Button DiskMenu(string title, string purpose, Action<string> onPick, bool flat = false)
    {
        var items = Volume.Mounted().Select(v => ($"{v.Name}  ·  {L("{0} livres", Fmt.Bytes(v.Free))}", (Action)(() => _ = Pick(v, purpose, onPick)))).ToList();
        items.Add(("-", () => { }));
        items.Add((L("Outra pasta…"), () => _ = Pick(null, purpose, onPick)));
        return Menu(title + "  ▾", items, flat);
    }

    async Task Pick(Volume? v, string purpose, Action<string> onPick)
    {
        var opts = new FolderPickerOpenOptions
        {
            Title = v != null ? L("Escolha ou crie, no disco {0}, a pasta {1}. Ex.: uma pasta “Inbox”.", v.Name, purpose) : L("Escolha ou crie a pasta {0}.", purpose),
        };
        if (v != null) opts.SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(v.Root);
        var r = await StorageProvider.OpenFolderPickerAsync(opts);
        if (r.FirstOrDefault()?.TryGetLocalPath() is { } path) { onPick(Path.GetFullPath(path)); Build(); }
    }

    void MainDisk(StackPanel body)
    {
        body.Children.Add(Header(L("Disco principal"), L("Onde o backup é feito. Cada gravação vira uma pasta aqui dentro, com os arquivos do cartão já organizados.")));
        var row = new DockPanel();
        var menu = DiskMenu(draft.Inbox.Length == 0 ? L("Escolher disco") : L("Trocar disco"), L("do disco principal"), p => draft.Inbox = p);
        menu.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(menu, Dock.Right);
        row.Children.Add(menu);
        row.Children.Add(DiskInfo(draft.Inbox, L("Nenhum disco escolhido")));
        body.Children.Add(Box(row));
    }

    void Backups(StackPanel body)
    {
        body.Children.Add(Header(L("Discos de redundância (opcional)"), L("Cópias idênticas em outros discos, com a mesma pasta e os mesmos nomes. Se um disco falhar, os arquivos continuam seguros no outro. Na hora de importar dá para ligar ou desligar cada um.")));
        var list = Col(10);
        foreach (var b in draft.Backups.ToList())
        {
            var row = new DockPanel();
            var rm = IconBtn("⛔", () => { draft.Backups.Remove(b); Build(); }, L("Remover"), Red);
            DockPanel.SetDock(rm, Dock.Right);
            row.Children.Add(rm);
            row.Children.Add(DiskInfo(b, ""));
            list.Children.Add(row);
            if (draft.Inbox.Length > 0 && Volume.RootOf(b) == Volume.RootOf(draft.Inbox))
                list.Children.Add(Caption("⚠ " + L("Está no mesmo disco do principal: se esse disco falhar, as duas cópias se perdem."), Orange));
        }
        list.Children.Add(DiskMenu("+ " + L("Adicionar disco de redundância"), L("da redundância"), p => { if (!draft.Backups.Contains(p)) draft.Backups.Add(p); }, flat: true));
        body.Children.Add(Box(list));
    }

    // MARK: Pastas

    void Folders(StackPanel body)
    {
        body.Children.Add(Header(L("Pasta de cada captação"), L("Como o app cria a pasta de cada gravação e as subpastas que vão dentro dela. Cada subpasta recebe os tipos de arquivo que você escolher.")));
        var box = Col(10);
        var pattern = new TextBox { Text = draft.FolderPattern, FontFamily = new FontFamily("Consolas, Menlo, monospace"), Watermark = $"{Tok.Year}{{MM}}{{DD}} - {Tok.Name}" };
        pattern.TextChanged += (_, _) => { draft.FolderPattern = pattern.Text ?? ""; Refresh(); };
        var presets = Menu("☰", new (string, string)[]
        {
            ($"20261027 - {L("NOME")}", $"{Tok.Year}{{MM}}{{DD}} - {Tok.Name}"),
            ($"2026-10-27 {L("NOME")}", $"{Tok.Year}-{{MM}}-{{DD}} {Tok.Name}"),
            ($"{L("NOME")} - 27.10.2026", $"{Tok.Name} - {{DD}}.{{MM}}.{Tok.Year}"),
            ($"261027_{L("NOME")}", $"{Tok.ShortYear}{{MM}}{{DD}}_{Tok.Name}"),
            (L("Só o nome"), Tok.Name),
        }.Select(p => ($"{p.Item1}      {p.Item2}", (Action)(() => { pattern.Text = p.Item2; }))));
        var head = new DockPanel();
        var lbl = T(L("Nome da pasta:")).Also(t => { t.Width = 130; t.VerticalAlignment = VerticalAlignment.Center; });
        DockPanel.SetDock(lbl, Dock.Left);
        DockPanel.SetDock(presets, Dock.Right);
        head.Children.Add(lbl);
        head.Children.Add(presets);
        head.Children.Add(pattern.Also(p => p.Margin = new Thickness(0, 0, 8, 0)));
        var example = new ContentControl();
        refreshers.Add(() => example.Content = Example(Sample.Name));
        box.Children.Add(head);
        box.Children.Add(example);
        box.Children.Add(Caption(L("Escreva como quiser: o texto fica igual e as etiquetas entre chaves são trocadas na hora. {0} é o nome que você digita ao criar a captação; {1} {MM} {DD}, a data da gravação.", Tok.Name, Tok.Year)));
        box.Children.Add(new Border { Height = 1, Background = Line, Margin = new Thickness(0, 4) });

        foreach (var f in draft.Folders.ToList()) box.Children.Add(SubfolderRow(f));
        box.Children.Add(Link("+ " + L("Adicionar subpasta"), () => { draft.Folders.Add(new Subfolder("", null)); Build(); }));
        var split = new CheckBox
        {
            IsChecked = draft.SplitByCard,
            Content = Col(2, T(L("Separar por cartão quando importar mais de um")),
                Caption(L("Cada cartão ganha uma subpasta com o nome dele (ex.: Vídeos/CAM A). Desmarcado, os arquivos de todos os cartões ficam juntos, numerados na ordem em que foram gravados."))),
        };
        split.IsCheckedChanged += (_, _) => draft.SplitByCard = split.IsChecked == true;
        box.Children.Add(split);
        body.Children.Add(Box(box));
        body.Children.Add(Caption(L("Em “recebe”, escreva a extensão dos arquivos que vão para essa subpasta, que são as letras depois do ponto no nome (ex.: Arte.psd → psd). Siga o formato das outras linhas: só as letras, separadas por vírgula (ex.: psd, ai). Ou escolha um tipo pronto na lista ao lado. Sem extensões, a subpasta é criada vazia. Arquivos de tipos que não estão em nenhuma subpasta ficam no cartão. Use / para uma subpasta dentro de outra (ex.: Fotos/Brutas). Clique no ícone para trocá-lo.")).Also(c => c.Margin = new Thickness(4, 6, 4, 0)));
    }

    /// <summary>Linha "[ícone] Subpasta: [nome]  recebe: [extensões] [tipos] [remover]".</summary>
    Control SubfolderRow(Subfolder f)
    {
        var iconBtn = Menu(f.Symbol, new[] { (L("Automático (pelo tipo de arquivo)"), (Action)(() => { f.Icon = null; Build(); })), ("-", () => { }) }
            .Concat(Subfolder.Icons.Select(i => ($"{i.Icon}   {L(i.Name)}", (Action)(() => { f.Icon = i.Icon; Build(); })))), flat: true);
        ToolTip.SetTip(iconBtn, L("Escolher ícone"));
        var name = new TextBox { Text = f.Path, Watermark = L("nome da subpasta") };
        name.TextChanged += (_, _) => { f.Path = name.Text ?? ""; Refresh(); };
        var exts = new TextBox { Text = string.Join(", ", f.Extensions), Watermark = L("extensões, ex.: psd, ai"), Width = 230 };
        exts.TextChanged += (_, _) => { f.Extensions = Subfolder.Parse(exts.Text ?? ""); Refresh(); };
        exts.LostFocus += (_, _) => Build();   // ícone automático e lista de nomes acompanham o tipo
        var types = Menu("☰", FileTypes.All.Select(t => ($"{FileTypes.Name(t)}  ({string.Join(", ", FileTypes.Extensions(t))})", (Action)(() =>
        {
            f.Extensions = [.. FileTypes.Extensions(t)];
            if (f.TrimmedPath.Length == 0) f.Path = FileTypes.Name(t);
            Build();
        }))).Append(("-", () => { })).Append((L("Nada (pasta vazia)"), () => { f.Extensions = []; Build(); })), flat: true);
        ToolTip.SetTip(types, L("Tipos de arquivo"));
        var rm = IconBtn("⛔", () =>
        {
            draft.Rules.RemoveAll(r => r.Folder == f.Id);
            draft.Folders.RemoveAll(x => x.Id == f.Id);
            Build();
        }, L("Remover subpasta"), Red);

        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*,Auto,Auto,Auto,Auto"), ColumnSpacing = 8 };
        void Put(Control c, int col) { Grid.SetColumn(c, col); c.VerticalAlignment = VerticalAlignment.Center; g.Children.Add(c); }
        Put(iconBtn, 0); Put(T(L("Subpasta:")), 1); Put(name, 2); Put(T(L("recebe:"), opacity: 0.6), 3); Put(exts, 4); Put(types, 5); Put(rm, 6);
        return g;
    }

    // MARK: Nomes dos arquivos

    void Files(StackPanel body)
    {
        body.Children.Add(Header(L("Nome dos arquivos"), L("Como os arquivos ficam depois de importados. Com Renomear marcado, todos levam o nome da pasta da captação e um número. Para um tipo de arquivo seguir outro padrão, ligue “Padrão próprio” na linha dele.")));
        var box = Col(10);
        var rename = new CheckBox
        {
            IsChecked = draft.Rename,
            Content = Col(2, T(L("Renomear os arquivos ao importar")),
                Caption(L("Usa o nome da pasta da captação (ou o padrão que você definir abaixo). Desmarcado, cada arquivo mantém o nome que veio do cartão, ex.: C0001.MP4."))),
        };
        rename.IsCheckedChanged += (_, _) => { draft.Rename = rename.IsChecked == true; Build(); };
        box.Children.Add(rename);
        var rows = Col(10);
        rows.IsEnabled = draft.Rename;
        rows.Opacity = draft.Rename ? 1 : 0.45;
        foreach (var f in draft.ReceivingFolders) rows.Children.Add(NamingRow(f));
        box.Children.Add(rows);
        body.Children.Add(Box(box));
        body.Children.Add(Caption(L("Etiquetas: {0} nome da pasta da captação · {1} só o nome · {2} {MM} {DD} data · {NNN} número com 3 dígitos (use {N}, {NN}, {NNNN}… para outros tamanhos; continua de onde a pasta parou) · {ORIGINAL} nome do arquivo no cartão. A extensão (.MP4, .WAV…) entra sozinha.", Tok.Folder, Tok.Name, Tok.Year)).Also(c => c.Margin = new Thickness(4, 6, 4, 0)));
    }

    static readonly string[] Samples = ["C0001.MP4", "IMG_0001.CR3", "IMG_0001.JPG", "ZOOM0001.WAV", "Roteiro.pdf", "Arte.psd"];

    /// <summary>Linha de uma subpasta: segue o padrão geral ou, com "Padrão próprio", mostra o campo do padrão.</summary>
    Control NamingRow(Subfolder f)
    {
        var rule = draft.Rules.FirstOrDefault(r => r.Folder == f.Id);
        var col = Col(6);
        var head = new DockPanel();
        var toggle = new ToggleSwitch { IsChecked = rule != null, OnContent = "", OffContent = "" };
        toggle.IsCheckedChanged += (_, _) =>
        {
            draft.Rules.RemoveAll(r => r.Folder == f.Id);
            if (toggle.IsChecked == true) draft.Rules.Add(new NamingRule { Folder = f.Id, Pattern = $"{Tok.Folder} - {{NNN}}" });
            Build();
        };
        var right = Row(8, T(L("Padrão próprio"), opacity: 0.6).Also(t => t.VerticalAlignment = VerticalAlignment.Center), toggle);
        DockPanel.SetDock(right, Dock.Right);
        head.Children.Add(right);
        head.Children.Add(Row(8, T(f.Symbol), T(f.TrimmedPath, 13, FontWeight.Medium)).Also(r => r.VerticalAlignment = VerticalAlignment.Center));
        col.Children.Add(head);
        if (rule != null)
        {
            var box = new TextBox { Text = rule.Pattern, FontFamily = new FontFamily("Consolas, Menlo, monospace"), Watermark = $"{Tok.Folder} - {{NNN}}" };
            box.TextChanged += (_, _) => { rule.Pattern = box.Text ?? ""; Refresh(); };
            var presets = Menu("☰", new (string, string)[]
            {
                ($"{L("CAPTAÇÃO")} - 001", $"{Tok.Folder} - {{NNN}}"),
                ($"{L("CAPTAÇÃO")}.1", $"{Tok.Folder}.{{N}}"),
                ($"{L("NOME")}_0001", $"{Tok.Name}_{{NNNN}}"),
                ("20261027_001", $"{Tok.Year}{{MM}}{{DD}}_{{NNN}}"),
                ($"{L("CAPTAÇÃO")} - {L("nome original")}", $"{Tok.Folder} - {{ORIGINAL}}"),
                (L("Nome original da câmera"), "{ORIGINAL}"),
            }.Select(p => ($"{p.Item1}      {p.Item2}", (Action)(() => box.Text = p.Item2))), flat: true);
            var line = new DockPanel { Margin = new Thickness(26, 0, 0, 0) };
            DockPanel.SetDock(presets, Dock.Right);
            line.Children.Add(presets);
            line.Children.Add(box);
            col.Children.Add(line);
        }
        var example = new ContentControl { Margin = new Thickness(26, 0, 0, 0) };
        var warn = Caption("", Orange).Also(c => c.Margin = new Thickness(26, 0, 0, 0));
        refreshers.Add(() =>
        {
            var c = draft.Clone();
            c.Rename = true;
            var own = draft.Rules.FirstOrDefault(r => r.Folder == f.Id)?.Pattern;
            c.Rules = own != null ? [new NamingRule { Folder = f.Id, Pattern = own }] : [];
            var t = FileTypes.Matching(f.Extensions);
            var src = t is { } ft ? Samples[(int)ft] : $"ARQUIVO.{(f.Extensions.FirstOrDefault() ?? "dat").ToUpperInvariant()}";
            var pattern = own ?? Config.DefaultFilePattern;
            var first = Naming.FileName(c, f, Sample, 1, src, DateTime.Today);
            example.Content = Example(Pattern.HasNumber(pattern) ? $"{first}, {Naming.FileName(c, f, Sample, 2, src, DateTime.Today)}…" : $"{src} → {first}");
            warn.Text = own is { Length: > 0 } && !Pattern.HasNumber(own) && !Pattern.HasOriginal(own) ? L("Sem número nem {ORIGINAL}, os arquivos vão ganhar (2), (3)… no fim.") : "";
        });
        col.Children.Add(example);
        col.Children.Add(warn);
        return col;
    }

    // MARK: Relatórios

    void ReportsSection(StackPanel body)
    {
        body.Children.Add(Header(L("Relatórios"), L("Um registro de cada importação: o que foi copiado, de qual cartão, para quais discos, e o checksum de cada arquivo. Serve para conferir depois ou para enviar ao cliente ou à produtora.")));
        var box = Col(10);
        var pdf = new CheckBox
        {
            IsChecked = draft.ReportPDF,
            Content = Col(2, T(L("Gerar um relatório em PDF de cada importação")),
                Caption(L("Captação, cartões, discos, horário, e cada arquivo com o nome original, o nome final, o tamanho e o checksum."))),
        };
        pdf.IsCheckedChanged += (_, _) => { draft.ReportPDF = pdf.IsChecked == true; Build(); };
        box.Children.Add(pdf);
        if (draft.ReportPDF)
        {
            var radios = Col(6);
            radios.Margin = new Thickness(28, 0, 0, 0);
            var junto = new RadioButton { GroupName = "rel", IsChecked = draft.ReportFolder.Length == 0, Content = L("Junto do backup: pasta Relatórios dentro da captação, em cada disco") };
            var other = new RadioButton { GroupName = "rel", IsChecked = draft.ReportFolder.Length > 0, Content = L("Numa pasta escolhida") };
            junto.IsCheckedChanged += (_, _) => { if (junto.IsChecked == true && draft.ReportFolder.Length > 0) { draft.ReportFolder = ""; Build(); } };
            other.Click += (_, _) => { if (draft.ReportFolder.Length == 0) _ = ChooseReportFolder(); };
            radios.Children.Add(junto);
            radios.Children.Add(other);
            if (draft.ReportFolder.Length > 0)
            {
                var line = new DockPanel();
                var change = Btn(L("Trocar…"), () => _ = ChooseReportFolder());
                DockPanel.SetDock(change, Dock.Right);
                line.Children.Add(change);
                line.Children.Add(Row(8, T("📁"), T(draft.ReportFolder, 11.5, opacity: 0.8)).Also(r => r.VerticalAlignment = VerticalAlignment.Center));
                radios.Children.Add(line);
            }
            box.Children.Add(radios);
        }
        var mhl = new CheckBox
        {
            IsChecked = draft.Mhl,
            Content = Col(2, T(L("Gerar o registro ASC MHL (padrão do mercado)")),
                Caption(L("Lista de checksums (xxHash64) que programas como Silverstack, ShotPut e OffShoot usam para conferir os arquivos depois. Fica na pasta ascmhl, dentro da captação, em cada disco."))),
        };
        mhl.IsCheckedChanged += (_, _) => draft.Mhl = mhl.IsChecked == true;
        box.Children.Add(mhl);
        body.Children.Add(Box(box));
    }

    async Task ChooseReportFolder()
    {
        var r = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = L("Escolha ou crie a pasta onde os relatórios vão ficar") });
        if (r.FirstOrDefault()?.TryGetLocalPath() is { } path) draft.ReportFolder = Path.GetFullPath(path);
        Build();
    }

    // MARK: Discos ignorados

    void Ignored(StackPanel body)
    {
        body.Children.Add(Header(L("Discos que não aparecem como cartão"), L("O app mostra como cartão todo disco removível que for conectado. Para não correr o risco de importar (ou limpar) os arquivos de um disco de trabalho, coloque aqui os discos que são seguros e nunca são cartões, como SSDs e HDs de backup. Os discos principal e de redundância já ficam de fora sozinhos.")));
        var list = Col(8);
        foreach (var v in draft.IgnoredVolumes.ToList())
        {
            var row = new DockPanel();
            var rm = IconBtn("⛔", () => { draft.IgnoredVolumes.Remove(v); Build(); }, L("Remover"), Red);
            DockPanel.SetDock(rm, Dock.Right);
            row.Children.Add(rm);
            row.Children.Add(Row(8, T("💽"), T(v)));
            list.Children.Add(row);
        }
        var candidates = Volume.Mounted().Where(v => !draft.IgnoredVolumes.Contains(v.Name)).ToList();
        IEnumerable<(string, Action)> items = candidates.Count > 0
            ? candidates.Select(v => ($"{v.Name}  ·  {L("{0} livres", Fmt.Bytes(v.Free))}", (Action)(() =>
              {
                  // Guarda o nome sem a letra (a letra pode mudar quando o disco é reconectado)
                  draft.IgnoredVolumes.Add(v.Name.Contains(" (") ? v.Name[..v.Name.LastIndexOf(" (", StringComparison.Ordinal)] : v.Name);
                  Build();
              })))
            : [(L("Nenhum outro disco conectado"), () => { })];
        list.Children.Add(Menu("+ " + L("Adicionar disco"), items, flat: true));
        body.Children.Add(Box(list));
        body.Children.Add(Caption(L("Dica: na lista de cartões, clique num disco com o botão direito para escondê-lo.")).Also(c => c.Margin = new Thickness(4, 6, 4, 0)));
    }
}
