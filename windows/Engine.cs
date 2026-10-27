// Motor do app (versão Windows): lista as captações, lê os cartões e copia com verificação.
// É a mesma lógica do app do Mac (Sources/Engine.swift). Nada aqui apaga, move ou renomeia
// arquivo do cartão, a não ser na limpeza pedida no fim, que confere cada arquivo antes de apagar.

using System.Collections.Concurrent;
using System.IO.Hashing;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using static Acervo.Loc;

namespace Acervo;

// MARK: Tipos de arquivo (modelos para o que cada subpasta recebe)

public enum FileType { Videos, Raw, Jpg, Audios, Documentos, Design }

public static class FileTypes
{
    public static readonly FileType[] All = Enum.GetValues<FileType>();

    public static string Name(FileType t) => t switch
    {
        FileType.Videos => L("Vídeos"),
        FileType.Raw => L("Fotos RAW"),
        FileType.Jpg => L("Fotos JPG e HEIC"),
        FileType.Audios => L("Áudios"),
        FileType.Documentos => L("Documentos"),
        _ => L("Design (PSD, AI)"),
    };

    public static string[] Extensions(FileType t) => t switch
    {
        FileType.Videos => ["mp4", "mov", "mxf", "braw"],
        FileType.Raw => ["cr2", "cr3", "arw", "nef", "raf", "rw2", "orf", "dng"],
        FileType.Jpg => ["jpg", "jpeg", "heic"],
        FileType.Audios => ["mp3", "wav"],
        FileType.Documentos => ["pdf", "doc", "docx", "pages", "rtf", "odt"],
        _ => ["psd", "psb", "ai"],
    };

    public static string Icon(FileType t) => t switch
    {
        FileType.Videos => "🎬",
        FileType.Raw or FileType.Jpg => "📷",
        FileType.Audios => "🎙",
        FileType.Documentos => "📄",
        _ => "🎨",
    };

    public static FileType? Matching(IEnumerable<string> exts)
    {
        var set = exts.ToHashSet();
        foreach (var t in All) if (Extensions(t).Any(set.Contains)) return t;
        return null;
    }
}

// MARK: Configuração (escolhida na primeira abertura, muda em Ajustes)

/// <summary>Subpasta criada em toda captação; recebe os arquivos com as extensões listadas
/// (sem extensões = pasta vazia, ex.: Fotos/Seleção).</summary>
public class Subfolder
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Path { get; set; } = "";
    public List<string> Extensions { get; set; } = [];
    /// <summary>Ícone escolhido pela pessoa (null = automático, pelo tipo de arquivo).</summary>
    public string? Icon { get; set; }

    public Subfolder() { }
    public Subfolder(string path, FileType? type) { Path = path; Extensions = type is { } t ? [.. FileTypes.Extensions(t)] : []; }

    public string TrimmedPath => string.Join("/", Path.Split('/', '\\').Select(p => p.Trim()).Where(p => p.Length > 0));
    public bool Receives => Extensions.Count > 0 && TrimmedPath.Length > 0;
    public string Symbol => Icon ?? (FileTypes.Matching(Extensions) is { } t ? FileTypes.Icon(t) : Extensions.Count == 0 ? "📁" : "📄");
    public string ExtensionsLabel => string.Join(", ", Extensions.Select(e => e.ToUpperInvariant()));
    /// <summary>Documentos só vêm marcados se a pessoa marcar; o resto já vem marcado.</summary>
    public bool OnByDefault => !Extensions.All(e => FileTypes.Extensions(FileType.Documentos).Contains(e));

    /// <summary>"mp4, .MOV;wav" → ["mp4", "mov", "wav"]</summary>
    public static List<string> Parse(string text)
    {
        var o = new List<string>();
        foreach (var part in text.Split([',', ' ', ';'], StringSplitOptions.RemoveEmptyEntries))
        {
            var e = part.Trim('.', ' ').ToLowerInvariant();
            if (e.Length > 0 && !o.Contains(e)) o.Add(e);
        }
        return o;
    }

    public static readonly (string Icon, string Name)[] Icons =
    [
        ("📁", "Pasta"), ("🎬", "Vídeo"), ("🎞", "Filme"), ("📷", "Câmera"), ("🖼", "Foto"), ("🎙", "Microfone"),
        ("🎵", "Música"), ("📄", "Documento"), ("🎨", "Design"), ("🧊", "3D"), ("💬", "Legenda"), ("⭐", "Favoritos"),
        ("🗄", "Arquivo"), ("✈", "Drone"), ("👥", "Pessoas"),
    ];
}

public class NamingRule
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid Folder { get; set; }
    public string Pattern { get; set; } = "";
}

public class Config
{
    /// <summary>Disco principal: a pasta onde ficam as captações.</summary>
    public string Inbox { get; set; } = "";
    /// <summary>Discos de redundância: recebem uma cópia idêntica, com a mesma pasta e os mesmos nomes.</summary>
    public List<string> Backups { get; set; } = [];
    public string FolderPattern { get; set; } = "{AAAA}{MM}{DD} - {NOME}";
    public List<Subfolder> Folders { get; set; } = [];
    /// <summary>Desligado, os arquivos mantêm o nome que vieram do cartão.</summary>
    public bool Rename { get; set; }
    public List<NamingRule> Rules { get; set; } = [];
    /// <summary>Discos que nunca aparecem na lista de cartões.</summary>
    public List<string> IgnoredVolumes { get; set; } = [];
    public bool SplitByCard { get; set; }
    public bool ReportPDF { get; set; } = true;
    /// <summary>Pasta dos relatórios ("" = junto do backup, na pasta da captação).</summary>
    public string ReportFolder { get; set; } = "";
    public bool Mhl { get; set; } = true;

    public const string DefaultFilePattern = "{PASTA} - {NNN}";

    public IEnumerable<Subfolder> ReceivingFolders => Folders.Where(f => f.Receives);
    public IEnumerable<string> BackupPaths => Backups.Where(b => b.Length > 0);

    public Subfolder? FolderFor(string file)
    {
        var ext = System.IO.Path.GetExtension(file).TrimStart('.').ToLowerInvariant();
        return ReceivingFolders.FirstOrDefault(f => f.Extensions.Contains(ext));
    }
    public Subfolder? FolderById(Guid id) => Folders.FirstOrDefault(f => f.Id == id);

    /// <summary>Padrão de nome de uma subpasta: o próprio (se tiver) ou o geral; null = nome original.</summary>
    public string? PatternFor(Subfolder f)
    {
        if (!Rename) return null;
        var own = Rules.FirstOrDefault(r => r.Folder == f.Id)?.Pattern.Trim() ?? "";
        return own.Length == 0 ? DefaultFilePattern : own;
    }

    public List<string> CaptureFolders => Folders.Select(f => f.TrimmedPath).Where(p => p.Length > 0).Distinct().ToList();

    public Config Clone() => JsonSerializer.Deserialize<Config>(JsonSerializer.Serialize(this))!;

    /// <summary>Modelo para quem está começando (nomes no idioma do sistema).</summary>
    public static Config Simple()
    {
        var v = new Subfolder(L("Vídeos"), FileType.Videos);
        var f = new Subfolder(L("Fotos"), FileType.Raw);
        var a = new Subfolder(L("Áudios"), FileType.Audios);
        var d = new Subfolder(L("Documentos"), FileType.Documentos);
        return new Config
        {
            FolderPattern = $"{Tok.Year}{{MM}}{{DD}} - {Tok.Name}",
            Folders = [v, f, a, d],
            Rules = [new NamingRule { Folder = d.Id, Pattern = "{ORIGINAL}" }],
        };
    }

    /// <summary>Padrão da Vértice (sem os discos, que no Windows têm outras letras).</summary>
    public static Config Vertice()
    {
        var v = new Subfolder("Vídeos", FileType.Videos);
        var f = new Subfolder("Fotos/Brutas", FileType.Raw);
        var s = new Subfolder("Fotos/Seleção", null);
        var a = new Subfolder("Áudios", FileType.Audios);
        var d = new Subfolder("Documentos", FileType.Documentos);
        return new Config
        {
            FolderPattern = "{AAAA}{MM}{DD} - {NOME}",
            Folders = [v, f, s, a, d],
            Rename = true,
            Rules = [new NamingRule { Folder = a.Id, Pattern = "{PASTA}.{N}" }, new NamingRule { Folder = d.Id, Pattern = "{ORIGINAL}" }],
        };
    }

    // Guardada em %APPDATA%\Acervo\config.json (ACERVO_CONFIG_DIR troca a pasta, para testes)
    public static string FilePath => System.IO.Path.Combine(
        Environment.GetEnvironmentVariable("ACERVO_CONFIG_DIR") is { Length: > 0 } dir ? dir
            : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Acervo"), "config.json");

    public static Config? Load()
    {
        try { return File.Exists(FilePath) ? JsonSerializer.Deserialize<Config>(File.ReadAllText(FilePath)) : null; }
        catch { return null; }
    }

    public void Save()
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}

// MARK: Discos

public record Volume(string Root, string Name, long Free, bool Removable)
{
    public static List<Volume> Mounted()
    {
        var o = new List<Volume>();
        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                if (!d.IsReady) continue;
                if (OperatingSystem.IsMacOS() && d.RootDirectory.FullName != "/" && !d.RootDirectory.FullName.StartsWith("/Volumes/")) continue;
                if (OperatingSystem.IsWindows() && d.DriveType is not (DriveType.Fixed or DriveType.Removable or DriveType.Network)) continue;
                o.Add(new Volume(d.RootDirectory.FullName, Label(d), d.AvailableFreeSpace, d.DriveType == DriveType.Removable));
            }
            catch { /* disco que sumiu no meio */ }
        }
        return o;
    }

    static string Label(DriveInfo d)
    {
        if (OperatingSystem.IsWindows())
        {
            var letter = d.Name.TrimEnd('\\');
            return string.IsNullOrWhiteSpace(d.VolumeLabel) ? letter : $"{d.VolumeLabel} ({letter})";
        }
        return d.RootDirectory.FullName == "/" ? "Macintosh HD" : System.IO.Path.GetFileName(d.RootDirectory.FullName.TrimEnd('/'));
    }

    /// <summary>Nome do disco onde está uma pasta ("Mídias (E:)", "Projetos"…).</summary>
    public static string NameOf(string path)
    {
        try
        {
            var full = System.IO.Path.GetFullPath(path);
            if (OperatingSystem.IsMacOS())
            {
                var parts = full.Split('/', StringSplitOptions.RemoveEmptyEntries);
                return parts.Length >= 2 && parts[0] == "Volumes" ? parts[1] : "Macintosh HD";
            }
            var root = System.IO.Path.GetPathRoot(full) ?? full;
            var d = new DriveInfo(root);
            return d.IsReady ? Label(d) : root.TrimEnd('\\');
        }
        catch { return path; }
    }

    /// <summary>Raiz do disco de uma pasta (para comparar se duas pastas estão no mesmo disco).</summary>
    public static string RootOf(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        if (OperatingSystem.IsMacOS())
        {
            var parts = full.Split('/', StringSplitOptions.RemoveEmptyEntries);
            return parts.Length >= 2 && parts[0] == "Volumes" ? $"/Volumes/{parts[1]}" : "/";
        }
        return (System.IO.Path.GetPathRoot(full) ?? full).ToUpperInvariant();
    }

    public static long FreeSpace(string path)
    {
        try { return new DriveInfo(RootOf(path)).AvailableFreeSpace; } catch { return long.MaxValue; }
    }
}

// MARK: Padrões de nome

/// <summary>Etiquetas aceitas nos três idiomas (o app grava e lê qualquer uma delas).</summary>
public static class Tok
{
    static readonly Dictionary<string, string> Aliases = new()
    {
        ["PASTA"] = "PASTA", ["FOLDER"] = "PASTA", ["CARPETA"] = "PASTA",
        ["NOME"] = "NOME", ["NAME"] = "NOME", ["NOMBRE"] = "NOME",
        ["AAAA"] = "AAAA", ["YYYY"] = "AAAA", ["AA"] = "AA", ["YY"] = "AA",
        ["MM"] = "MM", ["DD"] = "DD", ["ORIGINAL"] = "ORIGINAL",
    };

    public static bool IsNumber(string name) => name.Length > 0 && name.All(c => c == 'N');
    public static string? Canonical(string name) => IsNumber(name) ? name : Aliases.GetValueOrDefault(name);

    public static string Folder => Lang.Pick("{PASTA}", "{FOLDER}", "{CARPETA}");
    public static string Name => Lang.Pick("{NOME}", "{NAME}", "{NOMBRE}");
    public static string Year => Lang.Pick("{AAAA}", "{YYYY}", "{AAAA}");
    public static string ShortYear => Lang.Pick("{AA}", "{YY}", "{AA}");
}

public static class Pattern
{
    public static readonly Regex Token = new(@"\{([A-Z]+)\}");

    public static string Render(string pattern, string folder = "", string title = "", DateTime? date = null,
                                string original = "", int number = 1)
    {
        var o = Token.Replace(pattern, m =>
        {
            var raw = m.Groups[1].Value;
            var c = Tok.Canonical(raw);
            if (c == null) return m.Value;
            if (Tok.IsNumber(c)) return number.ToString().PadLeft(c.Length, '0');
            return c switch
            {
                "PASTA" => folder,
                "NOME" => title,
                "ORIGINAL" => original,
                "AAAA" => date?.ToString("yyyy") ?? raw,
                "AA" => date?.ToString("yy") ?? raw,
                "MM" => date?.ToString("MM") ?? raw,
                "DD" => date?.ToString("dd") ?? raw,
                _ => m.Value,
            };
        });
        // Caracteres que não podem entrar em nome de arquivo (Windows e Mac)
        foreach (var bad in new[] { '/', '\\', ':', '*', '?', '"', '<', '>', '|' }) o = o.Replace(bad, '-');
        return o.Trim().TrimEnd('.');
    }

    public static bool HasNumber(string pattern) => Regex.IsMatch(pattern, @"\{N+\}");
    public static bool HasOriginal(string pattern) => pattern.Contains("{ORIGINAL}");

    /// <summary>Reconhece nomes feitos com o padrão. `fix` dá o valor de etiquetas já conhecidas;
    /// as outras viram grupos que dá para ler (data, nome, número).</summary>
    public class Matcher
    {
        readonly Regex re;
        readonly List<string> groups = [];

        public Matcher(string pattern, Dictionary<string, string>? fix = null)
        {
            var o = "^";
            var rest = pattern;
            while (Token.Match(rest) is { Success: true } m)
            {
                o += Regex.Escape(rest[..m.Index]);
                var raw = m.Groups[1].Value;
                if (Tok.Canonical(raw) is { } name)
                {
                    var group = Tok.IsNumber(name) ? "N" : name;
                    if (fix != null && fix.TryGetValue(name, out var v)) o += Regex.Escape(v);
                    else if (groups.Contains(group)) o += ".+?";
                    else
                    {
                        groups.Add(group);
                        o += group switch
                        {
                            "AAAA" => @"(?<AAAA>\d{4})",
                            "AA" or "MM" or "DD" => $@"(?<{group}>\d{{2}})",
                            "N" => @"(?<N>\d+)",
                            _ => $"(?<{group}>.+?)",
                        };
                    }
                }
                else o += Regex.Escape(m.Value);
                rest = rest[(m.Index + m.Length)..];
            }
            o += Regex.Escape(rest) + "$";
            re = new Regex(o, RegexOptions.IgnoreCase);
        }

        public Dictionary<string, string>? Match(string s)
        {
            var m = re.Match(s);
            if (!m.Success) return null;
            return groups.Where(g => m.Groups[g].Success).ToDictionary(g => g, g => m.Groups[g].Value);
        }
    }

    public static DateTime? DateFrom(Dictionary<string, string> g)
    {
        if (!g.TryGetValue("MM", out var ms) || !g.TryGetValue("DD", out var ds)) return null;
        int y;
        if (g.TryGetValue("AAAA", out var ys)) y = int.Parse(ys);
        else if (g.TryGetValue("AA", out var yy)) y = 2000 + int.Parse(yy);
        else return null;
        try { return new DateTime(y, int.Parse(ms), int.Parse(ds)); } catch { return null; }
    }
}

public static class Naming
{
    /// <summary>Nome final de um arquivo do cartão, conforme a regra da subpasta (ou o nome original).</summary>
    public static string FileName(Config cfg, Subfolder folder, Capture capture, int number, string source, DateTime date)
    {
        var pattern = cfg.PatternFor(folder);
        if (pattern == null) return System.IO.Path.GetFileName(source);
        var original = System.IO.Path.GetFileNameWithoutExtension(source);
        var ext0 = System.IO.Path.GetExtension(source).TrimStart('.');
        // Com {ORIGINAL} a extensão fica como veio; nos outros, em maiúsculas (padrão dos atalhos).
        var ext = Pattern.HasOriginal(pattern) ? ext0 : ext0.ToUpperInvariant();
        var stem = Pattern.Render(pattern, capture.Name, capture.Title, capture.Date ?? date, original, number);
        if (stem.Length == 0) stem = original;
        return $"{stem}.{ext}";
    }

    public static Pattern.Matcher NumberMatcher(string pattern, Capture capture)
    {
        var fix = new Dictionary<string, string> { ["PASTA"] = capture.Name, ["NOME"] = capture.Title };
        if (capture.Date is { } d)
            foreach (var t in new[] { "AAAA", "AA", "MM", "DD" }) fix[t] = Pattern.Render("{" + t + "}", date: d);
        return new Pattern.Matcher(pattern, fix);
    }
}

// MARK: Captações do disco principal

public record Capture(string Name, DateTime? Date, string Title)
{
    static readonly Regex Legacy = new(@"^(\d{8})\s*-?\s*(.*)$");

    public static Capture From(string name, Pattern.Matcher? matcher)
    {
        if (matcher?.Match(name) is { } g && Pattern.DateFrom(g) is { } d)
        {
            var t = g.GetValueOrDefault("NOME", "").Trim();
            return new Capture(name, d, t.Length == 0 ? name : t);
        }
        // Pastas antigas: "20261020 - CC BEB Atividade Extra"
        var m = Legacy.Match(name);
        if (m.Success && DateTime.TryParseExact(m.Groups[1].Value, "yyyyMMdd", null, System.Globalization.DateTimeStyles.None, out var ld))
            return new Capture(name, ld, m.Groups[2].Value.Trim().Length == 0 ? name : m.Groups[2].Value.Trim());
        return new Capture(name, null, name);
    }

    /// <summary>Mais recente no topo; pastas sem data no fim, em ordem alfabética.</summary>
    public static List<Capture> List(Config cfg)
    {
        if (!Directory.Exists(cfg.Inbox)) return [];
        var matcher = new Pattern.Matcher(cfg.FolderPattern);
        var all = new DirectoryInfo(cfg.Inbox).EnumerateDirectories()
            .Where(d => !d.Name.StartsWith('.') && !d.Attributes.HasFlag(FileAttributes.Hidden))
            .Select(d => From(d.Name, matcher)).ToList();
        return all.Where(c => c.Date != null).OrderByDescending(c => c.Date).ThenByDescending(c => c.Name, StringComparer.CurrentCultureIgnoreCase)
            .Concat(all.Where(c => c.Date == null).OrderBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase)).ToList();
    }

    public static string FolderName(Config cfg, DateTime date, string title) =>
        Pattern.Render(cfg.FolderPattern, title: title.Trim(), date: date);

    /// <summary>Cria a pasta da captação com as subpastas escolhidas. Não mexe em nada que já exista.</summary>
    public static string Create(string name, Config cfg)
    {
        var root = System.IO.Path.Combine(cfg.Inbox, name);
        Directory.CreateDirectory(root);
        foreach (var sub in cfg.CaptureFolders) Directory.CreateDirectory(System.IO.Path.Combine(root, sub));
        return root;
    }
}

// MARK: Arquivos do cartão

public record SourceFile(string Path, long Size, DateTime Date, Guid Folder, string Card)
{
    public string CardName => CardScanner.CardName(Card);
}

public static class CardScanner
{
    /// <summary>Pastas que o cartão tem e não interessam (proxies da Sony, lixo do sistema).</summary>
    static readonly HashSet<string> Skipped = new(StringComparer.OrdinalIgnoreCase)
        { ".Spotlight-V100", ".Trashes", ".fseventsd", "SUB", "THMBNL", "System Volume Information", "$RECYCLE.BIN" };

    /// <summary>Pastas que os cartões das câmeras costumam ter.</summary>
    public static readonly string[] CameraFolders = ["DCIM", "PRIVATE", "CLIP", "M4ROOT", "XDROOT", "AVCHD", "Blackmagic RAW"];
    public static bool LooksLikeCard(string root) => CameraFolders.Any(f => Directory.Exists(System.IO.Path.Combine(root, f)));

    public static string CardName(string root)
    {
        if (OperatingSystem.IsWindows() && System.IO.Path.GetPathRoot(root) == root) return Volume.NameOf(root);
        return System.IO.Path.GetFileName(root.TrimEnd('/', '\\'));
    }

    /// <summary>Vários cartões: junta tudo em ordem de gravação (as câmeras ficam intercaladas no tempo).</summary>
    public static List<SourceFile> Scan(IEnumerable<string> roots, Config cfg) => Sorted(roots.SelectMany(r => Scan(r, cfg)));

    static List<SourceFile> Sorted(IEnumerable<SourceFile> files) =>
        files.OrderBy(f => f.Date).ThenBy(f => f.Path, StringComparer.OrdinalIgnoreCase).ToList();

    public static List<SourceFile> Scan(string root, Config cfg)
    {
        var o = new List<SourceFile>();
        void Walk(DirectoryInfo dir)
        {
            IEnumerable<FileSystemInfo> items;
            try { items = dir.EnumerateFileSystemInfos().ToList(); } catch { return; }
            foreach (var it in items)
            {
                if (it.Name.StartsWith('.') || Skipped.Contains(it.Name)) continue;
                if (it is DirectoryInfo d) { if (!d.Attributes.HasFlag(FileAttributes.System)) Walk(d); continue; }
                if (it is not FileInfo fi || cfg.FolderFor(fi.Name) is not { } folder) continue;
                var date = fi.CreationTime < fi.LastWriteTime ? fi.CreationTime : fi.LastWriteTime;
                o.Add(new SourceFile(fi.FullName, fi.Length, date, folder.Id, root));
            }
        }
        if (Directory.Exists(root)) Walk(new DirectoryInfo(root));
        // Ordem de gravação: assim o 001 é sempre o primeiro clipe/foto do dia.
        return Sorted(o);
    }
}

// MARK: Plano de importação

public record CopyJob(SourceFile Source, List<string> Targets)
{
    public string Name => System.IO.Path.GetFileName(Targets[0]);
}

/// <summary>Arquivo do cartão que já está no disco principal (mesmo tamanho e mesmo conteúdo).</summary>
public record Duplicate(SourceFile Source, string Existing, string Capture);

public class ImportPlan
{
    public string Capture = "";
    /// <summary>Pasta da captação em cada destino: o disco principal primeiro, depois as redundâncias.</summary>
    public List<string> Roots = [];
    public List<CopyJob> Jobs = [];
    public List<Duplicate> Duplicates = [];
    public long Bytes => Jobs.Sum(j => j.Source.Size);
    public IEnumerable<Duplicate> AlreadyHere => Duplicates.Where(d => d.Capture == Capture);
    public IEnumerable<Duplicate> Elsewhere => Duplicates.Where(d => d.Capture != Capture);

    public static ImportPlan Make(List<SourceFile> files, HashSet<Guid> selected, Capture capture, Config cfg, List<string> backups)
    {
        var plan = new ImportPlan { Capture = capture.Name };
        var chosen = files.Where(f => selected.Contains(f.Folder)).ToList();
        var index = new InboxIndex(cfg, chosen.Select(f => f.Size).ToHashSet(), capture.Name);
        var root = System.IO.Path.Combine(cfg.Inbox, capture.Name);
        var backupRoots = backups.Select(b => System.IO.Path.Combine(b, capture.Name)).ToList();
        plan.Roots = [root, .. backupRoots];
        // Com mais de um cartão e "separar por cartão", cada cartão ganha a sua subpasta
        var split = cfg.SplitByCard && chosen.Select(f => f.Card).Distinct().Count() > 1;
        foreach (var folder in cfg.ReceivingFolders.Where(f => selected.Contains(f.Id)))
        {
            var ofFolder = chosen.Where(f => f.Folder == folder.Id).ToList();
            var groups = split
                ? ofFolder.GroupBy(f => f.CardName).OrderBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase).Select(g => (g.Key, g.ToList())).ToList()
                : [("", ofFolder)];
            foreach (var (cardName, group) in groups)
            {
                var sub = cardName.Length == 0 ? folder.TrimmedPath : $"{folder.TrimmedPath}/{cardName}";
                var dest = System.IO.Path.Combine(root, sub);
                var backupDests = backupRoots.Select(b => System.IO.Path.Combine(b, sub)).ToList();
                var existing = Names(dest);
                var used = new HashSet<string>(existing, StringComparer.OrdinalIgnoreCase);
                foreach (var b in backupDests) used.UnionWith(Names(b));
                var pattern = cfg.PatternFor(folder);
                var numbered = pattern != null && Pattern.HasNumber(pattern);
                var matcher = pattern != null ? Naming.NumberMatcher(pattern, capture) : null;
                var number = existing.Select(n => matcher?.Match(System.IO.Path.GetFileNameWithoutExtension(n)) is { } g
                                                   && g.TryGetValue("N", out var s) && int.TryParse(s, out var i) ? i : 0)
                                     .DefaultIfEmpty(0).Max() + 1;
                foreach (var file in group)
                {
                    if (index.Match(file) is { } dup) { plan.Duplicates.Add(dup); continue; }
                    string Make(int n) => Naming.FileName(cfg, folder, capture, n, file.Path, file.Date);
                    var name = Make(number);
                    if (numbered)
                    {
                        while (used.Contains(name)) name = Make(++number);
                        number++;
                    }
                    else
                    {
                        // Sem número (ex.: nome original): nomes repetidos ganham " (2)", " (3)"…
                        var stem = System.IO.Path.GetFileNameWithoutExtension(name);
                        var ext = System.IO.Path.GetExtension(name);
                        for (var k = 2; used.Contains(name); k++) name = $"{stem} ({k}){ext}";
                    }
                    used.Add(name);
                    plan.Jobs.Add(new CopyJob(file, [System.IO.Path.Combine(dest, name), .. backupDests.Select(b => System.IO.Path.Combine(b, name))]));
                }
            }
        }
        return plan;
    }

    static List<string> Names(string dir)
    {
        try { return Directory.Exists(dir) ? new DirectoryInfo(dir).EnumerateFiles().Select(f => f.Name).Where(n => !n.StartsWith('.')).ToList() : []; }
        catch { return []; }
    }
}

/// <summary>Arquivos já importados no disco principal, por tamanho (só os tamanhos que existem no cartão).
/// Olha a captação inteira, em qualquer subpasta: mesmo tamanho + mesmo começo e fim = mesmo arquivo.</summary>
public class InboxIndex
{
    readonly Dictionary<long, List<(string Path, string Capture)>> bySize = [];

    public InboxIndex(Config cfg, HashSet<long> sizes, string preferring)
    {
        if (sizes.Count == 0 || !Directory.Exists(cfg.Inbox)) return;
        var captures = new DirectoryInfo(cfg.Inbox).EnumerateDirectories().Where(d => !d.Name.StartsWith('.'))
            .OrderBy(d => d.Name == preferring ? 0 : 1).ToList();
        var opts = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.System };
        foreach (var c in captures)
        {
            IEnumerable<FileInfo> files;
            try { files = c.EnumerateFiles("*", opts); } catch { continue; }
            foreach (var f in files)
            {
                if (f.Name.StartsWith('.') || !sizes.Contains(f.Length)) continue;
                if (!bySize.TryGetValue(f.Length, out var l)) bySize[f.Length] = l = [];
                l.Add((f.FullName, c.Name));
            }
        }
    }

    public Duplicate? Match(SourceFile file)
    {
        if (!bySize.TryGetValue(file.Size, out var candidates) || Signature.Of(file.Path) is not { } sig) return null;
        foreach (var c in candidates)
            if (Signature.Of(c.Path) is { } s && s.SequenceEqual(sig)) return new Duplicate(file, c.Path, c.Capture);
        return null;
    }
}

/// <summary>Hash do primeiro e do último 256 KB: rápido e suficiente para reconhecer o mesmo arquivo.
/// (Antes de apagar algo do cartão, a conferência é feita no arquivo inteiro.)</summary>
public static class Signature
{
    const int Span = 256 * 1024;
    public static byte[]? Of(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buf = new byte[Span];
            var n = fs.ReadAtLeast(buf, Span, throwOnEndOfStream: false);
            sha.AppendData(buf, 0, n);
            if (fs.Length > Span)
            {
                fs.Seek(fs.Length - Span, SeekOrigin.Begin);
                n = fs.ReadAtLeast(buf, Span, throwOnEndOfStream: false);
                sha.AppendData(buf, 0, n);
            }
            return sha.GetHashAndReset();
        }
        catch { return null; }
    }
}

// MARK: Cópia com verificação

public record VerifiedCopy(string Source, string Copy, long Size);

/// <summary>Um arquivo copiado e conferido (para o relatório e o ASC MHL).</summary>
public record FileEntry(string Source, string CardName, long Size, string Hash, List<string> Targets, DateTime Modified, DateTime HashDate);

public class ImportReport
{
    public ImportPlan Plan = new();
    public List<VerifiedCopy> Copies = [];
    public List<FileEntry> Entries = [];
    public Dictionary<Guid, int> Copied = [];
    public int Verified, Skipped;
    public List<string> Failures = [];
    /// <summary>Avisos que não afetam as cópias (ex.: relatório que não pôde ser salvo).</summary>
    public List<string> Warnings = [];
    public bool Cancelled;
    public long Bytes;
    public DateTime Start = DateTime.Now, End = DateTime.Now;
    public double Seconds => (End - Start).TotalSeconds;
}

public record Progress(long Done, long Total, int FileIndex, int FileCount, string FileName, string Phase, int Cards = 1);

public class CleanupReport
{
    public int Deleted, Leftovers;
    public long Bytes;
    public List<string> Problems = [];
    public bool Cancelled;
}

public class CopyException(string message) : Exception(message);
public class CancelledException() : Exception("cancelado");

public class Copier
{
    volatile bool cancelled;
    public bool IsCancelled => cancelled;
    public void Cancel() => cancelled = true;

    const int Chunk = 8 * 1024 * 1024;

    /// <summary>Copia cada arquivo para um temporário oculto, relê a cópia do disco (sem cache),
    /// compara o xxHash64 com o do original e só então dá o nome final.
    /// Cada cartão é copiado ao mesmo tempo que os outros (um leitor não espera o outro).</summary>
    public ImportReport Run(ImportPlan plan, Action<Progress> onProgress)
    {
        var state = new object();
        var report = new ImportReport { Plan = plan, Skipped = plan.Duplicates.Count, Start = DateTime.Now };
        var total = plan.Jobs.Sum(j => j.Source.Size * (1 + j.Targets.Count));
        long done = 0;
        var finished = 0;
        var last = DateTime.MinValue;
        string copying = L("Copiando"), checking = L("Conferindo");
        var byCard = plan.Jobs.GroupBy(j => j.Source.Card).Select(g => g.ToList()).ToList();

        void Tick(string name, string phase, long add = 0, bool force = false)
        {
            Progress? p = null;
            lock (state)
            {
                done += add;
                if (force || (DateTime.Now - last).TotalMilliseconds > 100)
                {
                    last = DateTime.Now;
                    p = new Progress(done, total, finished, plan.Jobs.Count, name, phase, byCard.Count);
                }
            }
            if (p != null) onProgress(p);
        }

        Parallel.ForEach(byCard, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, byCard.Count) }, jobs =>
        {
            var buffer = new AlignedBuffer(Chunk);
            try
            {
                foreach (var job in jobs)
                {
                    if (cancelled) { lock (state) report.Cancelled = true; break; }
                    Tick(job.Name, copying, force: true);
                    var temps = job.Targets.Select(t => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(t)!, $".{System.IO.Path.GetFileName(t)}.importando")).ToList();
                    try
                    {
                        foreach (var t in job.Targets)
                        {
                            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(t)!);
                            if (File.Exists(t)) throw new CopyException(L("já existe um arquivo chamado {0}", System.IO.Path.GetFileName(t)));
                        }
                        var digest = Copy(job.Source.Path, temps, buffer, n => Tick(job.Name, copying, n));
                        var modified = File.GetLastWriteTime(job.Source.Path);
                        for (var i = 0; i < temps.Count; i++)
                        {
                            Tick(job.Name, checking, force: true);
                            var check = Hash(temps[i], buffer, n => Tick(job.Name, checking, n));
                            if (check != digest) throw new CopyException(L("a cópia de {0} não bate com o original", System.IO.Path.GetFileName(job.Targets[i])));
                            File.SetCreationTime(temps[i], job.Source.Date);
                            File.SetLastWriteTime(temps[i], modified);
                            File.SetAttributes(temps[i], FileAttributes.Normal);
                            File.Move(temps[i], job.Targets[i]);
                        }
                        var entry = new FileEntry(job.Source.Path, job.Source.CardName, job.Source.Size, Hex(digest), job.Targets, modified, DateTime.Now);
                        lock (state)
                        {
                            report.Copies.Add(new VerifiedCopy(job.Source.Path, job.Targets[0], job.Source.Size));
                            report.Entries.Add(entry);
                            report.Copied[job.Source.Folder] = report.Copied.GetValueOrDefault(job.Source.Folder) + 1;
                            report.Verified++;
                            report.Bytes += job.Source.Size;
                            finished++;
                        }
                    }
                    catch (CancelledException)
                    {
                        foreach (var t in temps) TryDelete(t);   // só a cópia incompleta
                        lock (state) report.Cancelled = true;
                        break;
                    }
                    catch (Exception e)
                    {
                        foreach (var t in temps) TryDelete(t);   // só a cópia que falhou
                        lock (state)
                        {
                            report.Failures.Add($"{System.IO.Path.GetFileName(job.Source.Path)} → {job.Name}: {Message(e)}");
                            finished++;
                        }
                    }
                }
            }
            finally { buffer.Dispose(); }
        });
        // Relatório na ordem de gravação, não na ordem em que os cartões terminaram
        var rank = plan.Jobs.Select((j, i) => (j.Source.Path, i)).ToDictionary(x => x.Path, x => x.i);
        report.Entries.Sort((a, b) => rank.GetValueOrDefault(a.Source).CompareTo(rank.GetValueOrDefault(b.Source)));
        report.End = DateTime.Now;
        Tick("", L("Pronto"), force: true);
        return report;
    }

    /// <summary>Limpa os cartões: relê o original e a cópia inteiros, compara o xxHash64
    /// e só então apaga o original. O que não bater (ou sumir do disco) fica no cartão.</summary>
    public CleanupReport CleanCards(List<string> roots, List<VerifiedCopy> items, Action<Progress> onProgress)
    {
        var report = new CleanupReport();
        var total = items.Sum(i => i.Size * 2);
        long done = 0;
        var last = DateTime.MinValue;
        var checking = L("Conferindo");
        var buffer = new AlignedBuffer(Chunk);
        void Tick(int i, string name, bool force = false)
        {
            if (force || (DateTime.Now - last).TotalMilliseconds > 100)
            {
                last = DateTime.Now;
                onProgress(new Progress(done, total, i, items.Count, name, checking));
            }
        }
        var rootPaths = roots.Select(r => System.IO.Path.GetFullPath(r).TrimEnd('/', '\\') + System.IO.Path.DirectorySeparatorChar).ToList();
        try
        {
            for (var i = 0; i < items.Count; i++)
            {
                if (cancelled) { report.Cancelled = true; break; }
                var item = items[i];
                var name = System.IO.Path.GetFileName(item.Source);
                Tick(i, name, true);
                try
                {
                    // Segurança: só apaga dentro dos cartões escolhidos.
                    var full = System.IO.Path.GetFullPath(item.Source);
                    if (!rootPaths.Any(r => full.StartsWith(r, StringComparison.OrdinalIgnoreCase))) throw new CopyException(L("{0} não está no cartão", name));
                    if (!File.Exists(item.Copy)) throw new CopyException(L("a cópia {0} não está mais no disco", System.IO.Path.GetFileName(item.Copy)));
                    var original = Hash(item.Source, buffer, n => { done += n; Tick(i, name); });
                    var copy = Hash(item.Copy, buffer, n => { done += n; Tick(i, name); });
                    if (original != copy) throw new CopyException(L("a cópia de {0} não bate com o original", System.IO.Path.GetFileName(item.Copy)));
                    File.Delete(item.Source);
                    report.Deleted++;
                    report.Bytes += item.Size;
                }
                catch (CancelledException) { report.Cancelled = true; break; }
                catch (Exception e) { report.Problems.Add(L("{0}: {1}. Ficou no cartão.", name, Message(e))); }
            }
        }
        finally { buffer.Dispose(); }
        // O que sobrou nos cartões (JPG, proxies, arquivos da câmera…)
        foreach (var r in roots)
        {
            try { report.Leftovers += Directory.EnumerateFiles(r, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }).Count(f => !System.IO.Path.GetFileName(f).StartsWith('.')); }
            catch { }
        }
        onProgress(new Progress(done, total, items.Count, items.Count, "", L("Pronto")));
        return report;
    }

    public static string Hex(ulong v) => v.ToString("x16");

    static string Message(Exception e) => e.Message;

    static void TryDelete(string p) { try { File.Delete(p); } catch { } }

    // Windows: FILE_FLAG_NO_BUFFERING faz a releitura vir do disco, não da memória.
    const FileOptions NoBuffering = (FileOptions)0x20000000;

    static Microsoft.Win32.SafeHandles.SafeFileHandle OpenRead(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            try { return File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.Read, NoBuffering | FileOptions.SequentialScan); }
            catch { /* disco que não aceita: lê com cache */ }
        }
        return File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.Read, FileOptions.SequentialScan);
    }

    ulong Copy(string src, List<string> dests, AlignedBuffer buffer, Action<long> progress)
    {
        using var input = OpenRead(src);
        var outs = new List<FileStream>();
        try
        {
            foreach (var d in dests)
            {
                var fs = new FileStream(d, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.WriteThrough);
                if (OperatingSystem.IsWindows()) File.SetAttributes(d, FileAttributes.Hidden);
                outs.Add(fs);
            }
            var hasher = new XxHash64();
            long offset = 0;
            while (true)
            {
                if (cancelled) throw new CancelledException();
                var n = RandomAccess.Read(input, buffer.Span, offset);
                if (n == 0) break;
                var data = buffer.Span[..n];
                hasher.Append(data);
                foreach (var o in outs) o.Write(data);
                offset += n;
                progress(n);
                if (n < buffer.Length) break;   // fim do arquivo
            }
            foreach (var o in outs) o.Flush(flushToDisk: true);
            return hasher.GetCurrentHashAsUInt64();
        }
        finally { foreach (var o in outs) o.Dispose(); }
    }

    ulong Hash(string path, AlignedBuffer buffer, Action<long> progress)
    {
        using var input = OpenRead(path);
        var hasher = new XxHash64();
        long offset = 0;
        while (true)
        {
            if (cancelled) throw new CancelledException();
            var n = RandomAccess.Read(input, buffer.Span, offset);
            if (n == 0) break;
            hasher.Append(buffer.Span[..n]);
            offset += n;
            progress(n);
            if (n < buffer.Length) break;
        }
        return hasher.GetCurrentHashAsUInt64();
    }
}

/// <summary>Memória alinhada a 4 KB (exigida pela leitura sem cache do Windows).</summary>
public sealed unsafe class AlignedBuffer(int length) : IDisposable
{
    readonly void* ptr = NativeMemory.AlignedAlloc((nuint)length, 4096);
    public int Length => length;
    public Span<byte> Span => new(ptr, length);
    public void Dispose() => NativeMemory.AlignedFree(ptr);
}
