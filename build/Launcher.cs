// Debora.exe — запускач Debora.ps1, що лежить поруч. Права адміністратора просить маніфест (одне вікно UAC).
// Без аргументів — вікно програми (PowerShell без консолі); з аргументами — ті самі аргументи Debora.ps1
// у вікні консолі (Debora.exe -Scan, -Menu, -Guard …). Запускач одразу завершується, тож оновлення може
// перезаписати й його. Версію підставляє build\Compile.ps1.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("Debora")]
[assembly: AssemblyProduct("Debora")]
[assembly: AssemblyDescription("Debora: Windows debloat, setup from scratch and maintenance")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("%VERSION%")]
[assembly: AssemblyFileVersion("%VERSION%")]
[assembly: AssemblyInformationalVersion("%INFOVERSION%")]

static class DeboraLauncher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    static string Quote(string a)
    {
        if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
        return "\"" + a.Replace("\"", "\\\"") + "\"";
    }

    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "Debora.ps1");
        if (!File.Exists(script))
        {
            MessageBoxW(IntPtr.Zero, "Debora.ps1 не знайдено поруч із Debora.exe:\n" + dir + "\n\nРозпакуйте архів Debora повністю й запустіть Debora.exe з тієї ж папки.\n\nDebora.ps1 was not found next to Debora.exe.", "Debora", 0x10);
            return 2;
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        bool gui = args.Length == 0;
        var sb = new StringBuilder("-NoProfile -ExecutionPolicy Bypass ");
        if (gui) sb.Append("-WindowStyle Hidden ");
        sb.Append("-File ").Append(Quote(script));
        if (gui) sb.Append(" -Gui");
        else foreach (string a in args) sb.Append(' ').Append(Quote(a));
        var psi = new ProcessStartInfo(ps, sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = gui;
        psi.WorkingDirectory = dir;
        try { Process.Start(psi); }
        catch (Exception e)
        {
            MessageBoxW(IntPtr.Zero, "Не вдалося запустити PowerShell:\n" + e.Message, "Debora", 0x10);
            return 1;
        }
        return 0;
    }
}
