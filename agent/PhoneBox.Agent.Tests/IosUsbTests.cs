using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Logging.Abstractions;
using PhoneBox.Agent;
using Xunit;

public sealed class IosUsbTests
{
    [Fact]
    public void ThePortGoesToUsbmuxdInNetworkByteOrder()
    {
        Assert.Equal(0x3F22, Usbmux.SwapPort(8767)); // 8767 = 0x223F
        Assert.Equal(0x7E0F, Usbmux.SwapPort(3966));
    }

    [Fact]
    public void AMessageHasTheUsbmuxdHeaderAndAnXmlPlist()
    {
        var frame = Usbmux.Frame(new() { ["MessageType"] = "Connect", ["DeviceID"] = 7L, ["PortNumber"] = 0x3F22L }, 2);
        Assert.Equal((uint)frame.Length, BinaryPrimitives.ReadUInt32LittleEndian(frame));
        Assert.Equal(1u, BinaryPrimitives.ReadUInt32LittleEndian(frame.AsSpan(4)));
        Assert.Equal(8u, BinaryPrimitives.ReadUInt32LittleEndian(frame.AsSpan(8)));
        Assert.Equal(2u, BinaryPrimitives.ReadUInt32LittleEndian(frame.AsSpan(12)));
        var back = Plist.Read(Encoding.UTF8.GetString(frame, 16, frame.Length - 16));
        Assert.Equal("Connect", back["MessageType"]);
        Assert.Equal(7L, back["DeviceID"]);
        Assert.Equal(0x3F22L, back["PortNumber"]);
    }

    [Fact]
    public void OnlyUsbDevicesAreListed()
    {
        const string xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>DeviceList</key><array>
              <dict><key>DeviceID</key><integer>3</integer><key>MessageType</key><string>Attached</string>
                <key>Properties</key><dict><key>ConnectionType</key><string>USB</string><key>DeviceID</key><integer>3</integer>
                <key>SerialNumber</key><string>00008030-001A</string><key>LocationID</key><integer>-1</integer></dict></dict>
              <dict><key>DeviceID</key><integer>9</integer><key>Properties</key><dict><key>ConnectionType</key><string>Network</string>
                <key>DeviceID</key><integer>9</integer><key>EscapedFullServiceName</key><string>x</string></dict></dict>
            </array></dict></plist>
            """;
        var devices = Usbmux.Devices(Plist.Read(xml));
        Assert.Equal([(3, "00008030-001A")], devices);
    }

    [Fact]
    public void TheEnvironmentCanPointToAnotherUsbmuxd()
    {
        Assert.Equal(new IPEndPoint(IPAddress.Loopback, 27015), Usbmux.Address(null, windows: true));
        Assert.IsType<UnixDomainSocketEndPoint>(Usbmux.Address(null, windows: false));
        Assert.IsType<UnixDomainSocketEndPoint>(Usbmux.Address("UNIX:/tmp/mux", windows: true));
        Assert.Equal(new DnsEndPoint("127.0.0.1", 5000), Usbmux.Address("127.0.0.1:5000", windows: false));
    }

    /// <summary>
    /// The whole path with a fake usbmuxd, a fake phone app and a fake agent: the phone receives the hello on an idle
    /// pipe, sends a request through it, and the agent's answer comes back.
    /// </summary>
    [Fact]
    public async Task ARequestFromThePhoneReachesTheAgentThroughAPipe()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var ct = cts.Token;

        // the agent's HTTP port (an echo of the request line here)
        var agent = new TcpListener(IPAddress.Loopback, 0);
        agent.Start();
        var agentPort = ((IPEndPoint)agent.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                var c = await agent.AcceptTcpClientAsync(ct);
                _ = Task.Run(async () =>
                {
                    using var _c = c;
                    var s = c.GetStream();
                    var buf = new byte[1024];
                    var n = await s.ReadAsync(buf, ct);
                    var line = Encoding.ASCII.GetString(buf, 0, n).Split("\r\n")[0];
                    await s.WriteAsync(Encoding.ASCII.GetBytes("answer to " + line), ct);
                }, ct);
            }
        }, ct);

        // the phone: each Connect to the app's port gets a pipe; the first one is used
        var pipes = System.Threading.Channels.Channel.CreateUnbounded<Socket>();
        var mux = new TcpListener(IPAddress.Loopback, 0);
        mux.Start();
        var muxPort = ((IPEndPoint)mux.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                var c = await mux.AcceptSocketAsync(ct);
                _ = Task.Run(async () =>
                {
                    var s = new NetworkStream(c, ownsSocket: false);
                    var header = new byte[16];
                    await s.ReadExactlyAsync(header, ct);
                    var body = new byte[BinaryPrimitives.ReadUInt32LittleEndian(header) - 16];
                    await s.ReadExactlyAsync(body, ct);
                    var msg = Plist.Read(Encoding.UTF8.GetString(body));
                    if ((string?)msg["MessageType"] == "ListDevices")
                    {
                        var dev = new Dictionary<string, object?> { ["ConnectionType"] = "USB", ["DeviceID"] = 1L, ["SerialNumber"] = "TEST" };
                        await s.WriteAsync(Usbmux.Frame(new() { ["DeviceList"] = new List<object?> { new Dictionary<string, object?> { ["DeviceID"] = 1L, ["Properties"] = dev } } }, 1), ct);
                        c.Dispose();
                        return;
                    }
                    Assert.Equal((long)Usbmux.SwapPort(IosUsb.PhonePort), msg["PortNumber"]);
                    await s.WriteAsync(Usbmux.Frame(new() { ["MessageType"] = "Result", ["Number"] = 0L }, 2), ct);
                    await pipes.Writer.WriteAsync(c, ct);
                }, ct);
            }
        }, ct);

        Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", $"127.0.0.1:{muxPort}");
        try
        {
            var service = new IosUsb(NullLogger<IosUsb>.Instance, new AgentEndpoint(agentPort));
            await service.StartAsync(ct);
            var pipe = await pipes.Reader.ReadAsync(ct);
            using var ps = new NetworkStream(pipe, ownsSocket: true);
            var hello = new byte[IosUsb.Hello.Length];
            await ps.ReadExactlyAsync(hello, ct);
            Assert.Equal(IosUsb.Hello, hello);

            await ps.WriteAsync("GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"u8.ToArray(), ct);
            var buf = new byte[256];
            var n = await ps.ReadAsync(buf, ct);
            Assert.Equal("answer to GET /api/state HTTP/1.1", Encoding.ASCII.GetString(buf, 0, n));
            Assert.Equal(["TEST"], service.Connected);
            await service.StopAsync(CancellationToken.None);
        }
        finally
        {
            Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", null);
            cts.Cancel();
            mux.Stop();
            agent.Stop();
        }
    }
}
