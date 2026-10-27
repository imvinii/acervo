// Formatação de tamanhos, datas e durações (como no app do Mac).

using static Acervo.Loc;

namespace Acervo;

public static class Fmt
{
    /// <summary>Tamanho em unidades de 1000, como o Finder e o app do Mac ("3,2 GB").</summary>
    public static string Bytes(long b)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double v = b;
        var i = 0;
        while (v >= 1000 && i < units.Length - 1) { v /= 1000; i++; }
        if (i == 0) return $"{b} {(b == 1 ? "byte" : "bytes")}";
        return (v >= 100 || i == 1 ? v.ToString("0", Lang.Culture) : v.ToString("0.#", Lang.Culture)) + " " + units[i];
    }

    public static string Files(int n) => n == 1 ? L("1 arquivo") : L("{0} arquivos", n);

    public static string Duration(double s)
    {
        if (double.IsNaN(s) || double.IsInfinity(s) || s <= 0) return "—";
        int m = (int)s / 60, sec = (int)s % 60;
        if (m >= 60) return $"{m / 60} h {m % 60} min";
        return m > 0 ? $"{m} min {sec} s" : $"{sec} s";
    }

    public static string Day(DateTime d) => d.ToString("d MMM yyyy", Lang.Culture);

    /// <summary>"OUT 2026" (cabe na coluna da data)</summary>
    public static string MonthYear(DateTime d) => d.ToString("MMM yyyy", Lang.Culture).Replace(".", "").ToUpperInvariant();
}
