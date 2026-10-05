/// ============================================================================
//  Windows 常用指令集 · 图形工具台 —— EXE 启动器
//  作用：把全部 PowerShell 脚本作为资源嵌进单文件 EXE，运行时解包到本地目录，
//        再用 powershell.exe 以 STA + Bypass 策略启动图形界面。
//        这样用户只需要一个 exe，不需要关心脚本文件、执行策略、编码等问题。（当前内嵌 18 个文件）
//  编译：见同目录 build-exe.ps1（使用系统自带 csc.exe，无需安装任何工具）
// ============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace WinCommandToolkit
{
    internal static class Program
    {
        private const string AppTitle = "Windows 常用指令集 · 图形工具台";

        // 资源名 -> 解包后的相对路径
        // 脚本之间用相对路径互相调用，所以必须保持 scripts\ 这层目录结构
        private static readonly string[][] Payload = new string[][]
        {
            new string[] { "gui.ps1",      "图形工具台.ps1" },
            new string[] { "s01.ps1",      @"scripts\01-系统信息.ps1" },
            new string[] { "s02.ps1",      @"scripts\02-网络诊断.ps1" },
            new string[] { "s03.ps1",      @"scripts\03-端口占用.ps1" },
            new string[] { "s04.ps1",      @"scripts\04-清理临时文件.ps1" },
            new string[] { "s05.ps1",      @"scripts\05-文件夹备份.ps1" },
            new string[] { "s06.ps1",      @"scripts\06-进程服务速查.ps1" },
            new string[] { "s07.ps1",      @"scripts\07-大文件查找.ps1" },
            new string[] { "s08.ps1",      @"scripts\08-批量重命名.ps1" },
            new string[] { "s09.ps1",      @"scripts\09-文件哈希.ps1" },
            new string[] { "s10.ps1",      @"scripts\10-局域网扫描.ps1" },
            new string[] { "s11.ps1",      @"scripts\11-服务管理.ps1" },
            new string[] { "s12.ps1",      @"scripts\12-环境变量.ps1" },
            new string[] { "s13.ps1",      @"scripts\13-系统修复.ps1" },
            new string[] { "menu.ps1",     @"scripts\menu.ps1" },
            new string[] { "run.bat",      @"scripts\run.bat" },
            new string[] { "launcher.bat", "启动图形工具台.bat" },
            new string[] { "cheatsheet.md", @"docs\命令速查.md" },
            new string[] { "readme.md",    "README.md" }
        };

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();

            try
            {
                string baseDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "WinCommandToolkit", "app");
                Directory.CreateDirectory(baseDir);

                List<string> problems = new List<string>();
                Assembly asm = Assembly.GetExecutingAssembly();

                foreach (string[] item in Payload)
                {
                    try
                    {
                        string target = Path.Combine(baseDir, item[1]);
                        string folder = Path.GetDirectoryName(target);
                        if (!string.IsNullOrEmpty(folder)) Directory.CreateDirectory(folder);

                        using (Stream src = asm.GetManifestResourceStream(item[0]))
                        {
                            if (src == null) { problems.Add(item[0] + "（资源缺失）"); continue; }
                            using (FileStream dst = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.Read))
                            {
                                src.CopyTo(dst);
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        problems.Add(item[1] + " -> " + ex.Message);
                    }
                }

                // 便携模式：EXE 同目录就放着脚本时直接使用它们（方便自行改脚本，不必重新打包）
                string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                string portableGui = Path.Combine(exeDir, "图形工具台.ps1");
                string gui = File.Exists(portableGui) ? portableGui : Path.Combine(baseDir, "图形工具台.ps1");
                if (!File.Exists(gui))
                {
                    throw new FileNotFoundException(
                        "解包图形界面脚本失败：" + Environment.NewLine + gui +
                        (problems.Count > 0 ? Environment.NewLine + string.Join(Environment.NewLine, problems.ToArray()) : ""));
                }

                string psExe = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(psExe)) psExe = "powershell.exe";

                StringBuilder sb = new StringBuilder();
                sb.Append("-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File \"");
                sb.Append(gui);
                sb.Append("\"");
                foreach (string a in args)          // 透传参数，例如 -SelfTest
                {
                    sb.Append(" \"");
                    sb.Append(a.Replace("\"", ""));
                    sb.Append("\"");
                }

                ProcessStartInfo psi = new ProcessStartInfo(psExe, sb.ToString());
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;          // 不闪黑框
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                psi.WorkingDirectory = Path.GetDirectoryName(gui);

                Process.Start(psi);
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, AppTitle + " · 启动失败",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}
