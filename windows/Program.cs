// Ponto de entrada do app no Windows.
// --pasta <caminho> abre já com essa pasta na lista de cartões (útil para testar sem leitor).

using Avalonia;
using Avalonia.Media;

namespace Acervo;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        for (var i = 0; i + 1 < args.Length; i++)
            if (args[i] == "--pasta") MainWindow.StartupFolders.Add(args[i + 1]);
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UsePlatformDetect().WithInterFont()
            .With(new FontManagerOptions { DefaultFamilyName = "avares://Avalonia.Fonts.Inter/Assets#Inter" })
            .LogToTrace();
}
