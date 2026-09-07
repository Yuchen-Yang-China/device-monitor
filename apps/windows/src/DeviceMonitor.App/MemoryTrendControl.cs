using System.Windows;
using System.Windows.Media;
using DeviceMonitor.Core;
using MediaColor = System.Windows.Media.Color;
using MediaPen = System.Windows.Media.Pen;

namespace DeviceMonitor.App;

public sealed class MemoryTrendControl : FrameworkElement
{
    public IReadOnlyList<TrendPoint> Points { get; set; } = [];
    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext); var rect = new Rect(0, 0, ActualWidth, ActualHeight);
        drawingContext.DrawRoundedRectangle(new SolidColorBrush(MediaColor.FromRgb(247, 249, 252)), new MediaPen(new SolidColorBrush(MediaColor.FromRgb(228, 232, 239)), 1), rect, 10, 10);
        drawingContext.DrawLine(new MediaPen(new SolidColorBrush(MediaColor.FromRgb(228, 232, 239)), 1), new(0, ActualHeight * .5), new(ActualWidth, ActualHeight * .5));
        if (Points.Count < 2) return;
        var maxTime = Points[^1].SampledAt; var minTime = maxTime - TimeSpan.FromMinutes(5); var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            for (var i = 0; i < Points.Count; i++)
            {
                var x = Math.Clamp((Points[i].SampledAt - minTime).TotalSeconds / 300d, 0, 1) * ActualWidth;
                var y = ActualHeight - Math.Clamp(Points[i].Value / 100d, 0, 1) * ActualHeight;
                if (i == 0) context.BeginFigure(new(x, y), false, false); else context.LineTo(new(x, y), true, false);
            }
        }
        geometry.Freeze(); drawingContext.DrawGeometry(null, new MediaPen(new SolidColorBrush(MediaColor.FromRgb(15, 108, 189)), 2.25), geometry);
    }
}
