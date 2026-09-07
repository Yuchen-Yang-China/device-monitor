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
        drawingContext.DrawRoundedRectangle(new SolidColorBrush(MediaColor.FromRgb(242, 244, 247)), null, rect, 6, 6);
        drawingContext.DrawLine(new MediaPen(new SolidColorBrush(MediaColor.FromRgb(220, 224, 230)), 1), new(0, ActualHeight * .5), new(ActualWidth, ActualHeight * .5));
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
        geometry.Freeze(); drawingContext.DrawGeometry(null, new MediaPen(new SolidColorBrush(MediaColor.FromRgb(0, 120, 212)), 2), geometry);
    }
}
