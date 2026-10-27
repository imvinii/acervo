// Relatórios de cada importação: PDF para guardar/enviar ao cliente e ASC MHL,
// a lista de checksums no padrão do mercado (mesmo formato do app do Mac).

using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using PdfSharp.Drawing;
using PdfSharp.Fonts;
using PdfSharp.Pdf;
using static Acervo.Loc;

namespace Acervo;

public static class Reports
{
    /// <summary>Escreve o PDF e o ASC MHL conforme os Ajustes. Devolve avisos (nunca interrompe a importação).</summary>
    public static List<string> Write(ImportReport r, Config cfg)
    {
        var warnings = new List<string>();
        if (r.Entries.Count == 0 && r.Plan.Duplicates.Count == 0 && r.Failures.Count == 0) return warnings;
        var stamp = r.Start.ToString("yyyy-MM-dd HH'h'mm");
        if (cfg.Mhl && r.Entries.Count > 0)
        {
            for (var i = 0; i < r.Plan.Roots.Count; i++)
            {
                var root = r.Plan.Roots[i];
                if (!Directory.Exists(root)) continue;
                try { Mhl.AddGeneration(root, r.Entries, i, r.End); }
                catch (Exception e) { warnings.Add(L("ASC MHL em {0}: {1}", Volume.NameOf(root), e.Message)); }
            }
        }
        if (cfg.ReportPDF)
        {
            var name = Safe($"{stamp} - {r.Plan.Capture}.pdf");
            var targets = cfg.ReportFolder.Length == 0
                ? r.Plan.Roots.Where(Directory.Exists).Select(root => Path.Combine(root, L("Relatórios"), name)).ToList()
                : [Path.Combine(cfg.ReportFolder, name)];
            foreach (var t in targets)
            {
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(t)!);
                    PdfReport.Write(r, t);
                }
                catch (Exception e) { warnings.Add(L("Relatório em {0}: {1}", Path.GetDirectoryName(t)!, e.Message)); }
            }
        }
        return warnings;
    }

    static string Safe(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '-');
        return name;
    }

    /// <summary>Discos diferentes que têm uma cópia conferida de tudo (para o aviso "seguro para formatar").</summary>
    public static List<string> VerifiedDisks(ImportReport r)
    {
        if (r.Failures.Count > 0 || r.Cancelled) return [];
        return r.Plan.Roots.Select(Volume.RootOf).Distinct().Select(Volume.NameOf).ToList();
    }
}

// MARK: ASC MHL

/// <summary>Histórico ASC MHL v2.0: cada importação acrescenta uma "geração" em &lt;captação&gt;/ascmhl/
/// com o xxHash64 dos arquivos que entraram; o ascmhl_chain.xml encadeia as gerações.</summary>
public static class Mhl
{
    public static void AddGeneration(string root, List<FileEntry> entries, int index, DateTime date)
    {
        var dir = Path.Combine(root, "ascmhl");
        Directory.CreateDirectory(dir);
        var seq = Directory.EnumerateFiles(dir, "*.mhl").Select(Path.GetFileName)
            .Select(n => int.TryParse(n![..Math.Min(4, n!.Length)], out var i) ? i : 0).DefaultIfEmpty(0).Max() + 1;
        var rootName = Path.GetFileName(root.TrimEnd('/', '\\'));
        var fileName = $"{seq:0000}_{rootName}_{date.ToUniversalTime():yyyy-MM-dd_HHmmss}Z.mhl";

        var rootFull = Path.GetFullPath(root).TrimEnd('/', '\\') + Path.DirectorySeparatorChar;
        var hashes = new StringBuilder();
        foreach (var e in entries.Where(e => e.Targets.Count > index))
        {
            var full = Path.GetFullPath(e.Targets[index]);
            if (!full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase)) continue;
            var rel = full[rootFull.Length..].Replace('\\', '/');
            hashes.Append($"""
                    <hash>
                      <path size="{e.Size}" lastmodificationdate="{Iso(e.Modified)}">{Xml(rel)}</path>
                      <xxh64 action="original" hashdate="{Iso(e.HashDate)}">{e.Hash}</xxh64>
                    </hash>

                """);
        }
        var version = typeof(Mhl).Assembly.GetName().Version?.ToString(2) ?? "2.0";
        var manifest = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
              <creatorinfo>
                <creationdate>{Iso(date)}</creationdate>
                <hostname>{Xml(Environment.MachineName)}</hostname>
                <tool version="{version}">Acervo</tool>
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
            {hashes}  </hashes>
            </hashlist>

            """;
        var data = new UTF8Encoding(false).GetBytes(manifest.Replace("\r\n", "\n"));
        using (var fs = new FileStream(Path.Combine(dir, fileName), FileMode.CreateNew)) fs.Write(data);

        // Corrente: acrescenta esta geração
        var chainPath = Path.Combine(dir, "ascmhl_chain.xml");
        var chain = File.Exists(chainPath) ? File.ReadAllText(chainPath) :
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ascmhldirectory xmlns=\"urn:ASC:MHL:DIRECTORY:v2.0\">\n</ascmhldirectory>\n";
        var end = chain.IndexOf("</ascmhldirectory>", StringComparison.Ordinal);
        if (end < 0) throw new InvalidDataException("ascmhl_chain.xml");
        var entry = $"  <hashlist sequencenr=\"{seq}\">\n    <path>{Xml(fileName)}</path>\n    <c4>{C4(data)}</c4>\n  </hashlist>\n";
        File.WriteAllText(chainPath, chain.Insert(end, entry).Replace("\r\n", "\n"), new UTF8Encoding(false));
    }

    static string Iso(DateTime d) => d.ToString("yyyy-MM-dd'T'HH:mm:sszzz", System.Globalization.CultureInfo.InvariantCulture);

    static string Xml(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    /// <summary>Impressão C4 (SMPTE ST 2114): SHA-512 em base58, com o prefixo "c4", 90 caracteres.</summary>
    public static string C4(byte[] data)
    {
        const string alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        var num = new BigInteger(SHA512.HashData(data), isUnsigned: true, isBigEndian: true);
        var sb = new StringBuilder();
        while (num > 0) { sb.Insert(0, alphabet[(int)(num % 58)]); num /= 58; }
        return "c4" + sb.ToString().PadLeft(88, '1');
    }
}

// MARK: PDF

public static class PdfReport
{
    public static void Write(ImportReport r, string path)
    {
        Fonts.Install();
        var doc = new PdfDocument();
        doc.Info.Title = $"{L("Relatório de importação")} - {r.Plan.Capture}";
        doc.Info.Creator = "Acervo";
        var w = new PdfWriter(doc);
        var bold = new XFont(Fonts.Sans, 10, XFontStyleEx.Bold);
        var body = new XFont(Fonts.Sans, 10);
        var small = new XFont(Fonts.Sans, 8);
        var mono = new XFont(Fonts.Mono, 7.5);
        var gray = XColor.FromArgb(102, 102, 102);
        var accent = XColor.FromArgb(232, 92, 51);
        var ok = r.Failures.Count == 0 && !r.Cancelled;
        string D(DateTime d) => d.ToString("f", Lang.Culture);

        w.Text(L("Relatório de importação"), new XFont(Fonts.Sans, 20, XFontStyleEx.Bold));
        w.Text($"Acervo · {D(r.End)}", body, gray);
        w.Space(10);
        w.Text(r.Plan.Capture, new XFont(Fonts.Sans, 14, XFontStyleEx.Bold), accent);
        w.Space(8);

        var disks = Reports.VerifiedDisks(r);
        string status;
        XColor color;
        if (!ok) { status = r.Cancelled ? L("Importação cancelada") : L("Terminou com erros"); color = XColor.FromArgb(200, 30, 30); }
        else if (disks.Count >= 2) { status = L("Seguro para formatar: cada arquivo está conferido em {0} discos ({1}).", disks.Count, string.Join(", ", disks)); color = XColor.FromArgb(26, 128, 51); }
        else { status = L("Concluído com 1 cópia ({0}). Para formatar com segurança, tenha uma segunda cópia em outro disco.", disks.FirstOrDefault() ?? ""); color = XColor.FromArgb(217, 115, 0); }
        w.Text(status, bold, color);
        w.Space(8);
        foreach (var (k, v) in new[]
        {
            (L("Início"), D(r.Start)),
            (L("Fim"), D(r.End)),
            (L("Duração"), Fmt.Duration(r.Seconds)),
            (L("Copiados e conferidos"), $"{Fmt.Files(r.Verified)} · {Fmt.Bytes(r.Bytes)}"),
            (L("Já importados antes (não copiados)"), Fmt.Files(r.Skipped)),
            (L("Com problema"), Fmt.Files(r.Failures.Count)),
            (L("Conferência"), L("xxHash64; cada cópia é relida do disco e comparada com o original")),
        }) w.Pair(k, v, body, gray);
        w.Space(10);

        w.Heading(L("Cartões"), bold);
        foreach (var c in r.Entries.Select(e => e.CardName).Concat(r.Plan.Duplicates.Select(d => d.Source.CardName)).Distinct().Order())
        {
            var e = r.Entries.Where(x => x.CardName == c).ToList();
            w.Pair(c, $"{Fmt.Files(e.Count)} · {Fmt.Bytes(e.Sum(x => x.Size))}", body, XColors.Black);
        }
        w.Space(10);

        w.Heading(L("Destinos"), bold);
        for (var i = 0; i < r.Plan.Roots.Count; i++)
            w.Pair(i == 0 ? L("Disco principal") : L("Redundância"), $"{Volume.NameOf(r.Plan.Roots[i])} · {r.Plan.Roots[i]}", body, gray);
        w.Space(10);

        w.Heading(L("Arquivos copiados"), bold);
        double[] widths = [0.40, 0.24, 0.10, 0.26];
        w.Row([L("Nome final"), L("Original no cartão"), L("Tamanho"), "xxHash64"], widths, new XFont(Fonts.Sans, 7.5, XFontStyleEx.Bold), gray);
        var root = r.Plan.Roots.FirstOrDefault() is { } rt ? Path.GetFullPath(rt).TrimEnd('/', '\\') + Path.DirectorySeparatorChar : "";
        foreach (var e in r.Entries)
        {
            // Caminho dentro da captação (mostra a subpasta, ex.: Vídeos/CAM A/…)
            var full = Path.GetFullPath(e.Targets[0]);
            var rel = root.Length > 0 && full.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? full[root.Length..].Replace('\\', '/') : Path.GetFileName(full);
            w.Row([rel, $"{e.CardName}/{Path.GetFileName(e.Source)}", Fmt.Bytes(e.Size), e.Hash], widths, mono, XColors.Black);
        }
        if (r.Entries.Count == 0) w.Text("—", body, gray);

        if (r.Plan.Duplicates.Count > 0)
        {
            w.Space(10);
            w.Heading(L("Já estavam no disco (não copiados de novo)"), bold);
            foreach (var d in r.Plan.Duplicates)
                w.Row([$"{d.Source.CardName}/{Path.GetFileName(d.Source.Path)}", $"= {d.Capture}/{Path.GetFileName(d.Existing)}"], [0.35, 0.65], mono, XColors.Black);
        }
        if (r.Failures.Count > 0)
        {
            w.Space(10);
            w.Heading(L("Com problema"), bold, XColor.FromArgb(200, 30, 30));
            foreach (var f in r.Failures) w.Text(f, mono);
        }
        w.Space(14);
        w.Text(L("Gerado pelo {0}. O registro ASC MHL (pasta ascmhl, dentro da captação) guarda os mesmos checksums no padrão do mercado.", "Acervo"), small, gray);
        w.Finish();
        doc.Save(path);
    }
}

/// <summary>Desenho simples de PDF em várias páginas (A4), com texto que quebra linha e tabela.</summary>
class PdfWriter
{
    readonly PdfDocument doc;
    PdfPage page = null!;
    XGraphics gfx = null!;
    const double Margin = 42;
    double y;
    int pageNumber;

    public PdfWriter(PdfDocument doc) { this.doc = doc; NewPage(); }

    double Width => page.Width.Point - Margin * 2;

    void NewPage()
    {
        if (gfx != null) { Footer(); gfx.Dispose(); }
        page = doc.AddPage();
        page.Size = PdfSharp.PageSize.A4;
        gfx = XGraphics.FromPdfPage(page);
        pageNumber++;
        y = Margin;
    }

    void Footer() => gfx.DrawString($"Acervo · {pageNumber}", new XFont(Fonts.Sans, 7), XBrushes.Gray, new XPoint(Margin, page.Height.Point - Margin / 2));

    void Ensure(double h) { if (y + h > page.Height.Point - Margin - 10) NewPage(); }

    public void Space(double h) => y += h;

    List<string> Wrap(string text, XFont font, double width)
    {
        var lines = new List<string>();
        foreach (var para in text.Split('\n'))
        {
            var line = "";
            foreach (var word0 in para.Split(' '))
            {
                var word = word0;
                // Palavra maior que a linha (ex.: um caminho de pasta): quebra no meio
                while (gfx.MeasureString(word, font).Width > width && word.Length > 1)
                {
                    if (line.Length > 0) { lines.Add(line); line = ""; }
                    var cut = word.Length - 1;
                    while (cut > 1 && gfx.MeasureString(word[..cut], font).Width > width) cut--;
                    lines.Add(word[..cut]);
                    word = word[cut..];
                }
                var test = line.Length == 0 ? word : line + " " + word;
                if (gfx.MeasureString(test, font).Width <= width || line.Length == 0) line = test;
                else { lines.Add(line); line = word; }
            }
            lines.Add(line);
        }
        return lines;
    }

    public void Text(string s, XFont font, XColor? color = null, double x = 0, double? w = null)
    {
        var brush = new XSolidBrush(color ?? XColors.Black);
        var lh = font.GetHeight() * 1.15;
        foreach (var line in Wrap(s, font, w ?? Width - x))
        {
            Ensure(lh);
            gfx.DrawString(line, font, brush, new XRect(Margin + x, y, w ?? Width - x, lh), XStringFormats.TopLeft);
            y += lh;
        }
        y += 2;
    }

    public void Heading(string s, XFont font, XColor? color = null)
    {
        Ensure(30);
        Text(s, font, color);
        gfx.DrawLine(new XPen(XColor.FromArgb(217, 217, 217), 0.5), Margin, y, page.Width.Point - Margin, y);
        y += 4;
    }

    public void Pair(string k, string v, XFont font, XColor keyColor)
    {
        Ensure(font.GetHeight() * 1.2);
        var top = y;
        var startPage = pageNumber;
        Text(k, font, keyColor, 0, 170);
        var afterKey = y;
        if (pageNumber != startPage) return;
        y = top;
        Text(v, font, null, 175);
        y = Math.Max(y, afterKey);
    }

    /// <summary>Uma linha da tabela; cada célula é cortada com "…" no meio se não couber.</summary>
    public void Row(string[] cells, double[] widths, XFont font, XColor color)
    {
        var h = font.GetHeight() + 3;
        Ensure(h);
        var x = Margin;
        var brush = new XSolidBrush(color);
        for (var i = 0; i < cells.Length; i++)
        {
            var w = Width * widths[i] - 6;
            gfx.DrawString(Fit(cells[i], font, w), font, brush, new XRect(x, y, w, h), XStringFormats.TopLeft);
            x += Width * widths[i];
        }
        y += h;
    }

    string Fit(string s, XFont font, double w)
    {
        if (gfx.MeasureString(s, font).Width <= w) return s;
        for (var keep = s.Length - 1; keep > 4; keep--)
        {
            var head = s[..(keep / 2)];
            var tail = s[^(keep - keep / 2)..];
            var t = head + "…" + tail;
            if (gfx.MeasureString(t, font).Width <= w) return t;
        }
        return s[..Math.Min(4, s.Length)] + "…";
    }

    public void Finish() { Footer(); gfx.Dispose(); }
}

/// <summary>Fontes para o PDF: Arial e uma monoespaçada, do Windows (ou do Mac, nos testes).</summary>
static class Fonts
{
    public const string Sans = "Acervo Sans";
    public const string Mono = "Acervo Mono";
    static bool installed;

    static readonly Dictionary<string, string[]> Files = new()
    {
        ["sans"] = [@"C:\Windows\Fonts\arial.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"],
        ["sans-bold"] = [@"C:\Windows\Fonts\arialbd.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"],
        ["mono"] = [@"C:\Windows\Fonts\consola.ttf", @"C:\Windows\Fonts\cour.ttf", "/System/Library/Fonts/Supplemental/Courier New.ttf"],
    };

    public static void Install()
    {
        if (installed) return;
        installed = true;
        GlobalFontSettings.FontResolver = new Resolver();
    }

    class Resolver : IFontResolver
    {
        public FontResolverInfo? ResolveTypeface(string familyName, bool isBold, bool isItalic) =>
            familyName == Mono ? new FontResolverInfo("mono") : new FontResolverInfo(isBold ? "sans-bold" : "sans");

        public byte[]? GetFont(string faceName) =>
            Files.TryGetValue(faceName, out var paths) && paths.FirstOrDefault(File.Exists) is { } p ? File.ReadAllBytes(p) : null;
    }
}
