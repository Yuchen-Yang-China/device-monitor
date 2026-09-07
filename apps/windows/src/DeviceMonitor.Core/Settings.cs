using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Globalization;

namespace DeviceMonitor.Core;

public enum AppLanguage { English, SimplifiedChinese }

public sealed record AppSettings
{
    public string DeviceId { get; init; } = Guid.NewGuid().ToString("D").ToLowerInvariant();
    public string DeviceName { get; init; } = Environment.MachineName;
    public SamplingMode SamplingMode { get; init; } = SamplingMode.Balanced;
    public AppLanguage Language { get; init; } = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? AppLanguage.SimplifiedChinese : AppLanguage.English;
    public bool PeerEnabled { get; init; }
    public string? ListenAddress { get; init; }
    public string? PeerAddress { get; init; }
}

public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    public SettingsStore(string directory) { Directory = directory; SettingsPath = Path.Combine(directory, "settings.json"); }
    public string Directory { get; }
    public string SettingsPath { get; }
    public AppSettings LoadOrCreate()
    {
        System.IO.Directory.CreateDirectory(Directory);
        try
        {
            if (File.Exists(SettingsPath))
            {
                var value = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), Options);
                if (value is not null && Guid.TryParseExact(value.DeviceId, "D", out _)) return value;
            }
        }
        catch (Exception) { }
        var created = new AppSettings(); Save(created); return created;
    }
    public void Save(AppSettings value)
    {
        System.IO.Directory.CreateDirectory(Directory); var temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value, Options)); File.Move(temporary, SettingsPath, true);
    }
}

public sealed class ProtectedSecretStore
{
    private readonly string _path;
    public ProtectedSecretStore(string directory) => _path = Path.Combine(directory, "pairing-secret.dat");
    public byte[] LoadOrCreate()
    {
        if (File.Exists(_path))
        {
            var protectedBytes = File.ReadAllBytes(_path);
            try { return Unprotect(protectedBytes); }
            finally { CryptographicOperations.ZeroMemory(protectedBytes); }
        }
        var secret = Protocol.PeerAuthentication.GenerateSecret(); Save(secret); return secret;
    }
    public void Save(ReadOnlySpan<byte> secret)
    {
        if (secret.Length != 32) throw new ArgumentException("Pairing secret must contain exactly 32 bytes.", nameof(secret));
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(_path)!); var protectedBytes = Protect(secret);
        try { File.WriteAllBytes(_path, protectedBytes); } finally { CryptographicOperations.ZeroMemory(protectedBytes); }
    }

    private static byte[] Protect(ReadOnlySpan<byte> plaintext) => Transform(plaintext, true);
    private static byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => Transform(ciphertext, false);
    private static byte[] Transform(ReadOnlySpan<byte> input, bool protect)
    {
        var inputBytes = input.ToArray(); var inputBlob = new DataBlob(); var outputBlob = new DataBlob();
        try
        {
            inputBlob.Size = inputBytes.Length; inputBlob.Data = Marshal.AllocHGlobal(inputBytes.Length); Marshal.Copy(inputBytes, 0, inputBlob.Data, inputBytes.Length);
            var ok = protect
                ? CryptProtectData(ref inputBlob, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0x1, out outputBlob)
                : CryptUnprotectData(ref inputBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0x1, out outputBlob);
            if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            var output = new byte[outputBlob.Size]; Marshal.Copy(outputBlob.Data, output, 0, output.Length); return output;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(inputBytes);
            if (inputBlob.Data != IntPtr.Zero) { unsafe { new Span<byte>((void*)inputBlob.Data, inputBlob.Size).Clear(); } Marshal.FreeHGlobal(inputBlob.Data); }
            if (outputBlob.Data != IntPtr.Zero) LocalFree(outputBlob.Data);
        }
    }

    [StructLayout(LayoutKind.Sequential)] private struct DataBlob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob dataIn, string? description, IntPtr optionalEntropy, IntPtr reserved, IntPtr prompt, uint flags, out DataBlob dataOut);
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob dataIn, IntPtr description, IntPtr optionalEntropy, IntPtr reserved, IntPtr prompt, uint flags, out DataBlob dataOut);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
}

public static class NetworkBinding
{
    public static IReadOnlyList<IPAddress> PrivateIPv4Addresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up).SelectMany(n => n.GetIPProperties().UnicastAddresses)
        .Select(a => a.Address).Where(IsPrivateIPv4).Distinct().OrderBy(a => a.ToString()).ToArray();
    public static bool IsPrivateIPv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false; var b = address.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) ||
               (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] is >= 64 and <= 127);
    }
}

public static class PeerEndpoint
{
    public static bool TryParse(string? value, out Uri endpoint)
    {
        endpoint = null!;
        if (string.IsNullOrWhiteSpace(value) || value.Contains('/') || value.Contains('?') || value.Contains('#')) return false;
        if (!Uri.TryCreate("http://" + value.Trim(), UriKind.Absolute, out var parsed) || string.IsNullOrWhiteSpace(parsed.Host)) return false;
        var builder = new UriBuilder(parsed) { Scheme = "http", Path = Protocol.ProtocolConstants.StatusPath, Query = "", Fragment = "" };
        if (parsed.IsDefaultPort) builder.Port = Protocol.ProtocolConstants.DefaultPort;
        endpoint = builder.Uri; return true;
    }
}
