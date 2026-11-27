using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Rectangle = System.Windows.Shapes.Rectangle;

[assembly: AssemblyTitle("校园网守卫")]
[assembly: AssemblyDescription("JXAU 校园网自动认证守护脚本的图形界面")]
[assembly: AssemblyProduct("jxau-campus-net-gui")]
[assembly: AssemblyVersion("0.1.0.0")]
[assembly: AssemblyFileVersion("0.1.0.0")]

namespace JxauGuardUI
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            string[] args = Environment.GetCommandLineArgs();
            bool selfTest = args.Length > 1 && string.Equals(args[1], "--selftest", StringComparison.OrdinalIgnoreCase);

            if (selfTest)
            {
                // 无界面自检：结果和异常都写文件，绝不弹窗
                string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "selftest.txt");
                try
                {
                    var probe = new GuardUi();
                    File.WriteAllText(path, probe.RunSelfTest(), new UTF8Encoding(false));
                }
                catch (Exception ex)
                {
                    try
                    {
                        File.WriteAllText(path, "ok=false\n" + ex, new UTF8Encoding(false));
                    }
                    catch
                    {
                        // 连结果都写不进去就没办法了
                    }
                }
                Environment.Exit(0);
                return;
            }

            try
            {
                var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                var ui = new GuardUi();
                app.Run(ui.Window);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.ToString(), "校园网守卫启动失败",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }

    internal sealed class GuardUi
    {
        private const int KeepaliveWindowFallbackSec = 300;

        public Window Window { get; private set; }

        private readonly string _runtimeDir;
        private readonly string _statePath;
        private readonly string _configPath;
        private readonly string _logPath;
        private readonly string _pauseFlag;
        private readonly string _credPath;
        private string _scriptDir;
        private readonly string _exeDir;
        private readonly string _uiConfigPath;
        private Dictionary<string, object> _uiConfig;

        private TextBlock _txtPhase, _txtMessage, _txtRun, _txtUserIndex, _txtLogins, _txtBudget, _txtFooter, _txtAccount, _txtAutoStart, _txtScript;
        private TextBlock _txtHead, _txtCredState, _txtAutoStartDetail, _txtScriptDetail, _txtTimeoutHint, _txtBackground, _txtAboutPaths;
        private TextBox _txtLog, _txtLogPreview, _txtUser, _txtTimeout, _txtTitle;
        private PasswordBox _pwdMain, _pwdConfirm;
        private Button _btnStart, _btnPause, _btnRestart, _btnSaveCred, _btnInstall, _btnPickScript;
        private Button _btnSaveTimeout, _btnSaveTitle, _btnPickBg, _btnResetBg, _btnOpenLog, _btnClearLog, _btnUninstall;
        private Button _navOverview, _navAccount, _navSettings, _navLogs, _navAbout;
        private Grid _pageOverview, _pageAccount, _pageSettings, _pageLogs, _pageAbout;
        private Rectangle _bgImage, _bgOverlay;
        private Brush _defaultBgBrush;
        private string _currentBgPath;

        private readonly DispatcherTimer _timer;
        private bool _scriptOk;
        private DateTime _lastLogWrite = DateTime.MinValue;
        private long _lastLogLen = -1;

        private int _effectivePid;
        private bool _looksRunning;
        private int _cachedWmiPid;
        private DateTime _cachedWmiAt = DateTime.MinValue;

        private static readonly Brush BrushGreen = new SolidColorBrush(Color.FromRgb(0x15, 0x80, 0x3D));
        private static readonly Brush BrushAmber = new SolidColorBrush(Color.FromRgb(0xB4, 0x53, 0x09));
        private static readonly Brush BrushRed = new SolidColorBrush(Color.FromRgb(0xBE, 0x12, 0x3C));
        private static readonly Brush BrushNormal = new SolidColorBrush(Color.FromRgb(0x0F, 0x17, 0x2A));
        private static readonly Brush BrushMuted = new SolidColorBrush(Color.FromRgb(0x94, 0xA3, 0xB8));

        public GuardUi()
        {
            // 调试/排查用：设了 CAMPUSNET_RUNTIME_DIR 就改读写这个目录
            string overrideDir = Environment.GetEnvironmentVariable("CAMPUSNET_RUNTIME_DIR");
            _runtimeDir = string.IsNullOrWhiteSpace(overrideDir)
                ? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "CampusNetGuard")
                : overrideDir;
            _statePath = Path.Combine(_runtimeDir, "state.json");
            _configPath = Path.Combine(_runtimeDir, "config.json");
            _logPath = Path.Combine(_runtimeDir, "guard.log");
            _pauseFlag = Path.Combine(_runtimeDir, "paused.flag");
            _credPath = Path.Combine(_runtimeDir, "credential.dat");

            _exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            if (string.IsNullOrEmpty(_exeDir)) _exeDir = Environment.CurrentDirectory;
            _uiConfigPath = Path.Combine(_exeDir, "ui-config.json");
            _uiConfig = LoadUiConfig();
            _scriptDir = ResolveScriptDir(_exeDir, _uiConfig);

            BuildWindow();
            ApplyAppearance();

            _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
            _timer.Tick += (s, e) => Refresh();
            _timer.Start();
            Refresh();
        }

        // ---------------------------------------------------------------- 界面构建

        private void BuildWindow()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("GuardUI.xaml"))
            {
                if (stream == null)
                {
                    throw new InvalidOperationException("找不到内嵌资源 GuardUI.xaml，编译参数里要带 /resource:");
                }
                Window = (Window)XamlReader.Load(stream);
            }

            _txtPhase = Find<TextBlock>("TxtPhase");
            _txtMessage = Find<TextBlock>("TxtMessage");
            _txtRun = Find<TextBlock>("TxtRun");
            _txtUserIndex = Find<TextBlock>("TxtUserIndex");
            _txtLogins = Find<TextBlock>("TxtLogins");
            _txtBudget = Find<TextBlock>("TxtBudget");
            _txtFooter = Find<TextBlock>("TxtFooter");
            _txtHead = Find<TextBlock>("TxtHead");
            _txtAccount = Find<TextBlock>("TxtAccount");
            _txtAutoStart = Find<TextBlock>("TxtAutoStart");
            _txtScript = Find<TextBlock>("TxtScript");
            _txtCredState = Find<TextBlock>("TxtCredState");
            _txtAutoStartDetail = Find<TextBlock>("TxtAutoStartDetail");
            _txtScriptDetail = Find<TextBlock>("TxtScriptDetail");
            _txtTimeoutHint = Find<TextBlock>("TxtTimeoutHint");
            _txtBackground = Find<TextBlock>("TxtBackground");
            _txtAboutPaths = Find<TextBlock>("TxtAboutPaths");

            _txtLog = Find<TextBox>("TxtLog");
            _txtLogPreview = Find<TextBox>("TxtLogPreview");
            _txtUser = Find<TextBox>("TxtUser");
            _txtTimeout = Find<TextBox>("TxtTimeout");
            _txtTitle = Find<TextBox>("TxtTitle");
            _pwdMain = Find<PasswordBox>("PwdMain");
            _pwdConfirm = Find<PasswordBox>("PwdConfirm");

            _btnStart = Find<Button>("BtnStart");
            _btnPause = Find<Button>("BtnPause");
            _btnRestart = Find<Button>("BtnRestart");
            _btnSaveCred = Find<Button>("BtnSaveCred");
            _btnInstall = Find<Button>("BtnInstall");
            _btnPickScript = Find<Button>("BtnPickScript");
            _btnSaveTimeout = Find<Button>("BtnSaveTimeout");
            _btnSaveTitle = Find<Button>("BtnSaveTitle");
            _btnPickBg = Find<Button>("BtnPickBg");
            _btnResetBg = Find<Button>("BtnResetBg");
            _btnOpenLog = Find<Button>("BtnOpenLog");
            _btnClearLog = Find<Button>("BtnClearLog");
            _btnUninstall = Find<Button>("BtnUninstall");

            _navOverview = Find<Button>("NavOverview");
            _navAccount = Find<Button>("NavAccount");
            _navSettings = Find<Button>("NavSettings");
            _navLogs = Find<Button>("NavLogs");
            _navAbout = Find<Button>("NavAbout");
            _pageOverview = Find<Grid>("PageOverview");
            _pageAccount = Find<Grid>("PageAccount");
            _pageSettings = Find<Grid>("PageSettings");
            _pageLogs = Find<Grid>("PageLogs");
            _pageAbout = Find<Grid>("PageAbout");

            _bgImage = Find<Rectangle>("BgImage");
            _bgOverlay = Find<Rectangle>("BgOverlay");
            _defaultBgBrush = _bgImage.Fill;

            _navOverview.Click += (s, e) => SetPage(_pageOverview, _navOverview);
            _navAccount.Click += (s, e) => SetPage(_pageAccount, _navAccount);
            _navSettings.Click += (s, e) => SetPage(_pageSettings, _navSettings);
            _navLogs.Click += (s, e) => SetPage(_pageLogs, _navLogs);
            _navAbout.Click += (s, e) => SetPage(_pageAbout, _navAbout);

            _btnStart.Click += (s, e) => StartGuard();
            _btnPause.Click += (s, e) => PauseGuard();
            _btnRestart.Click += (s, e) => RestartGuard();
            _btnSaveCred.Click += (s, e) => SaveCredentialsInline();
            _btnInstall.Click += (s, e) => InstallAutoStart();
            _btnPickScript.Click += (s, e) => PickScriptDir();
            _btnSaveTimeout.Click += (s, e) => SaveTimeoutInline();
            _btnSaveTitle.Click += (s, e) => SaveTitleInline();
            _btnPickBg.Click += (s, e) => PickBackgroundInline();
            _btnResetBg.Click += (s, e) => ResetBackgroundInline();
            _btnOpenLog.Click += (s, e) => OpenLogFolder();
            _btnClearLog.Click += (s, e) => ClearLogs();
            _btnUninstall.Click += (s, e) => RunUninstall();

            _txtTimeout.TextChanged += (s, e) => UpdateTimeoutHint();

            _txtFooter.Text = "脚本目录：" + _scriptDir + "    ·    数据目录：" + _runtimeDir;
            _txtAboutPaths.Text = "脚本目录\n  " + _scriptDir + "\n\n数据目录\n  " + _runtimeDir;

            SetPage(_pageOverview, _navOverview);
            LoadSettingsIntoUi();
        }

        // ---------------------------------------------------------------- 页面切换

        private void SetPage(Grid page, Button nav)
        {
            var pages = new[] { _pageOverview, _pageAccount, _pageSettings, _pageLogs, _pageAbout };
            var navs = new[] { _navOverview, _navAccount, _navSettings, _navLogs, _navAbout };

            for (int i = 0; i < pages.Length; i++)
            {
                bool active = ReferenceEquals(pages[i], page);
                pages[i].Visibility = active ? Visibility.Visible : Visibility.Collapsed;

                Button b = navs[i];
                if (active)
                {
                    b.Background = new SolidColorBrush(Color.FromRgb(0x3D, 0x7B, 0xFA));
                    b.Foreground = Brushes.White;
                    b.FontWeight = FontWeights.SemiBold;
                }
                else
                {
                    b.Background = Brushes.Transparent;
                    b.Foreground = new SolidColorBrush(Color.FromRgb(0x33, 0x41, 0x55));
                    b.FontWeight = FontWeights.Normal;
                }
            }
        }

        private T Find<T>(string name) where T : class
        {
            var element = Window.FindName(name) as T;
            if (element == null)
            {
                throw new InvalidOperationException("界面里找不到控件：" + name);
            }
            return element;
        }

        // ---------------------------------------------------------------- 刷新

        private void Refresh()
        {
            Dictionary<string, object> state = ReadState();
            bool paused = File.Exists(_pauseFlag);
            int pid = state != null ? ToInt(state, "pid") : 0;
            bool running = IsGuardRunning(pid);

            // state.json 里的 pid 只有新版守护进程会写；老版本靠 WMI 按命令行兜底
            if (!running)
            {
                int wmiPid = FindGuardPidByWmi();
                if (wmiPid > 0)
                {
                    pid = wmiPid;
                    running = true;
                }
            }

            // 再兜一层：state.json 每轮都会重写，文件时间新就说明进程活着
            // （不能用 lastOnlineAt，暂停状态下它不会更新；也不能在解析失败时用，否则坏文件会被误判成运行中）
            if (!running && state != null)
            {
                try
                {
                    if (File.Exists(_statePath)
                        && (DateTime.Now - File.GetLastWriteTime(_statePath)).TotalSeconds < 90)
                    {
                        running = true;
                        pid = 0;
                    }
                }
                catch
                {
                    // 读不到文件时间就算了
                }
            }
            _effectivePid = running ? pid : 0;
            _looksRunning = running;

            string phase = state != null ? ToStr(state, "phase") : "unknown";
            if (paused)
            {
                _txtPhase.Text = "已暂停";
                _txtPhase.Foreground = BrushAmber;
            }
            else
            {
                _txtPhase.Text = PhaseText(phase);
                _txtPhase.Foreground = PhaseBrush(phase);
            }

            _txtMessage.Text = state != null ? ToStr(state, "lastMessage") : "还没读到状态文件，可能从未运行过";
            if (paused)
            {
                _txtMessage.Text = "已停止登录与保活。恢复后会立刻检查当前网络状态。";
            }

            _txtRun.Text = running
                ? (pid > 0 ? "守护进程：运行中（PID " + pid + "）" : "守护进程：运行中")
                : "守护进程：未运行";
            _txtRun.Foreground = running ? BrushGreen : BrushMuted;

            string userIndex = state != null ? ToStr(state, "userIndex") : "";
            if (string.IsNullOrEmpty(userIndex))
            {
                _txtUserIndex.Text = "会话：—";
            }
            else
            {
                _txtUserIndex.Text = "会话：" + Shorten(userIndex, 18);
            }

            _txtLogins.Text = "今日重登：" + (state != null ? ToInt(state, "todayLoginCount") : 0) + " 次";

            _txtBudget.Text = BuildBudgetText(state);

            // 先算脚本目录是否可用，下面的按钮/菜单状态要用到
            RefreshScriptStatus();

            _btnStart.IsEnabled = _scriptOk && (paused || !running);
            _btnPause.IsEnabled = !paused;
            _btnRestart.IsEnabled = _scriptOk;


            RefreshLog();
            RefreshAccount();
            RefreshAutoStart();
        }

        private string BuildBudgetText(Dictionary<string, object> state)
        {
            if (state == null) return "";
            string since = ToStr(state, "reconnectSince");
            if (string.IsNullOrEmpty(since)) return "重连预算：空闲";

            DateTime started;
            if (!DateTime.TryParse(since, out started)) return "";
            int window = ReadReconnectWindowSec();
            if (window <= 0) return "重连预算：不限制（会一直重试）";
            double left = window - (DateTime.Now - started).TotalSeconds;
            if (left < 0) left = 0;
            return "重连预算：剩 " + (int)left + " 秒";
        }

        private int ReadReconnectWindowSec()
        {
            try
            {
                if (!File.Exists(_configPath)) return KeepaliveWindowFallbackSec;
                var cfg = Deserialize(File.ReadAllText(_configPath, Encoding.UTF8));
                if (cfg == null || !cfg.ContainsKey("reconnectWindowSec")) return KeepaliveWindowFallbackSec;
                int v = ToInt(cfg, "reconnectWindowSec");
                return v < 0 ? 0 : v;
            }
            catch
            {
                return KeepaliveWindowFallbackSec;
            }
        }

        private void SaveReconnectSeconds(int minutes)
        {
            Dictionary<string, object> cfg;
            if (File.Exists(_configPath))
            {
                cfg = Deserialize(File.ReadAllText(_configPath, Encoding.UTF8))
                      ?? new Dictionary<string, object>();
            }
            else
            {
                cfg = new Dictionary<string, object>();
            }

            cfg["reconnectWindowSec"] = minutes * 60;
            Directory.CreateDirectory(_runtimeDir);
            File.WriteAllText(_configPath,
                new JavaScriptSerializer().Serialize(cfg), new UTF8Encoding(false));
        }

        private void SaveTimeoutInline()
        {
            int minutes;
            if (!int.TryParse((_txtTimeout.Text ?? "").Trim(), out minutes) || minutes < 0 || minutes > 1440)
            {
                MessageBox.Show(Window,
                    "请填 0 到 1440 之间的整数（分钟）。\n\n0 = 不限制：掉线后会一直尝试，直到连上或你手动暂停。",
                    "重连超时", MessageBoxButton.OK, MessageBoxImage.Warning);
                _txtTimeout.Focus();
                return;
            }

            try
            {
                SaveReconnectSeconds(minutes);
                Refresh();
                MessageBox.Show(Window, "已保存。下一轮巡检生效（最多 30 秒），不用重启守护进程。",
                    "重连超时", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(Window, "保存失败：" + ex.Message, "重连超时",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void UpdateTimeoutHint()
        {
            int currentSec = ReadReconnectWindowSec();
            string currentText = currentSec <= 0 ? "不限制" : (currentSec / 60) + " 分钟";

            string pending = "";
            int typed;
            if (int.TryParse((_txtTimeout.Text ?? "").Trim(), out typed) && typed >= 0 && typed <= 1440)
            {
                string target = typed == 0 ? "不限制" : typed + " 分钟";
                if (!string.Equals(target, currentText, StringComparison.Ordinal))
                {
                    pending = "   -> 保存后改为：" + target;
                }
            }

            _txtTimeoutHint.Text =
                "当前生效：" + currentText + pending + "\n" +
                "掉线后最多自动重连这么久（期间按 5/15/30/60 秒退避）；用完还连不上就停手、只探测不登录，" +
                "免得反复骚扰认证设备，等你手动登一次后自动接管。\n" +
                "填 0 = 不限制；范围 0–1440 分钟；保存后最多 30 秒生效，不用重启。";
        }

        private void LoadSettingsIntoUi()
        {
            CredPair cred = ReadCredential();
            if (cred != null)
            {
                _txtUser.Text = cred.User;
            }

            int sec = ReadReconnectWindowSec();
            _txtTimeout.Text = (sec / 60).ToString();

            string title = ToStr(_uiConfig, "title");
            if (string.IsNullOrWhiteSpace(title)) title = "JNT v2";
            _txtTitle.Text = title;

            RefreshBackgroundText();
            UpdateTimeoutHint();
        }

        private void SaveTitleInline()
        {
            string title = (_txtTitle.Text ?? "").Trim();
            if (title.Length == 0) title = "JNT v2";

            string bg = ToStr(_uiConfig, "background");
            SaveUiConfig(title, bg);
            _uiConfig["title"] = title;
            ApplyAppearance();

            MessageBox.Show(Window, "标题已保存：" + title, "标题",
                MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void PickBackgroundInline()
        {
            var dialog = new OpenFileDialog
            {
                Title = "选择背景图片",
                Filter = "图片文件|*.png;*.jpg;*.jpeg;*.bmp;*.webp;*.gif|所有文件|*.*",
                CheckFileExists = true
            };
            if (dialog.ShowDialog() != true) return;

            string ext = Path.GetExtension(dialog.FileName);
            if (string.IsNullOrEmpty(ext)) ext = ".png";
            string target = Path.Combine(_exeDir, "bg-custom" + ext);
            string stored;

            try
            {
                foreach (string old in Directory.GetFiles(_exeDir, "bg-custom.*"))
                {
                    if (!string.Equals(old, target, StringComparison.OrdinalIgnoreCase))
                    {
                        try { File.Delete(old); } catch { }
                    }
                }
                File.Copy(dialog.FileName, target, true);
                stored = Path.GetFileName(target);
            }
            catch
            {
                stored = dialog.FileName;   // 复制不了就直接读原路径
            }

            SaveUiConfig(ToStr(_uiConfig, "title"), stored);
            _uiConfig["background"] = stored;
            ApplyBackground(ResolveBackgroundPath());
            RefreshBackgroundText();
        }

        private void ResetBackgroundInline()
        {
            try
            {
                foreach (string old in Directory.GetFiles(_exeDir, "bg-custom.*"))
                {
                    try { File.Delete(old); } catch { }
                }
            }
            catch { }

            SaveUiConfig(ToStr(_uiConfig, "title"), "");
            _uiConfig["background"] = "";
            ApplyAppearance();
            RefreshBackgroundText();
        }

        private void RefreshBackgroundText()
        {
            string bg = ToStr(_uiConfig, "background");
            if (!string.IsNullOrWhiteSpace(bg))
            {
                _txtBackground.Text = Path.GetFileName(bg);
                return;
            }

            string auto = ResolveBackgroundPath();
            _txtBackground.Text = string.IsNullOrEmpty(auto)
                ? "默认（浅色渐变）"
                : "默认（" + Path.GetFileName(auto) + "）";
        }

        private void SaveCredentialsInline()
        {
            string user = (_txtUser.Text ?? "").Trim();
            string p1 = _pwdMain.Password ?? "";
            string p2 = _pwdConfirm.Password ?? "";

            if (user.Length == 0)
            {
                MessageBox.Show(Window, "学号不能为空。", "账号", MessageBoxButton.OK, MessageBoxImage.Warning);
                _txtUser.Focus();
                return;
            }
            if (p1.Length == 0)
            {
                MessageBox.Show(Window, "密码不能为空。", "账号", MessageBoxButton.OK, MessageBoxImage.Warning);
                _pwdMain.Focus();
                return;
            }
            if (p1 != p2)
            {
                MessageBox.Show(Window, "两次输入的密码不一致。", "账号", MessageBoxButton.OK, MessageBoxImage.Warning);
                _pwdConfirm.Focus();
                return;
            }

            try
            {
                WriteCredential(user, p1);
            }
            catch (Exception ex)
            {
                MessageBox.Show(Window, "保存失败：" + ex.Message, "账号", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            _pwdMain.Password = "";
            _pwdConfirm.Password = "";
            Refresh();

            MessageBoxResult answer = MessageBox.Show(Window,
                "账号已保存。\n守护进程只在启动时读取账号，需要重启才生效。\n\n现在重启吗？",
                "账号", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer == MessageBoxResult.Yes)
            {
                RestartGuard();
            }
        }

        private void RefreshLog()
        {
            try
            {
                if (!File.Exists(_logPath))
                {
                    _txtLog.Text = "（还没有日志，先点「启动」并等它跑一轮）";
                    return;
                }

                var info = new FileInfo(_logPath);
                if (info.Length == _lastLogLen && info.LastWriteTime == _lastLogWrite)
                {
                    return;
                }
                _lastLogLen = info.Length;
                _lastLogWrite = info.LastWriteTime;

                const int maxBytes = 256 * 1024;
                long start = Math.Max(0, info.Length - maxBytes);

                using (var fs = new FileStream(_logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    fs.Seek(start, SeekOrigin.Begin);
                    var buffer = new byte[info.Length - start];
                    int read = 0;
                    int n;
                    while (read < buffer.Length && (n = fs.Read(buffer, read, buffer.Length - read)) > 0)
                    {
                        read += n;
                    }

                    string text = Encoding.UTF8.GetString(buffer, 0, read);
                    string[] lines = text.Replace("\r\n", "\n").Split('\n');
                    int take = Math.Min(200, lines.Length);
                    string tail = string.Join("\n", lines, lines.Length - take, take);

                    // 用户往上翻的时候别强行拽回底部
                    double maxOffset = Math.Max(0, _txtLog.ExtentHeight - _txtLog.ViewportHeight);
                    bool atBottom = _txtLog.VerticalOffset >= maxOffset - 2;
                    _txtLog.Text = tail.TrimEnd('\n');
                    if (atBottom) _txtLog.ScrollToEnd();

                    // 概览页只放最近 8 行，够看个大概
                    int previewTake = Math.Min(8, lines.Length);
                    _txtLogPreview.Text = string.Join("\n", lines, lines.Length - previewTake, previewTake).TrimEnd('\n');
                    _txtLogPreview.ScrollToEnd();
                }
            }
            catch (Exception ex)
            {
                _txtLog.Text = "读取日志失败：" + ex.Message;
            }
        }

        // ---------------------------------------------------------------- 自检

        public string SelfTestPath
        {
            get
            {
                string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                if (string.IsNullOrEmpty(exeDir)) exeDir = Environment.CurrentDirectory;
                return Path.Combine(exeDir, "selftest.txt");
            }
        }

        public string RunSelfTest()        {
            var sb = new StringBuilder();
            sb.AppendLine("ok=true");
            sb.AppendLine("title=" + Window.Title);
            sb.AppendLine("head=" + _txtHead.Text);
            sb.AppendLine("background=" + (string.IsNullOrEmpty(_currentBgPath) ? "(默认渐变)" : Path.GetFileName(_currentBgPath)));
            sb.AppendLine("uiConfig=" + _uiConfigPath);
            sb.AppendLine("scriptDir=" + _scriptDir);
            sb.AppendLine("runtimeDir=" + _runtimeDir);
            sb.AppendLine("guardPs1Found=" + File.Exists(Path.Combine(_scriptDir, "guard.ps1")));
            sb.AppendLine("phase=" + _txtPhase.Text);
            sb.AppendLine("message=" + _txtMessage.Text);
            sb.AppendLine("run=" + _txtRun.Text);
            sb.AppendLine("logins=" + _txtLogins.Text);
            sb.AppendLine("budget=" + _txtBudget.Text);
            sb.AppendLine("buttons.start=" + _btnStart.IsEnabled);
            sb.AppendLine("buttons.pause=" + _btnPause.IsEnabled);
            sb.AppendLine("buttons.restart=" + _btnRestart.IsEnabled);
            sb.AppendLine("pages.overview=" + (_pageOverview.Visibility == Visibility.Visible));
            sb.AppendLine("pages.account=" + _pageAccount.Visibility);
            sb.AppendLine("pages.settings=" + _pageSettings.Visibility);

            // 页面切换自检：五个页面逐个切一遍，确认没有异常
            try
            {
                SetPage(_pageAccount, _navAccount);
                SetPage(_pageSettings, _navSettings);
                SetPage(_pageLogs, _navLogs);
                SetPage(_pageAbout, _navAbout);
                SetPage(_pageOverview, _navOverview);
                sb.AppendLine("pageSwitch=ok");
            }
            catch (Exception ex)
            {
                sb.AppendLine("pageSwitch=FAIL " + ex.Message);
            }
            long logSize = 0;
            try { if (File.Exists(_logPath)) logSize = new FileInfo(_logPath).Length; } catch { }
            sb.AppendLine("logSize=" + logSize);
            CredPair cred = ReadCredential();
            sb.AppendLine("account=" + (cred == null ? "(未录入)" : cred.User));
            bool autoStart = false;
            try { autoStart = File.Exists(TaskDefinitionPath()); } catch { }
            sb.AppendLine("autoStart=" + autoStart);
            sb.AppendLine("timeoutSec=" + ReadReconnectWindowSec());
            string log = _txtLog.Text ?? "";
            sb.AppendLine("logLines=" + log.Split('\n').Length);
            return sb.ToString();
        }

        // ---------------------------------------------------------------- 动作

        private void StartGuard()
        {
            try
            {
                bool wasPaused = File.Exists(_pauseFlag);
                if (wasPaused)
                {
                    File.Delete(_pauseFlag);
                }

                int pid = _effectivePid > 0 ? _effectivePid : CurrentPid();
                if (IsGuardRunning(pid) || _looksRunning)
                {
                    MessageBox.Show(
                        wasPaused
                            ? "已恢复运行。守护进程下一轮就会重新检查网络。"
                            : "守护进程本来就在运行，不需要再启动。\n想重新加载请点「重启」。",
                        "启动", MessageBoxButton.OK, MessageBoxImage.Information);
                    Refresh();
                    return;
                }

                if (LaunchGuard())
                {
                    MessageBox.Show(
                        "已启动守护进程。\n关掉这个窗口不影响它继续运行。",
                        "启动", MessageBoxButton.OK, MessageBoxImage.Information);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败：" + ex.Message, "启动",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
            Refresh();
        }

        private void PauseGuard()
        {
            try
            {
                if (File.Exists(_pauseFlag))
                {
                    MessageBox.Show("已经是暂停状态了。", "暂停",
                        MessageBoxButton.OK, MessageBoxImage.Information);
                    Refresh();
                    return;
                }

                Directory.CreateDirectory(_runtimeDir);
                File.WriteAllText(_pauseFlag, DateTime.Now.ToString("o"), Encoding.UTF8);

                MessageBox.Show(
                    "已暂停：不再自动登录，也不再发保活。\n点「启动」随时恢复。",
                    "暂停", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("暂停失败：" + ex.Message, "暂停",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
            Refresh();
        }

        private void RestartGuard()
        {
            bool killed = false;
            int oldPid = 0;

            try
            {
                int pid = _effectivePid;
                if (pid <= 0) pid = CurrentPid();
                if (IsGuardRunning(pid))
                {
                    try
                    {
                        Process.GetProcessById(pid).Kill();
                        killed = true;
                        oldPid = pid;
                        Thread.Sleep(500);
                    }
                    catch
                    {
                        // 进程可能刚好自己退出了
                    }
                }

                if (File.Exists(_pauseFlag))
                {
                    File.Delete(_pauseFlag);
                }

                if (killed || !_looksRunning)
                {
                    if (LaunchGuard())
                    {
                        MessageBox.Show(
                            killed
                                ? "已结束旧进程（PID " + oldPid + "）并重新启动。"
                                : "已重新启动（之前没有在运行的实例）。",
                            "重启", MessageBoxButton.OK, MessageBoxImage.Information);
                    }
                }
                else
                {
                    MessageBox.Show(
                        "检测到守护进程在运行，但拿不到它的进程号，没法结束它。\n" +
                        "可以到「任务管理器 → 详细信息」里手动结束 powershell.exe，" +
                        "或者直接重启电脑。\n\n暂停标志已经清理。",
                        "重启", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("重启失败：" + ex.Message, "重启",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
            Refresh();
        }

        private void OpenLogFolder()
        {
            try
            {
                Directory.CreateDirectory(_runtimeDir);
            }
            catch
            {
                // 目录建不出来也继续试
            }

            string via = null;

            // 方式一：把文件夹直接交给 shell（推荐的写法，不会再手工拉起 explorer.exe）
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = _runtimeDir,
                    UseShellExecute = true
                });
                via = "shell";
            }
            catch
            {
                // 继续试下一种
            }

            // 方式二：带 /e 参数调 explorer，避开 0xc0000142 那种壳层问题
            if (via == null)
            {
                try
                {
                    Process.Start("explorer.exe", "/e," + _runtimeDir);
                    via = "explorer";
                }
                catch
                {
                    // 继续
                }
            }

            // 方式三：交给 cmd start
            if (via == null)
            {
                try
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "cmd.exe",
                        Arguments = "/c start \"\" \"" + _runtimeDir + "\"",
                        UseShellExecute = false,
                        CreateNoWindow = true
                    });
                    via = "cmd";
                }
                catch
                {
                    // 全部失败
                }
            }

            if (via != null)
            {
                MessageBox.Show(
                    "已打开日志文件夹。\n" + _runtimeDir,
                    "打开日志文件夹", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show(
                    "系统不让我打开资源管理器。\n\n把下面这个路径复制到资源管理器地址栏就行：\n" + _runtimeDir,
                    "打开日志文件夹", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void RunUninstall()
        {
            string cmd = Path.Combine(_scriptDir, "uninstall.cmd");
            if (!File.Exists(cmd))
            {
                MessageBox.Show("没找到 uninstall.cmd：" + _scriptDir, "校园网守卫");
                return;
            }

            var answer = MessageBox.Show(
                "会停止并删除计划任务、还原网卡设置、清理运行数据。\n\n确定卸载吗？",
                "卸载校园网守卫", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
            if (answer != MessageBoxResult.OK)
            {
                return;
            }

            try
            {
                var psi = new ProcessStartInfo("cmd.exe", "/c \"" + cmd + "\"");
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                psi.WorkingDirectory = _scriptDir;
                Process.Start(psi);

                MessageBox.Show(
                    "已启动卸载程序，请在弹出的窗口里按提示操作。\n卸载完成后可以关掉本窗口。",
                    "卸载", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("卸载没执行（可能是取消了 UAC）：\n" + ex.Message, "卸载",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void ClearLogs()
        {
            string log = _logPath;
            string rotated = _logPath + ".1";

            long total = 0;
            foreach (string f in new[] { log, rotated })
            {
                try { if (File.Exists(f)) total += new FileInfo(f).Length; }
                catch { }
            }

            if (total == 0)
            {
                MessageBox.Show("日志已经是空的，没有可清理的内容。", "清理日志",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            var answer = MessageBox.Show(
                "会删除 guard.log 和轮转出来的 guard.log.1（共 " + (total / 1024) + " KB）。\n" +
                "状态、配置和账号不受影响，守护进程会继续往新日志里写。\n\n确定清理吗？",
                "清理日志", MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (answer != MessageBoxResult.OK) return;

            var failed = new System.Collections.Generic.List<string>();
            foreach (string f in new[] { log, rotated })
            {
                try
                {
                    if (File.Exists(f)) File.Delete(f);
                }
                catch (Exception ex)
                {
                    failed.Add(Path.GetFileName(f) + "：" + ex.Message);
                }
            }

            // 让日志面板立刻重新读取
            _lastLogLen = -1;
            _lastLogWrite = DateTime.MinValue;
            RefreshLog();

            if (failed.Count == 0)
            {
                MessageBox.Show("已清理 " + (total / 1024) + " KB 日志。", "清理日志",
                    MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show("有文件删不掉（可能正被占用，稍后再试）：\n" + string.Join("\n", failed),
                    "清理日志", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private bool LaunchGuard()
        {
            string vbs = Path.Combine(_scriptDir, "launch.vbs");
            if (!File.Exists(vbs))
            {
                MessageBox.Show(
                    "找不到 launch.vbs，脚本目录是：\n" + _scriptDir + "\n\n" +
                    "界面需要和校园网脚本放在一起。两种办法：\n" +
                    "1. 把 guard.ps1、launch.vbs 等脚本复制到界面同目录；\n" +
                    "2. 点第二行「指定脚本目录…」，选中脚本所在文件夹。",
                    "启动", MessageBoxButton.OK, MessageBoxImage.Error);
                return false;
            }

            try
            {
                var psi = new ProcessStartInfo("wscript.exe", "//B //Nologo \"" + vbs + "\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                // 关键：不继承本程序的工作目录。否则子进程会把 GUI 所在文件夹当成当前目录，
                // 那个文件夹就删不掉、改不了名了（复制一份到别处再删就会踩到）。
                psi.WorkingDirectory = _scriptDir;
                Process.Start(psi);
                return true;
            }
            catch (Exception ex)
            {
                MessageBox.Show("启动失败：" + ex.Message, "启动",
                    MessageBoxButton.OK, MessageBoxImage.Error);
                return false;
            }
        }

        // ---------------------------------------------------------------- 外观（标题 / 背景）

        private Dictionary<string, object> LoadUiConfig()
        {
            try
            {
                if (File.Exists(_uiConfigPath))
                {
                    return Deserialize(File.ReadAllText(_uiConfigPath, Encoding.UTF8))
                        ?? new Dictionary<string, object>();
                }
            }
            catch
            {
                // 配置坏了就当没有
            }
            return new Dictionary<string, object>();
        }

        private void ApplyAppearance()
        {
            string title = ToStr(_uiConfig, "title");
            if (string.IsNullOrWhiteSpace(title)) title = "JNT v2";
            Window.Title = title;
            _txtHead.Text = title;

            ApplyBackground(ResolveBackgroundPath());
        }

        private string ResolveBackgroundPath()
        {
            string fromConfig = ToStr(_uiConfig, "background");
            if (!string.IsNullOrWhiteSpace(fromConfig))
            {
                string p = fromConfig;
                if (!Path.IsPathRooted(p)) p = Path.Combine(_exeDir, p);
                if (File.Exists(p)) return p;
            }

            foreach (string ext in new[] { ".png", ".jpg", ".jpeg", ".bmp", ".webp", ".gif" })
            {
                string p = Path.Combine(_exeDir, "bg" + ext);
                if (File.Exists(p)) return p;
            }

            try
            {
                if (Directory.Exists(_runtimeDir))
                {
                    foreach (string p in Directory.GetFiles(_runtimeDir, "background.*"))
                    {
                        return p;
                    }
                }
            }
            catch
            {
                // 目录读不了就算了
            }

            return null;
        }

        private void ApplyBackground(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                _bgImage.Fill = _defaultBgBrush;
                _bgOverlay.Fill = new SolidColorBrush(Colors.Transparent);
                _currentBgPath = null;
                return;
            }

            try
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.CreateOptions = BitmapCreateOptions.IgnoreImageCache;
                bitmap.UriSource = new Uri(path, UriKind.Absolute);
                bitmap.EndInit();
                bitmap.Freeze();

                var brush = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
                brush.Freeze();

                _bgImage.Fill = brush;
                _bgOverlay.Fill = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF));
                _currentBgPath = path;
            }
            catch
            {
                _bgImage.Fill = _defaultBgBrush;
                _bgOverlay.Fill = new SolidColorBrush(Colors.Transparent);
                _currentBgPath = null;
            }
        }

        private string ToStorablePath(string absolute)
        {
            if (string.IsNullOrEmpty(absolute)) return "";
            try
            {
                string full = Path.GetFullPath(absolute);
                string dir = Path.GetFullPath(_exeDir) + Path.DirectorySeparatorChar;
                if (full.StartsWith(dir, StringComparison.OrdinalIgnoreCase))
                {
                    return full.Substring(dir.Length);
                }
            }
            catch
            {
                // 保持绝对路径
            }
            return absolute;
        }

        private void SaveUiConfig(string title, string background)
        {
            try
            {
                var config = new Dictionary<string, object>
                {
                    { "scriptDir", ToStorableDir(_scriptDir) },
                    { "title", title },
                    { "background", background ?? "" }
                };
                File.WriteAllText(_uiConfigPath, new JavaScriptSerializer().Serialize(config), new UTF8Encoding(false));
                _uiConfig = config;
            }
            catch
            {
                // 写不进去就算了，下次启动回到默认
            }
        }

        private string ToStorableDir(string absolute)
        {
            // 尽量存相对路径：整个文件夹复制到别处后，配置仍然指得对
            try
            {
                string full = Path.GetFullPath(absolute).TrimEnd('\\');
                string exeFull = Path.GetFullPath(_exeDir).TrimEnd('\\');

                if (string.Equals(full, exeFull, StringComparison.OrdinalIgnoreCase)) return ".";

                string exeBase = exeFull + Path.DirectorySeparatorChar;
                if (full.StartsWith(exeBase, StringComparison.OrdinalIgnoreCase))
                {
                    return full.Substring(exeBase.Length);
                }

                string parent = Path.GetDirectoryName(exeFull);
                if (!string.IsNullOrEmpty(parent))
                {
                    string parentBase = parent.TrimEnd('\\') + Path.DirectorySeparatorChar;
                    if (full.StartsWith(parentBase, StringComparison.OrdinalIgnoreCase))
                    {
                        return ".." + Path.DirectorySeparatorChar + full.Substring(parentBase.Length);
                    }
                }
            }
            catch
            {
                // 算不出来就存绝对路径
            }
            return absolute;
        }

        // ---------------------------------------------------------------- 账号

        private sealed class CredPair
        {
            public string User;
            public string Pass;
        }

        private CredPair ReadCredential()
        {
            try
            {
                if (!File.Exists(_credPath)) return null;

                string hex = File.ReadAllText(_credPath, Encoding.ASCII).Trim();
                if (hex.Length == 0) return null;

                byte[] encrypted = HexToBytes(hex);
                byte[] plain = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
                string text = Encoding.Unicode.GetString(plain);

                int cut = text.IndexOf('\n');
                if (cut < 0) return null;

                return new CredPair
                {
                    User = text.Substring(0, cut),
                    Pass = text.Substring(cut + 1)
                };
            }
            catch
            {
                // 换了 Windows 账户、或者文件被改坏，DPAPI 都会解不开
                return null;
            }
        }

        private void WriteCredential(string user, string pass)
        {
            Directory.CreateDirectory(_runtimeDir);
            byte[] plain = Encoding.Unicode.GetBytes(user + "\n" + pass);
            byte[] encrypted = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
            File.WriteAllText(_credPath, BytesToHex(encrypted), Encoding.ASCII);
        }

        private static byte[] HexToBytes(string hex)
        {
            hex = hex.Trim();
            byte[] bytes = new byte[hex.Length / 2];
            for (int i = 0; i < bytes.Length; i++)
            {
                bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            }
            return bytes;
        }

        private static string BytesToHex(byte[] bytes)
        {
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }

        private void RefreshAccount()
        {
            CredPair cred = ReadCredential();

            if (cred == null)
            {
                _txtAccount.Text = File.Exists(_credPath)
                    ? "账号解不开（换过 Windows 账户？请重新录入）"
                    : "未录入账号 —— 没有它守护进程无法自动登录";
                _txtAccount.Foreground = BrushRed;

                _txtCredState.Text = File.Exists(_credPath) ? "凭据解不开，请重新输入" : "还没有录入账号";
                _txtCredState.Foreground = BrushRed;
            }
            else
            {
                _txtAccount.Text = "账号：" + cred.User + "（密码已用 Windows DPAPI 加密，只存本机）";
                _txtAccount.Foreground = BrushNormal;

                _txtCredState.Text = "当前账号：" + cred.User + "（密码已加密保存）";
                _txtCredState.Foreground = BrushGreen;
            }
        }

        private static string TaskDefinitionPath()
        {
            // 计划任务在磁盘上的定义文件，存在即说明已注册（比每次调 schtasks 便宜得多）
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "Tasks", "CampusNetGuard");
        }

        private void RefreshScriptStatus()
        {
            _scriptOk = File.Exists(Path.Combine(_scriptDir, "guard.ps1"));
            bool launcherOk = File.Exists(Path.Combine(_scriptDir, "launch.vbs"));

            if (_scriptOk && launcherOk)
            {
                _txtScript.Text = _scriptDir;
                _txtScript.Foreground = BrushNormal;
                _txtScriptDetail.Text = "guard.ps1 和 launch.vbs 都在这里，状态正常。";
                _txtScriptDetail.Foreground = BrushGreen;
            }
            else if (_scriptOk)
            {
                _txtScript.Text = _scriptDir + "（缺 launch.vbs）";
                _txtScript.Foreground = BrushAmber;
                _txtScriptDetail.Text = "这个目录有 guard.ps1，但缺少 launch.vbs，启动会失败。建议整份脚本一起复制。";
                _txtScriptDetail.Foreground = BrushAmber;
            }
            else
            {
                _txtScript.Text = "没找到 guard.ps1 —— 用下面的「指定目录…」选一下";
                _txtScript.Foreground = BrushRed;
                _txtScriptDetail.Text = "界面需要和脚本放在同一个文件夹，或者手动指定 guard.ps1 所在的目录。";
                _txtScriptDetail.Foreground = BrushRed;
            }
        }

        private void PickScriptDir()
        {
            var dialog = new OpenFileDialog
            {
                Title = "选择 guard.ps1 所在目录",
                Filter = "守护脚本 guard.ps1|guard.ps1|所有文件|*.*",
                CheckFileExists = true,
                InitialDirectory = Directory.Exists(_scriptDir) ? _scriptDir : _exeDir
            };

            if (dialog.ShowDialog() != true) return;

            string dir = Path.GetDirectoryName(dialog.FileName);
            if (string.IsNullOrEmpty(dir)) return;

            if (!File.Exists(Path.Combine(dir, "guard.ps1")))
            {
                MessageBox.Show("这个目录里没有 guard.ps1，换一个试试。", "脚本目录",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            _scriptDir = dir;
            SaveUiConfig(ToStr(_uiConfig, "title"),
                _currentBgPath == null ? "" : ToStorablePath(_currentBgPath));
            RefreshScriptStatus();
            Refresh();

            MessageBox.Show("脚本目录已设为：\n" + dir, "脚本目录",
                MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void RefreshAutoStart()
        {
            bool installed;
            try
            {
                installed = File.Exists(TaskDefinitionPath());
            }
            catch
            {
                installed = false;
            }

            if (installed)
            {
                _txtAutoStart.Text = "已启用 —— 登录 Windows 后自动在后台运行";
                _txtAutoStart.Foreground = BrushGreen;
                _txtAutoStartDetail.Text = "计划任务 CampusNetGuard 已注册。登录 Windows 后会自动在后台运行，不用打开这个窗口。";
                _txtAutoStartDetail.Foreground = BrushGreen;
            }
            else
            {
                _txtAutoStart.Text = "未启用 —— 只能手动启动，关机后不会自动运行";
                _txtAutoStart.Foreground = BrushRed;
                _txtAutoStartDetail.Text = "还没有注册计划任务。点右边的按钮装一下（会弹 UAC），装完就开机自启；顺带会关掉 Windows 开机自动弹认证页。";
                _txtAutoStartDetail.Foreground = BrushNormal;
            }
        }

        private void InstallAutoStart()
        {
            if (ReadCredential() == null)
            {
                MessageBoxResult ask = MessageBox.Show(
                    "还没有录入账号。没有账号，自启装上也登不进去。\n\n现在录入吗？",
                    "开机自启", MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (ask == MessageBoxResult.Yes)
                {
                    SetPage(_pageAccount, _navAccount);
                }
                return;
            }

            string script = Path.Combine(_scriptDir, "install.ps1");
            if (!File.Exists(script))
            {
                MessageBox.Show("没找到 install.ps1：\n" + _scriptDir, "开机自启",
                    MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            string owner = System.Security.Principal.WindowsIdentity.GetCurrent().Name;
            string args = string.Format(
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{0}\" " +
                "-SkipPrompt -NonInteractive -Owner \"{1}\" -RuntimeDir \"{2}\"",
                script, owner, _runtimeDir);

            try
            {
                var psi = new ProcessStartInfo("powershell.exe", args)
                {
                    UseShellExecute = true,
                    Verb = "runas"
                };

                Process installer = Process.Start(psi);
                if (installer != null)
                {
                    installer.WaitForExit(90000);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("安装自启失败（可能是取消了 UAC）：\n" + ex.Message,
                    "开机自启", MessageBoxButton.OK, MessageBoxImage.Error);
                Refresh();
                return;
            }

            RefreshAutoStart();

            if (File.Exists(TaskDefinitionPath()))
            {
                MessageBox.Show(
                    "已注册开机自启。\n登录 Windows 后守护进程会自动在后台运行，不用再打开这个窗口。",
                    "开机自启", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show(
                    "注册好像没成功：没找到计划任务 CampusNetGuard。\n\n" +
                    "可以打开「任务计划程序」看看，或者以管理员身份重试一次。",
                    "开机自启", MessageBoxButton.OK, MessageBoxImage.Warning);
            }

            Refresh();
        }

        private int CurrentPid()
        {
            var state = ReadState();
            return state != null ? ToInt(state, "pid") : 0;
        }

        private bool IsGuardRunning(int pid)
        {
            if (pid <= 0) return false;
            try
            {
                var p = Process.GetProcessById(pid);
                if (p.HasExited) return false;
                string name = p.ProcessName;
                return string.Equals(name, "powershell", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(name, "pwsh", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private int FindGuardPidByWmi()
        {
            // 只缓存 5 秒，避免每 1.2 秒都查一次 WMI（那玩意儿有点重）
            if ((DateTime.Now - _cachedWmiAt).TotalSeconds < 5)
            {
                return _cachedWmiPid;
            }

            int found = 0;
            try
            {
                using (var searcher = new ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
                {
                    foreach (ManagementBaseObject item in searcher.Get())
                    {
                        string commandLine = Convert.ToString(item["CommandLine"]);
                        if (!string.IsNullOrEmpty(commandLine)
                            && commandLine.IndexOf("guard.ps1", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            found = Convert.ToInt32(item["ProcessId"]);
                            break;
                        }
                    }
                }
            }
            catch
            {
                found = 0;
            }

            _cachedWmiPid = found;
            _cachedWmiAt = DateTime.Now;
            return found;
        }

        private Dictionary<string, object> ReadState()
        {
            try
            {
                if (!File.Exists(_statePath)) return null;
                return Deserialize(File.ReadAllText(_statePath, Encoding.UTF8));
            }
            catch
            {
                return null;
            }
        }

        private static Dictionary<string, object> Deserialize(string json)
        {
            if (string.IsNullOrEmpty(json)) return null;
            json = json.TrimStart('\uFEFF');
            return new JavaScriptSerializer().DeserializeObject(json) as Dictionary<string, object>;
        }

        private static string ToStr(Dictionary<string, object> d, string key)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return "";
            return Convert.ToString(d[key]);
        }

        private static int ToInt(Dictionary<string, object> d, string key)
        {
            if (d == null || !d.ContainsKey(key) || d[key] == null) return 0;
            try
            {
                return Convert.ToInt32(d[key]);
            }
            catch
            {
                return 0;
            }
        }

        private static string Shorten(string text, int max)
        {
            if (string.IsNullOrEmpty(text)) return "";
            return text.Length <= max ? text : text.Substring(0, max) + "…";
        }

        private static string PhaseText(string phase)
        {
            switch (phase)
            {
                case "online": return "在线";
                case "paused": return "已暂停";
                case "init": return "刚启动";
                case "waiting": return "等待重试";
                case "login-failed": return "重连中";
                case "gave-up": return "已停止自动重连";
                case "rate-limited": return "尝试过于频繁";
                case "no-gateway": return "网络未连接";
                case "link-down": return "链路不通";
                case "http-suspect": return "探测异常";
                case "need-captcha": return "需要验证码";
                case "bad-credential": return "账号或密码被拒";
                case "unsupported": return "认证页不支持";
                case "no-credential": return "未录入账号";
                case "foreign-portal": return "非校园网认证页";
                default: return string.IsNullOrEmpty(phase) || phase == "unknown" ? "未知" : phase;
            }
        }

        private static Brush PhaseBrush(string phase)
        {
            switch (phase)
            {
                case "online": return BrushGreen;
                case "paused": return BrushAmber;
                case "gave-up":
                case "bad-credential":
                case "need-captcha":
                case "unsupported": return BrushRed;
                case "login-failed":
                case "waiting":
                case "rate-limited": return BrushAmber;
                default: return BrushNormal;
            }
        }

        // ---------------------------------------------------------------- 目录解析

        private static string ResolveScriptDir(string exeDir, Dictionary<string, object> cfg)
        {
            string p = ToStr(cfg, "scriptDir");
            if (!string.IsNullOrEmpty(p))
            {
                if (!Path.IsPathRooted(p)) p = Path.GetFullPath(Path.Combine(exeDir, p));
                if (File.Exists(Path.Combine(p, "guard.ps1"))) return p;
            }

            if (File.Exists(Path.Combine(exeDir, "guard.ps1"))) return exeDir;

            foreach (string name in new[] { "campus-net", "jxau-campus-net" })
            {
                string sibling = Path.GetFullPath(Path.Combine(exeDir, "..", name));
                if (File.Exists(Path.Combine(sibling, "guard.ps1"))) return sibling;
            }

            return exeDir;
        }
    }
}
