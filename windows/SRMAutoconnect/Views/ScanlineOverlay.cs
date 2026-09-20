using System.Windows;
using System.Windows.Media;
using SRMAutoconnect.Helpers;

namespace SRMAutoconnect.Views;

public sealed class ScanlineOverlay : FrameworkElement
{
    private static readonly Pen ScanlinePen = new(
        new SolidColorBrush(Color.FromArgb(0x09, Theme.GreenColor.R, Theme.GreenColor.G, Theme.GreenColor.B)),
        1);

    public ScanlineOverlay()
    {
        IsHitTestVisible = false;
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);

        for (var y = 0.0; y < ActualHeight; y += 3.0)
        {
            drawingContext.DrawLine(ScanlinePen, new Point(0, y), new Point(ActualWidth, y));
        }
    }
}
