using System.Windows;
using System.Windows.Media;

namespace SRMAutoconnect.Helpers;

public static class Theme
{
    public static readonly Color BackgroundColor = Colors.Black;
    public static readonly Color GreenColor = Color.FromRgb(0x33, 0xFF, 0x59);
    public static readonly Color AmberColor = Color.FromRgb(0xFF, 0xBF, 0x26);
    public static readonly Color DimGreenColor = Color.FromArgb(0x80, 0x33, 0xFF, 0x59);

    public static SolidColorBrush BackgroundBrush { get; } = new(BackgroundColor);
    public static SolidColorBrush GreenBrush { get; } = new(GreenColor);
    public static SolidColorBrush AmberBrush { get; } = new(AmberColor);
    public static SolidColorBrush DimGreenBrush { get; } = new(DimGreenColor);
    public static SolidColorBrush PanelBorderBrush { get; } = new(Color.FromArgb(0x99, 0x33, 0xFF, 0x59));

    public static FontFamily MonoFont { get; } = new("Consolas");
    public static CornerRadius PanelCornerRadius { get; } = new(8);
}
