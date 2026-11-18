using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security;
using System.Text;
using System.Xml.Linq;

namespace PhoneBox.Agent;

/// <summary>
/// USB for the iOS app: what "adb reverse tcp:8765" is for the Android app.
///
/// An iPhone has no adb, but Apple's usbmuxd (built into macOS; the Apple Devices app / iTunes on Windows; the usbmuxd
/// package on Linux) lets the computer open TCP connections to a port on a phone plugged in over USB. While the PhoneBox
/// app is open it listens on its own 127.0.0.1:<see cref="PhonePort"/>, and this service keeps a few connections ("pipes")
/// to it waiting. When the app needs the agent, it takes one and sends an HTTP request through it; the first byte makes
/// this side connect the pipe to the agent's own 127.0.0.1 port, so the request arrives exactly like one through the adb
/// tunnel (local, no token), then a new pipe takes its place.
/// </summary>
public sealed class IosUsb(ILogger<IosUsb> log, AgentEndpoint? endpoint = null) : BackgroundService
{
    /// <summary>The port the iOS app listens on for these pipes (phone side).</summary>
    public const int PhonePort = 8767;
    /// <summary>The app checks this before taking a pipe, so only a PhoneBox agent is used.</summary>
    internal static readonly byte[] Hello = "PHONEBOX-USB/1\n"u8.ToArray();
    private const int IdleTarget = 4;
    private const int MaxPipes = 32;

    private readonly ConcurrentDictionary<int, Device> _devices = new();
    private volatile bool _muxMissingLogged;
    private int AgentPort => endpoint?.Port ?? 8765;

    /// <summary>iPhones / iPads on USB whose PhoneBox app is open (it answered on its port).</summary>
    public string[] Connected => _devices.Values.Where(d => d.AppOpen).Select(d => d.Serial).ToArray();

    private sealed class Device(int id, string serial)
    {
        public int Id { get; } = id;
        public string Serial { get; } = serial;
        public int Idle;
        public int Total;
        public long RetryAt;
        public volatile bool AppOpen;
        public volatile bool Gone;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var list = await Usbmux.ListDevicesAsync(ct);
                _muxMissingLogged = false;
                var seen = new HashSet<int>();
                foreach (var (id, serial) in list)
                {
                    seen.Add(id);
                    var d = _devices.GetOrAdd(id, _ =>
                    {
                        log.LogInformation("iOS device on USB: {Serial}", serial);
                        return new Device(id, serial);
                    });
                    Fill(d, ct);
                }
                foreach (var (id, d) in _devices)
                {
                    if (seen.Contains(id)) continue;
                    d.Gone = true;
                    _devices.TryRemove(id, out _);
                    log.LogInformation("iOS device unplugged: {Serial}", d.Serial);
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception ex) when (ex is SocketException or IOException or FormatException or TimeoutException)
            {
                // no usbmuxd: no Apple device support installed, or not running. Nothing to do until it is.
                if (!_muxMissingLogged) log.LogDebug("usbmuxd not reachable: {Message}", ex.Message);
                _muxMissingLogged = true;
                foreach (var d in _devices.Values) d.Gone = true;
                _devices.Clear();
            }
            try { await Task.Delay(TimeSpan.FromSeconds(2), ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Opens pipes until <see cref="IdleTarget"/> wait on the phone.</summary>
    private void Fill(Device d, CancellationToken ct)
    {
        if (d.Gone || Environment.TickCount64 < Interlocked.Read(ref d.RetryAt)) return;
        while (Volatile.Read(ref d.Idle) < IdleTarget && Volatile.Read(ref d.Total) < MaxPipes)
        {
            Interlocked.Increment(ref d.Idle);
            Interlocked.Increment(ref d.Total);
            _ = Task.Run(() => RunPipe(d, ct), ct);
        }
    }

    private async Task RunPipe(Device d, CancellationToken ct)
    {
        var idle = true;
        Socket? phone = null;
        try
        {
            phone = await Usbmux.ConnectAsync(d.Id, PhonePort, ct);
            if (phone is null)
            {
                // the app is not open (nothing listens on its port): try again a little later
                if (d.AppOpen) log.LogInformation("PhoneBox app on {Serial} closed", d.Serial);
                d.AppOpen = false;
                Interlocked.Exchange(ref d.RetryAt, Environment.TickCount64 + 2000);
                return;
            }
            if (!d.AppOpen) log.LogInformation("PhoneBox app on {Serial} is open: USB connection ready", d.Serial);
            d.AppOpen = true;
            using var phoneStream = new NetworkStream(phone, ownsSocket: true);
            await phoneStream.WriteAsync(Hello, ct);

            // wait for the app to use this pipe: its first bytes are the start of an HTTP request
            var first = new byte[16 * 1024];
            var n = await phoneStream.ReadAsync(first, ct);
            if (n <= 0) return;
            idle = false;
            Interlocked.Decrement(ref d.Idle);
            Fill(d, ct);

            using var agent = new TcpClient { NoDelay = true };
            await agent.ConnectAsync(IPAddress.Loopback, AgentPort, ct);
            using var agentStream = agent.GetStream();
            await agentStream.WriteAsync(first.AsMemory(0, n), ct);
            using var done = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var up = Pump(phoneStream, agentStream, done.Token);
            var down = Pump(agentStream, phoneStream, done.Token);
            await Task.WhenAny(up, down);
            done.Cancel();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is SocketException or IOException or FormatException or TimeoutException or ObjectDisposedException)
        {
            log.LogDebug("iOS USB pipe ended: {Message}", ex.Message);
        }
        finally
        {
            if (idle) Interlocked.Decrement(ref d.Idle);
            Interlocked.Decrement(ref d.Total);
            phone?.Dispose();
        }
        if (!ct.IsCancellationRequested && d.AppOpen) Fill(d, ct);
    }

    private static async Task Pump(Stream from, Stream to, CancellationToken ct)
    {
        try
        {
            var buffer = new byte[32 * 1024];
            int n;
            while ((n = await from.ReadAsync(buffer, ct)) > 0)
            {
                await to.WriteAsync(buffer.AsMemory(0, n), ct);
                await to.FlushAsync(ct);
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or ObjectDisposedException) { }
    }
}

/// <summary>
/// A minimal client for Apple's usbmuxd: list the attached devices and open a TCP connection to a port on one.
/// Messages are XML property lists after a 16-byte header (length, version 1, type 8, tag), all little-endian.
/// </summary>
internal static class Usbmux
{
    private const int PlistMessage = 8;
    private const int Version = 1;

    /// <summary>Where usbmuxd listens: USBMUXD_SOCKET_ADDRESS ("UNIX:/path" or "host:port") as in libimobiledevice.</summary>
    internal static EndPoint Address(string? overrideAddress, bool windows)
    {
        if (!string.IsNullOrWhiteSpace(overrideAddress))
        {
            var s = overrideAddress.Trim();
            if (s.StartsWith("UNIX:", StringComparison.OrdinalIgnoreCase)) return new UnixDomainSocketEndPoint(s[5..]);
            var colon = s.LastIndexOf(':');
            if (colon > 0 && int.TryParse(s[(colon + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var port) && port is > 0 and < 65536)
                return new DnsEndPoint(s[..colon], port);
        }
        return windows ? new IPEndPoint(IPAddress.Loopback, 27015) : new UnixDomainSocketEndPoint("/var/run/usbmuxd");
    }

    private static async Task<Socket> OpenAsync(CancellationToken ct)
    {
        var ep = Address(Environment.GetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS"), OperatingSystem.IsWindows());
        var socket = ep is UnixDomainSocketEndPoint
            ? new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified)
            : new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(2000);
            await socket.ConnectAsync(ep, timeout.Token);
            return socket;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            socket.Dispose();
            throw new TimeoutException("usbmuxd did not answer");
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    /// <summary>The devices attached over USB (not over Wi-Fi sync): (DeviceID, serial number).</summary>
    public static async Task<List<(int Id, string Serial)>> ListDevicesAsync(CancellationToken ct)
    {
        using var socket = await OpenAsync(ct);
        using var s = new NetworkStream(socket, ownsSocket: false);
        await SendAsync(s, Request("ListDevices"), 1, ct);
        var reply = await ReceiveAsync(s, ct);
        return Devices(reply);
    }

    internal static List<(int Id, string Serial)> Devices(Dictionary<string, object?> reply)
    {
        var result = new List<(int, string)>();
        if (reply.GetValueOrDefault("DeviceList") is not List<object?> list) return result;
        foreach (var item in list)
        {
            if (item is not Dictionary<string, object?> entry) continue;
            var props = entry.GetValueOrDefault("Properties") as Dictionary<string, object?> ?? entry;
            if (props.GetValueOrDefault("ConnectionType") is string type && type != "USB") continue;
            var id = props.GetValueOrDefault("DeviceID") ?? entry.GetValueOrDefault("DeviceID");
            if (id is not long l || l is <= 0 or > int.MaxValue) continue;
            result.Add(((int)l, props.GetValueOrDefault("SerialNumber") as string ?? l.ToString(CultureInfo.InvariantCulture)));
        }
        return result;
    }

    /// <summary>
    /// A TCP connection to <paramref name="port"/> on the device, or null when nothing listens there (the app is not
    /// open). After a successful Connect the usbmuxd socket itself is the connection.
    /// </summary>
    public static async Task<Socket?> ConnectAsync(int deviceId, int port, CancellationToken ct)
    {
        var socket = await OpenAsync(ct);
        try
        {
            using (var s = new NetworkStream(socket, ownsSocket: false))
            {
                var req = Request("Connect");
                req["DeviceID"] = (long)deviceId;
                req["PortNumber"] = (long)SwapPort(port);
                await SendAsync(s, req, 2, ct);
                var reply = await ReceiveAsync(s, ct);
                if (reply.GetValueOrDefault("Number") is not long result || result != 0)
                {
                    socket.Dispose();
                    return null;
                }
            }
            return socket;
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    /// <summary>usbmuxd wants the port in network byte order inside a host-order integer.</summary>
    internal static int SwapPort(int port) => ((port & 0xFF) << 8) | ((port >> 8) & 0xFF);

    private static Dictionary<string, object?> Request(string type) => new()
    {
        ["MessageType"] = type,
        ["ClientVersionString"] = "PhoneBox",
        ["ProgName"] = "PhoneBox",
    };

    internal static byte[] Frame(Dictionary<string, object?> message, int tag)
    {
        var body = Encoding.UTF8.GetBytes(Plist.Write(message));
        var frame = new byte[16 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(0), (uint)frame.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(4), Version);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(8), PlistMessage);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(12), (uint)tag);
        body.CopyTo(frame, 16);
        return frame;
    }

    private static async Task SendAsync(Stream s, Dictionary<string, object?> message, int tag, CancellationToken ct)
    {
        await s.WriteAsync(Frame(message, tag), ct);
        await s.FlushAsync(ct);
    }

    private static async Task<Dictionary<string, object?>> ReceiveAsync(Stream s, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(5000);
        try
        {
            var header = new byte[16];
            await s.ReadExactlyAsync(header, timeout.Token);
            var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
            if (length < 16 || length > 1 << 20) throw new FormatException("bad usbmuxd message length");
            var body = new byte[length - 16];
            await s.ReadExactlyAsync(body, timeout.Token);
            return Plist.Read(Encoding.UTF8.GetString(body));
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException("usbmuxd did not answer");
        }
    }
}

/// <summary>Just enough of Apple's XML property lists for usbmuxd: dict, array, string, integer, real, bool, data.</summary>
internal static class Plist
{
    public static string Write(Dictionary<string, object?> dict)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.Append("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
        sb.Append("<plist version=\"1.0\">\n");
        WriteValue(sb, dict);
        sb.Append("</plist>\n");
        return sb.ToString();
    }

    private static void WriteValue(StringBuilder sb, object? value)
    {
        switch (value)
        {
            case Dictionary<string, object?> d:
                sb.Append("<dict>\n");
                foreach (var (k, v) in d)
                {
                    sb.Append("<key>").Append(SecurityElement.Escape(k)).Append("</key>\n");
                    WriteValue(sb, v);
                }
                sb.Append("</dict>\n");
                break;
            case List<object?> list:
                sb.Append("<array>\n");
                foreach (var v in list) WriteValue(sb, v);
                sb.Append("</array>\n");
                break;
            case string s: sb.Append("<string>").Append(SecurityElement.Escape(s)).Append("</string>\n"); break;
            case bool b: sb.Append(b ? "<true/>\n" : "<false/>\n"); break;
            case long or int: sb.Append("<integer>").Append(Convert.ToInt64(value, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)).Append("</integer>\n"); break;
            case double r: sb.Append("<real>").Append(r.ToString("R", CultureInfo.InvariantCulture)).Append("</real>\n"); break;
            case byte[] data: sb.Append("<data>").Append(Convert.ToBase64String(data)).Append("</data>\n"); break;
            default: sb.Append("<string></string>\n"); break;
        }
    }

    public static Dictionary<string, object?> Read(string xml)
    {
        // usbmuxd sends the Apple DOCTYPE; it is skipped, never fetched
        var settings = new System.Xml.XmlReaderSettings { DtdProcessing = System.Xml.DtdProcessing.Ignore, XmlResolver = null };
        using var reader = System.Xml.XmlReader.Create(new StringReader(xml.TrimEnd('\0')), settings);
        var doc = XDocument.Load(reader);
        var root = doc.Root?.Name.LocalName == "plist" ? doc.Root.Elements().FirstOrDefault() : doc.Root;
        return ReadValue(root) as Dictionary<string, object?> ?? throw new FormatException("the property list is not a dict");
    }

    private static object? ReadValue(XElement? e)
    {
        if (e is null) return null;
        switch (e.Name.LocalName)
        {
            case "dict":
                var d = new Dictionary<string, object?>();
                string? key = null;
                foreach (var child in e.Elements())
                {
                    if (child.Name.LocalName == "key") key = child.Value;
                    else if (key is not null) { d[key] = ReadValue(child); key = null; }
                }
                return d;
            case "array": return e.Elements().Select(ReadValue).ToList();
            case "string": return e.Value;
            case "integer": return long.TryParse(e.Value.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var l) ? l : null;
            case "real": return double.TryParse(e.Value.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var r) ? r : null;
            case "true": return true;
            case "false": return false;
            case "data":
                try { return Convert.FromBase64String(string.Concat(e.Value.Where(c => !char.IsWhiteSpace(c)))); }
                catch (FormatException) { return null; }
            default: return null;
        }
    }
}
