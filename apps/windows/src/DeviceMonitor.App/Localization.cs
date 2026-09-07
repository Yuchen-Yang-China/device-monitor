using System.Globalization;
using System.Windows;
using DeviceMonitor.Core;

namespace DeviceMonitor.App;

public static class Localization
{
    public static AppLanguage Current { get; private set; }
    public static event Action? Changed;

    public static void Apply(AppLanguage language)
    {
        Current = language;
        var culture = CultureInfo.GetCultureInfo(language == AppLanguage.SimplifiedChinese ? "zh-CN" : "en-US");
        CultureInfo.CurrentUICulture = culture;
        var dictionaries = System.Windows.Application.Current.Resources.MergedDictionaries;
        var old = dictionaries.Where(d => d.Source?.OriginalString.Contains("Strings.", StringComparison.OrdinalIgnoreCase) == true).ToArray();
        foreach (var dictionary in old) dictionaries.Remove(dictionary);
        dictionaries.Add(new ResourceDictionary
        {
            Source = new Uri($"Resources/Strings.{culture.Name}.xaml", UriKind.Relative)
        });
        Changed?.Invoke();
    }

    public static string Text(string key) => System.Windows.Application.Current.TryFindResource(key) as string ?? key;
    public static string Error(string value) => System.Windows.Application.Current.TryFindResource(value) as string ?? value;
}
