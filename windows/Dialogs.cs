// Janelas pequenas: aviso, confirmação e nova captação.

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using static Acervo.Loc;
using static Acervo.Ui;

namespace Acervo;

public static class Dialogs
{
    static Window Make(string title, Control content, double width = 460) => new()
    {
        Title = title,
        Width = width,
        SizeToContent = SizeToContent.Height,
        CanResize = false,
        WindowStartupLocation = WindowStartupLocation.CenterOwner,
        ShowInTaskbar = false,
        Content = new Border { Padding = new Thickness(24), Child = content },
    };

    public static async Task Alert(Window owner, string title, string message)
    {
        Window? w = null;
        var ok = Btn("OK", () => w!.Close(), primary: true).Also(b => b.HorizontalAlignment = HorizontalAlignment.Right);
        w = Make(title, Col(16, T(title, 16, FontWeight.Bold, wrap: true), T(message, wrap: true), ok));
        await w.ShowDialog(owner);
    }

    public static async Task<bool> Confirm(Window owner, string title, string message, string okText, bool destructive = false, string? cancel = null)
    {
        Window? w = null;
        var okBtn = Btn(okText, () => w!.Close(true), primary: !destructive);
        if (destructive) okBtn.Foreground = Red;
        var buttons = Row(8, Btn(cancel ?? L("Cancelar"), () => w!.Close(false)), okBtn);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        w = Make(title, Col(16, T(title, 16, FontWeight.Bold, wrap: true), T(message, wrap: true), buttons), 500);
        return await w.ShowDialog<bool?>(owner) == true;
    }
}

/// <summary>Nova captação: nome + data da gravação; mostra a pasta que vai ser criada.</summary>
public class NewCaptureWindow : Window
{
    public NewCaptureWindow(Config cfg, List<Capture> existing, DateTime date)
    {
        Title = L("Nova captação");
        Width = 460;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var name = new TextBox { Watermark = L("ex.: CASAMENTO ANA E JOÃO") };
        var picker = new CalendarDatePicker { SelectedDate = date, HorizontalAlignment = HorizontalAlignment.Stretch };
        var preview = T("", 14, FontWeight.SemiBold, wrap: true);
        var exists = Caption("", Orange);
        var create = Btn(L("Criar pasta"), () => { }, primary: true);
        string Folder() => Capture.FolderName(cfg, picker.SelectedDate ?? DateTime.Today, (name.Text ?? "").Trim());
        bool Invalid()
        {
            var t = (name.Text ?? "").Trim();
            return t.Length == 0 || t.IndexOfAny(['/', '\\', ':', '*', '?', '"', '<', '>', '|']) >= 0 || Folder().Length == 0;
        }
        void Update()
        {
            var t = (name.Text ?? "").Trim();
            preview.Text = "📁 " + Capture.FolderName(cfg, picker.SelectedDate ?? DateTime.Today, t.Length == 0 ? "…" : t);
            var already = existing.Any(c => c.Name == Folder());
            exists.Text = already ? L("Essa pasta já existe; ela só vai ser selecionada.") : "";
            create.Content = already ? L("Selecionar") : L("Criar pasta");
            create.IsEnabled = !Invalid();
        }
        void Submit() { if (!Invalid()) Close(Folder()); }
        name.TextChanged += (_, _) => Update();
        picker.SelectedDateChanged += (_, _) => Update();
        name.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) Submit(); };
        create.Click += (_, _) => Submit();

        var buttons = Row(8, Btn(L("Cancelar"), () => Close(null)), create);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        Content = new Border
        {
            Padding = new Thickness(24),
            Child = Col(14,
                T(L("Nova captação"), 20, FontWeight.Bold),
                Col(4, T(L("Nome")), name),
                Col(4, T(L("Data da gravação")), picker),
                Col(4, Label(L("VAI CRIAR")), preview,
                    cfg.CaptureFolders.Count > 0 ? Caption(L("com {0}", string.Join(", ", cfg.CaptureFolders))) : new Panel()),
                exists,
                buttons),
        };
        Update();
        Opened += (_, _) => name.Focus();
    }
}
