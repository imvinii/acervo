// Idiomas: o app segue o idioma do Windows. Português, inglês e espanhol;
// qualquer outro idioma usa o inglês. Os textos são escritos em português no código:
// L("…") procura a tradução na tabela. {0}, {1}… são trocados pelos valores passados.

using System.Globalization;

namespace Acervo;

public enum LangCode { Pt, En, Es }

public static class Lang
{
    public static readonly LangCode Current = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName switch
    {
        "pt" => LangCode.Pt,
        "es" => LangCode.Es,
        _ => LangCode.En,
    };

    public static CultureInfo Culture => Current switch
    {
        LangCode.Pt => new CultureInfo("pt-BR"),
        LangCode.Es => new CultureInfo("es-ES"),
        _ => new CultureInfo("en-US"),
    };

    public static string Pick(string pt, string en, string es) => Current switch { LangCode.Pt => pt, LangCode.En => en, _ => es };
}

public static class Loc
{
    public static string L(string key, params object[] args)
    {
        var s = key;
        if (Lang.Current != LangCode.Pt)
        {
            if (Translations.Table.TryGetValue(key, out var t) || Translations.WindowsOnly.TryGetValue(key, out t))
                s = Lang.Current == LangCode.En ? t.En : t.Es;
        }
        for (var i = 0; i < args.Length; i++) s = s.Replace("{" + i + "}", Convert.ToString(args[i], Lang.Culture));
        // Atalhos do Mac nos textos compartilhados
        return s.Replace("⌘,", "Ctrl+,");
    }
}

public static partial class Translations
{
    /// <summary>Textos que só existem na versão Windows.</summary>
    public static readonly Dictionary<string, (string En, string Es)> WindowsOnly = new()
    {
        ["Mostrar no Explorador"] = ("Show in File Explorer", "Mostrar en el Explorador"),
        ["Escolher pasta…"] = ("Choose folder…", "Elegir carpeta…"),
        ["Escolher"] = ("Choose", "Elegir"),
        ["Hoje"] = ("Today", "Hoy"),
        ["Versão de testes (beta)"] = ("Test version (beta)", "Versión de prueba (beta)"),
        ["Essa ação não pode ser desfeita."] = ("This can’t be undone.", "No se puede deshacer."),
        ["Ícone"] = ("Icon", "Icono"),
        ["Pasta para os relatórios"] = ("Folder for reports", "Carpeta para los informes"),
        ["Pasta do disco principal ou da redundância"] = ("Folder on the main or redundancy drive", "Carpeta del disco principal o de redundancia"),
        ["Escolha a pasta com os arquivos da gravação"] = ("Choose the folder with the recording files", "Elige la carpeta con los archivos de la grabación"),
    };
}
