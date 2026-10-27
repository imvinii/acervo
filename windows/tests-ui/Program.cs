// Roda o app sem janela visível, simula o uso e salva fotos de cada etapa.
using System.Reflection;
using Acervo;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media;
using Avalonia.Threading;

var outDir = args[0];
MainWindow.StartupFolders.AddRange(args.Skip(1));
var session = HeadlessUnitTestSession.StartNew(typeof(TestEntry));
await await session.Dispatch((Func<Task>)(async () =>
{
    Console.Error.WriteLine("criando a janela");
    var w = new MainWindow();
    w.Show();
    Console.Error.WriteLine("janela aberta");
    async Task Wait(Func<bool> done, int ms = 20000)
    {
        for (var t = 0; t < ms && !done(); t += 50) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(50); }
        await Task.CompletedTask;
        Dispatcher.UIThread.RunJobs();
    }
    T Get<T>(string field) => (T)typeof(MainWindow).GetField(field, BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(w)!;
    void Shot(Window win, string name)
    {
        Dispatcher.UIThread.RunJobs();
        win.CaptureRenderedFrame()?.Save(Path.Combine(outDir, name));
        Console.WriteLine("foto: " + name);
    }

    await Wait(() => Get<List<SourceFile>>("files").Count > 0);
    Console.WriteLine($"arquivos lidos dos 2 cartões: {Get<List<SourceFile>>("files").Count}");
    // Escolhe a captação na lista (como um clique)
    var list = Get<ListBox>("captureList");
    list.SelectedItem = list.Items.OfType<ListBoxItem>().First(i => ((Capture)i.Tag!).Name.EndsWith("TESTE UI"));
    await Wait(() => Get<ImportPlan?>("plan") != null && !Get<bool>("planning"));
    Shot(w, "1-principal.png");
    var plan = Get<ImportPlan?>("plan")!;
    Console.WriteLine($"plano: {plan.Jobs.Count} para copiar, {plan.Duplicates.Count} já importados");

    // Clica em Importar
    typeof(MainWindow).GetMethod("Start", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(w, null);
    await Wait(() => Get<ImportReport?>("report") != null);
    Shot(w, "2-resultado.png");
    var r = Get<ImportReport?>("report")!;
    Console.WriteLine($"resultado: {r.Verified} copiados e conferidos, falhas={r.Failures.Count}, avisos={string.Join("; ", r.Warnings)}");

    // Tela de Ajustes (primeira abertura)
    var s = new SetupWindow(Config.Load()!, true);
    s.Show();
    Shot(s, "3-ajustes.png");
    var sc = (ScrollViewer)typeof(SetupWindow).GetField("scroll", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(s)!;
    for (var i = 1; i <= 3; i++) { sc.Offset = new Vector(0, i * 650); Shot(s, $"3-ajustes-{i}.png"); }
}), CancellationToken.None);

class TestEntry
{
    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UseSkia().WithInterFont()
            .With(new FontManagerOptions { DefaultFamilyName = "avares://Avalonia.Fonts.Inter/Assets#Inter" })
            .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
}
