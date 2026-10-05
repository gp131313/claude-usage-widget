// Setup.cs — однофайловый установщик Claude Usage Widget (ClaudeUsageWidget-Setup.exe).
// Внутри exe лежат те же файлы, что и в архиве с Setup.cmd: он распаковывает их во временную папку
// и запускает install.ps1 без окна консоли. Прав администратора не требует. Сборка — build.ps1.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Claude Usage Widget Setup")]
[assembly: AssemblyProduct("Claude Usage Widget")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

static class Setup
{
    [STAThread]
    static int Main()
    {
        string dir = Path.Combine(Path.GetTempPath(), "ClaudeUsageWidget-Setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        try
        {
            Directory.CreateDirectory(dir);
            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string name in asm.GetManifestResourceNames())
            {
                using (Stream src = asm.GetManifestResourceStream(name))
                using (FileStream dst = File.Create(Path.Combine(dir, name)))
                    src.CopyTo(dst);
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "install.ps1") + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;   // окна установщика — диалоги самого install.ps1
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("Установка не удалась:\n\n" + ex.Message, "Claude Usage Widget", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }
}
