// Setup.cs — однофайловый установщик Claude Usage Widget. Внутри exe лежат те же файлы, что и в архиве
// с Setup.cmd: он распаковывает их во временную папку и запускает install.ps1 без окна консоли.
// Прав администратора не требует. Сборка — build.ps1. Один исходник, два файла:
//   ClaudeUsageWidget-Setup.exe         мастер «Далее → Установить → Готово»
//   ClaudeUsageWidget-Setup-Silent.exe  без единого окна (то же даёт ключ /silent у первого)
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("Claude Usage Widget Setup")]
[assembly: AssemblyProduct("Claude Usage Widget")]
[assembly: AssemblyVersion("1.4.0.0")]
[assembly: AssemblyFileVersion("1.4.0.0")]

public static class Setup
{
    public const string Title = "Claude Usage Widget";
    // язык окон — по языку Windows: русский или английский
    public static bool Ru = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru";
    public static string T(string ru, string en) { return Ru ? ru : en; }

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static int Main(string[] args)
    {
        // тихий режим: по имени файла (…-Silent.exe) или по ключу /silent, /quiet, /s, /q
        bool silent = Path.GetFileNameWithoutExtension(Application.ExecutablePath).IndexOf("silent", StringComparison.OrdinalIgnoreCase) >= 0;
        foreach (string a in args)
        {
            string s = a.TrimStart('/', '-').ToLowerInvariant();
            if (s == "silent" || s == "verysilent" || s == "quiet" || s == "s" || s == "q") silent = true;
            else if (s.StartsWith("dir=") && s.Length > 4) Dir = Path.GetFullPath(a.Substring(a.IndexOf('=') + 1).Trim('"')).TrimEnd('\\');   // /dir=<папка установки>
        }
        if (silent)
        {
            try { return RunInstall("-Silent"); } catch { return 1; }
        }
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Wizard w = new Wizard();
        Application.Run(w);
        return w.ExitCode;
    }

    public static string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeUsageWidget");

    // распаковать вложенные файлы и выполнить install.ps1 с заданными ключами; возвращает его код выхода.
    // Распаковка — сразу в папку установки: запуск скриптов из %TEMP% антивирусы блокируют.
    public static int RunInstall(string psArgs)
    {
        string dir = Dir;
        psArgs += " -Dir \"" + dir + "\"";
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
            ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "install.ps1") + "\" " + psArgs);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        finally
        {
            try { File.Delete(Path.Combine(dir, "install.ps1")); } catch { }   // остальное — файлы самой программы
        }
    }
}

// Мастер: 0 приветствие → 1 параметры → 2 установка → 3 готово
public class Wizard : Form
{
    public int ExitCode = 1;   // 1 — отменено или не удалось
    int page;
    string error;
    Label head, sub, body;
    Panel optPanel;
    CheckBox autoBox;
    ProgressBar bar;
    Button back, next, cancel;
    static string T(string ru, string en) { return Setup.T(ru, en); }
    float scale = 1F;
    int S(int v) { return (int)Math.Round(v * scale); }
    Point P(int x, int y) { return new Point(S(x), S(y)); }
    Size Z(int w, int h) { return new Size(S(w), S(h)); }


    static bool LoggedIn
    {
        get
        {
            string cfg = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            if (string.IsNullOrEmpty(cfg)) cfg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
            return File.Exists(Path.Combine(cfg, ".credentials.json"));
        }
    }

    public Wizard()
    {
        SuspendLayout();
        AutoScaleMode = AutoScaleMode.None;   // масштабируем сами: координаты ниже — в логических px (96 dpi)
        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) scale = g.DpiX / 96F;
        ClientSize = Z(500, 344);
        Text = T("Установка ", "Setup — ") + Setup.Title;
        Font = new Font("Segoe UI", 9F);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        Panel header = new Panel(); header.BackColor = Color.White; header.Location = P(0, 0); header.Size = Z(500, 66);
        head = new Label(); head.Font = new Font("Segoe UI", 11F, FontStyle.Bold); head.Location = P(18, 12); head.Size = Z(464, 24);
        sub = new Label(); sub.ForeColor = Color.FromArgb(90, 90, 90); sub.Location = P(18, 38); sub.Size = Z(464, 20);
        header.Controls.Add(head); header.Controls.Add(sub);
        Label line1 = new Label(); line1.BorderStyle = BorderStyle.Fixed3D; line1.Location = P(0, 66); line1.Size = Z(500, 2);

        body = new Label(); body.Location = P(24, 86); body.Size = Z(452, 196);

        optPanel = new Panel(); optPanel.Location = P(24, 86); optPanel.Size = Z(452, 196); optPanel.Visible = false;
        Label pathLabel = new Label(); pathLabel.Text = T("Папка установки:", "Install folder:"); pathLabel.Location = P(0, 0); pathLabel.Size = Z(452, 20);
        TextBox pathBox = new TextBox(); pathBox.ReadOnly = true; pathBox.Text = Setup.Dir; pathBox.Location = P(0, 22); pathBox.Size = Z(452, 23); pathBox.TabStop = false;
        autoBox = new CheckBox(); autoBox.Text = T("Запускать виджет при входе в Windows", "Start the widget when I sign in to Windows"); autoBox.Checked = true; autoBox.Location = P(0, 62); autoBox.Size = Z(452, 24);
        Label note = new Label(); note.ForeColor = Color.FromArgb(90, 90, 90); note.Location = P(0, 100); note.Size = Z(452, 90);
        note.Text = T("Устанавливается только для вашей учётной записи, права администратора не нужны.\n\n"
                    + "Удалить можно в любой момент: «Параметры» → «Приложения» → " + Setup.Title + ".",
                      "Installed for your user account only; no administrator rights are needed.\n\n"
                    + "You can uninstall it at any time: Settings → Apps → " + Setup.Title + ".");
        optPanel.Controls.Add(pathLabel); optPanel.Controls.Add(pathBox); optPanel.Controls.Add(autoBox); optPanel.Controls.Add(note);

        bar = new ProgressBar(); bar.Style = ProgressBarStyle.Marquee; bar.MarqueeAnimationSpeed = 30; bar.Location = P(24, 126); bar.Size = Z(452, 18); bar.Visible = false;

        Label line2 = new Label(); line2.BorderStyle = BorderStyle.Fixed3D; line2.Location = P(0, 292); line2.Size = Z(500, 2);
        back = new Button(); back.Text = T("< Назад", "< Back"); back.Location = P(206, 306); back.Size = Z(88, 26);
        next = new Button(); next.Location = P(300, 306); next.Size = Z(88, 26);
        cancel = new Button(); cancel.Text = T("Отмена", "Cancel"); cancel.Location = P(400, 306); cancel.Size = Z(88, 26);
        back.Click += delegate { ShowPage(0); };
        next.Click += delegate { if (page == 0) ShowPage(1); else if (page == 1) StartInstall(); else Close(); };
        cancel.Click += delegate { Close(); };
        AcceptButton = next; CancelButton = cancel;

        Controls.Add(bar); Controls.Add(optPanel); Controls.Add(body);
        Controls.Add(header); Controls.Add(line1); Controls.Add(line2);
        Controls.Add(back); Controls.Add(next); Controls.Add(cancel);
        ResumeLayout(false);
        PerformLayout();

        FormClosing += delegate(object s, FormClosingEventArgs e) { if (page == 2) e.Cancel = true; };   // во время установки не закрываем
        ShowPage(0);
    }

    public void ShowPage(int p)
    {
        page = p;
        optPanel.Visible = (p == 1);
        body.Visible = (p != 1);
        bar.Visible = (p == 2);
        back.Visible = (p < 2); back.Enabled = (p == 1);
        next.Enabled = (p != 2);
        cancel.Enabled = (p < 2);
        switch (p)
        {
            case 0:
                head.Text = T("Установка ", "Welcome to ") + Setup.Title + T("", " Setup");
                sub.Text = T("Расход квоты Claude — на панели задач Windows", "Your Claude usage — on the Windows taskbar");
                body.Text = T("Виджет показывает прямо на панели задач, сколько квоты Claude (Pro/Max) осталось в 5-часовом окне "
                            + "и на неделю, и какой темп расхода позволит дотянуть до конца недели.\n\n"
                            + "Данные берутся из вашего входа в Claude Code. Если вход ещё не выполнен, установщик поможет это сделать.\n\n"
                            + "Нажмите «Далее», чтобы продолжить.",
                              "The widget shows right on the taskbar how much of your Claude (Pro/Max) limit is left in the 5-hour window "
                            + "and for the week, and what pace of spending will last you until the end of the week.\n\n"
                            + "The data comes from your Claude Code sign-in. If you are not signed in yet, Setup will help you do it.\n\n"
                            + "Click Next to continue.");
                next.Text = T("Далее >", "Next >");
                break;
            case 1:
                head.Text = T("Параметры установки", "Installation options");
                sub.Text = T("Проверьте параметры и нажмите «Установить»", "Review the options and click Install");
                next.Text = T("Установить", "Install");
                break;
            case 2:
                head.Text = T("Установка", "Installing");
                sub.Text = T("Подождите, это займёт несколько секунд", "Please wait, this takes a few seconds");
                body.Text = T("Копирование файлов и настройка…", "Copying files and setting up…");
                break;
            case 3:
                head.Text = T("Установка завершена", "Installation complete");
                sub.Text = Setup.Title + T(" установлен", " is installed");
                string auto = autoBox.Checked ? T(" и будет запускаться сам при входе в Windows", " and will start by itself when you sign in to Windows") : "";
                if (LoggedIn)
                    body.Text = T("Виджет уже на панели задач — слева от значков у часов", "The widget is already on the taskbar, to the left of the icons near the clock") + auto + ".\n\n"
                              + T("Правый щелчок по виджету — настройки.\n\n", "Right-click the widget for settings.\n\n")
                              + T("Удаление: «Параметры» → «Приложения» → ", "To uninstall: Settings → Apps → ") + Setup.Title + ".";
                else
                    body.Text = T("Виджет уже на панели задач — слева от значков у часов", "The widget is already on the taskbar, to the left of the icons near the clock") + auto + ".\n\n"
                              + T("Вход в Claude пока не выполнен, поэтому вместо цифр виджет показывает «Войдите в Claude». "
                                + "Щёлкните по нему правой кнопкой и выберите «Войти в аккаунт Claude…».\n\n",
                                  "You are not signed in to Claude yet, so the widget shows \"Sign in to Claude\" instead of numbers. "
                                + "Right-click it and choose \"Sign in to Claude…\".\n\n")
                              + T("Удаление: «Параметры» → «Приложения» → ", "To uninstall: Settings → Apps → ") + Setup.Title + ".";
                next.Text = T("Готово", "Finish");
                next.Focus();
                break;
        }
    }

    void StartInstall()
    {
        ShowPage(2);
        string psArgs = "-NoFinishBox" + (autoBox.Checked ? "" : " -NoAutostart");
        Task.Factory.StartNew<int>(delegate
        {
            try { return Setup.RunInstall(psArgs); }
            catch (Exception ex) { error = ex.Message; return 1; }
        }).ContinueWith(delegate(Task<int> t) { Done(t.Result); }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void Done(int code)
    {
        ExitCode = code;
        page = 3;   // снять запрет на закрытие
        if (code != 0)
        {
            // об ошибке внутри install.ps1 он уже сообщил сам; здесь — только сбой запуска
            if (error != null) MessageBox.Show(this, T("Установка не удалась:\n\n", "Installation failed:\n\n") + error, Setup.Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
            return;
        }
        ShowPage(3);
        Activate();
    }
}
