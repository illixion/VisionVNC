using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using VisionVNC.Hotspot.Backend;

// One binary, two deployment shapes (the spike left the Session-0 question open, so we keep
// both): a Windows Service (control plane) OR an elevated interactive-session helper (the
// PoC default, side-stepping the documented Session-0 tethering risk). AddWindowsService()
// auto-detects which the SCM launched us as.

// --probe : print capability + status and exit (used by the installer / troubleshooting).
if (args.Contains("--probe"))
{
    using var lf = LoggerFactory.Create(b => b.AddSimpleConsole());
    var controller = new TetheringController(lf.CreateLogger<TetheringController>());
    Console.WriteLine("Upstream profiles:");
    foreach (var p in controller.ListUpstreamProfiles())
        Console.WriteLine($"  - {p.Name,-28} kind={p.Kind,-9} internet={p.HasInternet} default={p.IsDefault} cap={p.TetheringCapability}");
    var status = await controller.GetStatusAsync();
    Console.WriteLine($"State={status.State}  canHostAp={status.CanHostAp}");
    Console.WriteLine($"Capability: {status.CapabilityDetail}");
    return status.CanHostAp ? 0 : 1;
}

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddWindowsService(o => o.ServiceName = "VisionVNCHotspot");
builder.Services.AddSingleton<TetheringController>();
builder.Services.AddHostedService<MonitorService>();
builder.Services.AddHostedService<PipeServer>();

builder.Logging.AddSimpleConsole(o => o.SingleLine = true);
if (OperatingSystem.IsWindows())
    builder.Logging.AddEventLog(o => o.SourceName = "VisionVNCHotspot");

var host = builder.Build();
await host.RunAsync();
return 0;
