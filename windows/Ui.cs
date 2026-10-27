// Início do app e peças de interface usadas nas janelas (montadas em código, sem XAML).

using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace Acervo;

public class App : Application
{
    public override void Initialize()
    {
        var theme = new FluentTheme();
        theme.Palettes[ThemeVariant.Light] = new ColorPaletteResources { Accent = Ui.Accent };
        theme.Palettes[ThemeVariant.Dark] = new ColorPaletteResources { Accent = Ui.Accent };
        Styles.Add(theme);
        RequestedThemeVariant = ThemeVariant.Default;   // segue o tema claro/escuro do Windows
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime d) d.MainWindow = new MainWindow();
        base.OnFrameworkInitializationCompleted();
    }
}

public static class Ui
{
    public static readonly Color Accent = Color.Parse("#EE6A2C");
    public static readonly IBrush AccentBrush = new SolidColorBrush(Accent);
    public static readonly IBrush Subtle = new SolidColorBrush(Color.FromArgb(20, 128, 128, 128));
    public static readonly IBrush Line = new SolidColorBrush(Color.FromArgb(40, 128, 128, 128));
    public static readonly IBrush Green = new SolidColorBrush(Color.Parse("#2E9E4F"));
    public static readonly IBrush Orange = new SolidColorBrush(Color.Parse("#E08A00"));
    public static readonly IBrush Red = new SolidColorBrush(Color.Parse("#D93B30"));

    public static TextBlock T(string s, double size = 13, FontWeight weight = FontWeight.Normal, double opacity = 1, bool wrap = false, IBrush? color = null)
    {
        var t = new TextBlock { Text = s, FontSize = size, FontWeight = weight, Opacity = opacity, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap };
        if (!wrap) t.TextTrimming = TextTrimming.CharacterEllipsis;
        if (color != null) t.Foreground = color;
        return t;
    }

    public static TextBlock Caption(string s, IBrush? color = null) => T(s, 11.5, opacity: color == null ? 0.65 : 1, wrap: true, color: color);
    public static TextBlock Label(string s) => T(s, 11, FontWeight.SemiBold, 0.6);

    /// <summary>Título de seção com subtítulo explicando para que serve.</summary>
    public static Control Header(string title, string subtitle) => new StackPanel
    {
        Spacing = 3,
        Margin = new Thickness(0, 18, 0, 6),
        Children = { T(title, 15, FontWeight.SemiBold), Caption(subtitle) },
    };

    public static Border Box(Control child, double padding = 12) => new()
    {
        Background = Subtle,
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(padding),
        Child = child,
    };

    public static Button Btn(string text, Action click, bool primary = false)
    {
        var b = new Button { Content = text };
        if (primary) b.Classes.Add("accent");
        b.Click += (_, _) => click();
        return b;
    }

    public static Button Link(string text, Action click)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = text, Foreground = AccentBrush },
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0, 4),
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
        };
        b.Click += (_, _) => click();
        return b;
    }

    public static Button IconBtn(string glyph, Action click, string tip, IBrush? color = null)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = glyph, FontSize = 15, Foreground = color },
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => click();
        return b;
    }

    public static StackPanel Row(double spacing, params Control[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var c in children) p.Children.Add(c);
        return p;
    }

    public static StackPanel Col(double spacing, params Control[] children)
    {
        var p = new StackPanel { Spacing = spacing };
        foreach (var c in children) p.Children.Add(c);
        return p;
    }

    /// <summary>Número da etapa (1, 2, 3) com o título ao lado.</summary>
    public static Control Step(int n, string title) => Row(10,
        new Border
        {
            Width = 24, Height = 24, CornerRadius = new CornerRadius(12), Background = AccentBrush,
            Child = new TextBlock { Text = n.ToString(), Foreground = Brushes.White, FontWeight = FontWeight.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        },
        T(title, 17, FontWeight.SemiBold));

    /// <summary>Menu que abre ao clicar num botão (lista de discos, modelos prontos, ícones…).</summary>
    public static Button Menu(object content, IEnumerable<(string Text, Action Click)> items, bool flat = false)
    {
        var b = new Button { Content = content };
        if (flat) { b.Background = Brushes.Transparent; b.BorderThickness = new Thickness(0); }
        var flyout = new MenuFlyout();
        foreach (var (text, click) in items)
        {
            if (text == "-") { flyout.Items.Add(new Separator()); continue; }
            var mi = new MenuItem { Header = text };
            mi.Click += (_, _) => click();
            flyout.Items.Add(mi);
        }
        b.Flyout = flyout;
        return b;
    }

    public static Control Example(string text) => Row(4, T(Loc.L("Exemplo:"), 11.5, opacity: 0.45), T(text, 11.5, opacity: 0.7));
}
