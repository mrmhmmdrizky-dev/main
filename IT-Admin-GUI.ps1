
# Auto-Elevate ke Administrator jika dijalankan dari terminal user biasa
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($PSCommandPath) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    } else {
        Write-Warning "Harap jalankan PowerShell sebagai Administrator (Run as Administrator)!"
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Native Win32 Icon Extractor & Hardware Diagnostic Helpers
if (-not ([System.Management.Automation.PSTypeName]'NativeIconHelper').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public class NativeIconHelper {
    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    private static extern uint ExtractIconEx(string lpszFile, int nIconIndex, IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    public static Bitmap GetSystemBitmap(string dllName, int index, int size) {
        IntPtr[] small = new IntPtr[1];
        IntPtr[] large = new IntPtr[1];
        uint count = ExtractIconEx(dllName, index, large, small, 1);
        IntPtr hIcon = (size <= 16 && small[0] != IntPtr.Zero) ? small[0] : large[0];
        if (hIcon == IntPtr.Zero && small[0] != IntPtr.Zero) hIcon = small[0];
        if (hIcon == IntPtr.Zero) return null;

        try {
            using (Icon ico = Icon.FromHandle(hIcon)) {
                return new Bitmap(ico.ToBitmap(), new Size(size, size));
            }
        } finally {
            if (large[0] != IntPtr.Zero) DestroyIcon(large[0]);
            if (small[0] != IntPtr.Zero) DestroyIcon(small[0]);
        }
    }
}

public class WinAudioDiagHelper {
    [DllImport("winmm.dll")]
    public static extern uint waveInGetNumDevs();

    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    public static extern int mciSendString(string command, System.Text.StringBuilder buffer, int bufferSize, IntPtr hwndCallback);

    public static string SendMci(string cmd) {
        var sb = new System.Text.StringBuilder(256);
        mciSendString(cmd, sb, sb.Capacity, IntPtr.Zero);
        return sb.ToString();
    }
}

public class WinCamPreviewHelper {
    [DllImport("avicap32.dll", EntryPoint = "capCreateCaptureWindowW", CharSet = CharSet.Unicode)]
    public static extern IntPtr capCreateCaptureWindowW(string lpszWindowName, int dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hWndParent, int nID);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, int wMsg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool DestroyWindow(IntPtr hWnd);

    public const int WS_CHILD = 0x40000000;
    public const int WS_VISIBLE = 0x10000000;
    public const int WM_CAP_DRIVER_CONNECT = 0x40A;
    public const int WM_CAP_DRIVER_DISCONNECT = 0x40B;
    public const int WM_CAP_EDIT_COPY = 0x41E;
    public const int WM_CAP_GRAB_FRAME = 0x43C;
    public const int WM_CAP_SET_PREVIEW = 0x432;
    public const int WM_CAP_SET_PREVIEWRATE = 0x434;
    public const int WM_CAP_SET_SCALE = 0x435;
}
"@ -ReferencedAssemblies System.Drawing
}

$script:SysBitmapCache = @{}
function Get-WinBitmap {
    param([string]$Dll = "shell32.dll", [int]$Index = 0, [int]$Size = 16)
    $key = "${Dll}_${Index}_${Size}"
    if ($script:SysBitmapCache.ContainsKey($key)) { return $script:SysBitmapCache[$key] }
    $bmp = [NativeIconHelper]::GetSystemBitmap($Dll, $Index, $Size)
    if (-not $bmp) {
        $bmp = New-Object System.Drawing.Bitmap(([System.Drawing.SystemIcons]::Application).ToBitmap(), (New-Object System.Drawing.Size($Size, $Size)))
    }
    $script:SysBitmapCache[$key] = $bmp
    return $bmp
}

# ==============================================================================
# ASYNC HELPERS (MENCEGAH GUI FREEZE / NOT RESPONDING SAAT PROSES BERAT)
# ==============================================================================
function Invoke-AsyncTask {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [hashtable]$Parameters = @{},
        [System.Windows.Forms.Control[]]$DisableControls = @()
    )
    foreach ($ctrl in $DisableControls) { if ($ctrl) { $ctrl.Enabled = $false } }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = "STA"
        $rs.ThreadOptions = "ReuseThread"
        $rs.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($ScriptBlock)
        foreach ($k in $Parameters.Keys) {
            [void]$ps.AddParameter($k, $Parameters[$k])
        }

        $asyncResult = $ps.BeginInvoke()
        while (-not $asyncResult.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $output = $ps.EndInvoke($asyncResult)
        $ps.Dispose()
        $rs.Close()
        $rs.Dispose()
        return $output
    } finally {
        foreach ($ctrl in $DisableControls) { if ($ctrl) { $ctrl.Enabled = $true } }
    }
}

function Invoke-ProcAsync {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string]$ArgumentList = "",
        [switch]$NoNewWindow
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentList
    if ($NoNewWindow) {
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
    } else {
        $psi.UseShellExecute = $true
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { return -1 }
    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\ITAdminTools" }
if (-not (Test-Path $ScriptDir)) { New-Item -Path $ScriptDir -ItemType Directory -Force | Out-Null }

# ==============================================================================
# KONFIGURASI URL ASET ON-DEMAND (GOOGLE DRIVE DIRECT DOWNLOAD)
# ==============================================================================
$AssetUrls = @{
    "wp.png"             = "https://drive.usercontent.google.com/download?id=1H14Xk1VITUOVm88f2IJMHCSMoXYbxPiD&export=download"
    "vpn_master.conf"    = "https://drive.usercontent.google.com/download?id=1K6nBZ-Z-jNSYs1Y-e6UoJEqTlpdKhsph&export=download"
    "FortiClientVPN.exe" = "https://drive.usercontent.google.com/download?id=1uw-_ceCJneaOxgpYOBQO2QeXfeAhjcNh&export=download&confirm=t"
}

function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $prefix = switch ($Type) {
        "SUCCESS" { "[+]" }
        "ERROR"   { "[-]" }
        "WARN"    { "[!]" }
        "SKIP"    { "[SKIP]" }
        default   { "[*]" }
    }
    $txtLog.AppendText("[$timestamp] $prefix $Message`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-ToolAsset {
    param([string]$FileName)
    $localPath = Join-Path -Path $ScriptDir -ChildPath $FileName
    if (Test-Path $localPath) { return $localPath }

    $url = $AssetUrls[$FileName]
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-Log "File '$FileName' tidak ada di lokal dan URL belum diatur!" "ERROR"
        return $null
    }

    Write-Log "Mengunduh '$FileName' secara on-demand dari Google Drive ke $ScriptDir..." "INFO"
    try {
        Invoke-AsyncTask -ScriptBlock {
            param($u, $dest)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $u -OutFile $dest -UserAgent "Mozilla/5.0" -UseBasicParsing -ErrorAction Stop
        } -Parameters @{ u = $url; dest = $localPath } | Out-Null

        if (Test-Path $localPath) {
            $firstLine = Get-Content -Path $localPath -TotalCount 1 -ErrorAction SilentlyContinue
            if ($firstLine -match "<!DOCTYPE html|<html") {
                Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                Write-Log "Gagal: Google Drive mengembalikan halaman HTML (pastikan permission 'Anyone with the link')." "ERROR"
                return $null
            }
            $sizeMB = [math]::Round((Get-Item $localPath).Length / 1MB, 2)
            Write-Log "Berhasil mengunduh '$FileName' ($sizeMB MB)!" "SUCCESS"
            return $localPath
        }
    } catch {
        Write-Log "Gagal mengunduh '$FileName': $($_.Exception.Message)" "ERROR"
    }
    return $null
}

function Set-UnlockedLockScreenImage {
    param([string]$ImagePath)
    $winRtCode = @"
[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
[Windows.System.UserProfile.LockScreen,Windows.System.UserProfile,ContentType=WindowsRuntime] | Out-Null
Add-Type -AssemblyName System.Runtime.WindowsRuntime
`$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    `$_.Name -eq 'AsTask' -and `$_.GetParameters().Count -eq 1 -and `$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation``1'
})[0]
Function Await(`$WinRtTask, `$ResultType) {
    `$asTask = `$asTaskGeneric.MakeGenericMethod(`$ResultType)
    `$netTask = `$asTask.Invoke(`$null, @(`$WinRtTask))
    `$netTask.Wait(-1) | Out-Null
    `$netTask.Result
}
Function AwaitAction(`$WinRtAction) {
    `$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        `$_.Name -eq 'AsTask' -and `$_.GetParameters().Count -eq 1 -and `$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    })[0]
    `$netTask = `$asTask.Invoke(`$null, @(`$WinRtAction))
    `$netTask.Wait(-1) | Out-Null
}
`$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync('$ImagePath')) ([Windows.Storage.StorageFile])
AwaitAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync(`$file))
"@
    Invoke-ProcAsync -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$($winRtCode -replace '"','\"')`"" -NoNewWindow | Out-Null
}

function Resolve-AppIcon {
    param([string]$RawPath)
    if ([string]::IsNullOrWhiteSpace($RawPath)) { return $null }
    try {
        $clean = $RawPath.Trim()
        if ($clean -match '^"?([^"]+\.(exe|ico|dll|lnk))"?') {
            $clean = $Matches[1]
        } elseif ($clean -match '^([^\s]+\.(exe|ico|dll|lnk))') {
            $clean = $Matches[1]
        }
        $clean = [Environment]::ExpandEnvironmentVariables($clean.Trim('"'))

        if ($clean -like "*.lnk" -and (Test-Path $clean)) {
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($clean)
            if ($sc.TargetPath -and (Test-Path $sc.TargetPath)) {
                $clean = $sc.TargetPath
            }
        }

        if (Test-Path $clean -PathType Leaf) {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($clean)
            if ($ico) { return $ico.ToBitmap() }
        }
    } catch {}
    return $null
}

$script:WebIconCache = @{}
function Get-CatalogAppIcon {
    param([string]$AppName, [string]$Domain, $LocalInstalledList)
    if ($LocalInstalledList) {
        $matched = $LocalInstalledList | Where-Object { $_.DisplayName -like "*$AppName*" } | Select-Object -First 1
        if ($matched) {
            $cand = $matched.DisplayIcon
            if ([string]::IsNullOrWhiteSpace($cand) -and -not [string]::IsNullOrWhiteSpace($matched.InstallLocation) -and (Test-Path $matched.InstallLocation)) {
                $exe = Get-ChildItem -Path $matched.InstallLocation -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) { $cand = $exe.FullName }
            }
            $bmp = Resolve-AppIcon -RawPath $cand
            if ($bmp) { return (New-Object System.Drawing.Bitmap($bmp, (New-Object System.Drawing.Size(18, 18)))) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Domain)) {
        if ($script:WebIconCache.ContainsKey($Domain)) { return $script:WebIconCache[$Domain] }
        try {
            $wc = New-Object System.Net.WebClient
            $bytes = $wc.DownloadData("https://www.google.com/s2/favicons?domain=$Domain&sz=32")
            if ($bytes -and $bytes.Length -gt 0) {
                $ms = New-Object System.IO.MemoryStream(,$bytes)
                $img = [System.Drawing.Image]::FromStream($ms)
                $bmp = New-Object System.Drawing.Bitmap($img, (New-Object System.Drawing.Size(18, 18)))
                $script:WebIconCache[$Domain] = $bmp
                return $bmp
            }
        } catch {}
    }
    return $null
}

function Show-InputBox {
    param([string]$Title, [string]$Prompt, [string]$DefaultValue = "", [bool]$IsPassword = $false)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(390, 180)
    $form.StartPosition = "CenterParent"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(15, 15)
    $lbl.Size = New-Object System.Drawing.Size(345, 38)
    $form.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = $DefaultValue
    $txt.Location = New-Object System.Drawing.Point(15, 58)
    $txt.Size = New-Object System.Drawing.Size(345, 25)
    if ($IsPassword) { $txt.UseSystemPasswordChar = $true }
    $form.Controls.Add($txt)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Location = New-Object System.Drawing.Point(200, 98)
    $form.AcceptButton = $btnOk
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Batal"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object System.Drawing.Point(285, 98)
    $form.CancelButton = $btnCancel
    $form.Controls.Add($btnCancel)

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $txt.Text }
    return $null
}

function New-ActionButton {
    param(
        $Parent,
        $Text,
        $X,
        $Y,
        $W = 220,
        $H = 34,
        $Color = $null,
        [string]$IconDll = "shell32.dll",
        [int]$IconIndex = 0,
        [int]$IconSize = 16
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = " $Text"
    $btn.UseMnemonic = $false
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($W, $H)
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::LightGray
    $btn.Image = Get-WinBitmap -Dll $IconDll -Index $IconIndex -Size $IconSize
    $btn.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $btn.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $btn.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
    $btn.Padding = New-Object System.Windows.Forms.Padding(6, 0, 4, 0)

    if ($Color) {
        $btn.BackColor = $Color
        $btn.ForeColor = [System.Drawing.Color]::White
    } else {
        $btn.BackColor = [System.Drawing.Color]::White
    }
    $Parent.Controls.Add($btn)
    return $btn
}

# ==============================================================================
# DATABASE APLIKASI EMBEDDED (MURNI WINGET + DOMAIN ICON + KEYWORD DETEKSI)
# ==============================================================================
$AppCatalog = [ordered]@{
    "Browsers" = @(
        @{ Name = "Google Chrome";        Id = "Google.Chrome";                     Domain = "google.com";        Match = "Google Chrome" },
        @{ Name = "Mozilla Firefox";      Id = "Mozilla.Firefox";                   Domain = "mozilla.org";       Match = "Mozilla Firefox" },
        @{ Name = "Brave Browser";        Id = "Brave.Brave";                       Domain = "brave.com";         Match = "Brave" },
        @{ Name = "Microsoft Edge";       Id = "Microsoft.Edge";                    Domain = "microsoft.com";     Match = "Microsoft Edge" },
        @{ Name = "Vivaldi";              Id = "Vivaldi.Vivaldi";                   Domain = "vivaldi.com";       Match = "Vivaldi" },
        @{ Name = "Opera";                Id = "Opera.Opera";                       Domain = "opera.com";         Match = "Opera" },
        @{ Name = "LibreWolf";            Id = "LibreWolf.LibreWolf";               Domain = "librewolf.net";     Match = "LibreWolf" }
    )
    "Communications" = @(
        @{ Name = "WhatsApp";             Id = "9NKSQGP7F2NH";                      Domain = "whatsapp.com";      Match = "WhatsApp" },
        @{ Name = "Zoom Workplace";       Id = "Zoom.Zoom";                         Domain = "zoom.us";           Match = "Zoom" },
        @{ Name = "Microsoft Teams";      Id = "Microsoft.Teams";                   Domain = "microsoft.com";     Match = "Microsoft Teams" },
        @{ Name = "Discord";              Id = "Discord.Discord";                   Domain = "discord.com";       Match = "Discord" },
        @{ Name = "Slack";                Id = "SlackTechnologies.Slack";           Domain = "slack.com";         Match = "Slack" },
        @{ Name = "Telegram Desktop";     Id = "Telegram.TelegramDesktop";          Domain = "telegram.org";      Match = "Telegram" },
        @{ Name = "Thunderbird";          Id = "Mozilla.Thunderbird";               Domain = "thunderbird.net";   Match = "Thunderbird" }
    )
    "Document and Office" = @(
        @{ Name = "Adobe Acrobat Reader"; Id = "Adobe.Acrobat.Reader.64-bit";       Domain = "adobe.com";         Match = "Adobe Acrobat" },
        @{ Name = "Foxit PDF Reader";     Id = "Foxit.FoxitReader";                 Domain = "foxit.com";         Match = "Foxit PDF" },
        @{ Name = "SumatraPDF";           Id = "SumatraPDF.SumatraPDF";             Domain = "sumatrapdfreader.org"; Match = "SumatraPDF" },
        @{ Name = "LibreOffice";          Id = "TheDocumentFoundation.LibreOffice"; Domain = "libreoffice.org";   Match = "LibreOffice" },
        @{ Name = "OnlyOffice Desktop";   Id = "ONLYOFFICE.DesktopEditors";         Domain = "onlyoffice.com";    Match = "ONLYOFFICE" },
        @{ Name = "WPS Office";           Id = "Kingsoft.WPSOffice";                Domain = "wps.com";           Match = "WPS Office" },
        @{ Name = "Notepad++";            Id = "Notepad++.Notepad++";               Domain = "notepad-plus-plus.org"; Match = "Notepad++" },
        @{ Name = "Obsidian";             Id = "Obsidian.Obsidian";                 Domain = "obsidian.md";       Match = "Obsidian" }
    )
    "Utilities and Remote" = @(
        @{ Name = "7-Zip";                Id = "7zip.7zip";                         Domain = "7-zip.org";         Match = "7-Zip" },
        @{ Name = "WinRAR";               Id = "RARLab.WinRAR";                     Domain = "win-rar.com";       Match = "WinRAR" },
        @{ Name = "AnyDesk";              Id = "AnyDeskSoftwareGmbH.AnyDesk";       Domain = "anydesk.com";       Match = "AnyDesk" },
        @{ Name = "RustDesk";             Id = "RustDesk.RustDesk";                 Domain = "rustdesk.com";      Match = "RustDesk" },
        @{ Name = "TeamViewer";           Id = "TeamViewer.TeamViewer";             Domain = "teamviewer.com";    Match = "TeamViewer" },
        @{ Name = "Google Drive";         Id = "Google.GoogleDrive";                Domain = "drive.google.com";  Match = "Google Drive" },
        @{ Name = "Microsoft PowerToys";  Id = "Microsoft.PowerToys";               Domain = "microsoft.com";     Match = "PowerToys" },
        @{ Name = "Everything Search";    Id = "voidtools.Everything";              Domain = "voidtools.com";     Match = "Everything" },
        @{ Name = "Revo Uninstaller";     Id = "RevoUninstaller.RevoUninstaller";   Domain = "revouninstaller.com"; Match = "Revo Uninstaller" },
        @{ Name = "WizTree (Disk Space)"; Id = "AntibodySoftware.WizTree";          Domain = "diskanalyzer.com";  Match = "WizTree" },
        @{ Name = "Rufus";                Id = "Rufus.Rufus";                       Domain = "rufus.ie";          Match = "Rufus" },
        @{ Name = "CPU-Z";                Id = "CPUID.CPU-Z";                       Domain = "cpuid.com";         Match = "CPU-Z" },
        @{ Name = "CrystalDiskInfo";      Id = "CrystalDewWorld.CrystalDiskInfo";   Domain = "crystalmark.info";  Match = "CrystalDiskInfo" }
    )
    "Multimedia and Graphics" = @(
        @{ Name = "VLC Media Player";     Id = "VideoLAN.VLC";                      Domain = "videolan.org";      Match = "VLC media player" },
        @{ Name = "MPC-HC";               Id = "clsid2.mpc-hc";                     Domain = "github.com";        Match = "MPC-HC" },
        @{ Name = "ShareX";               Id = "ShareX.ShareX";                     Domain = "getsharex.com";     Match = "ShareX" },
        @{ Name = "Greenshot";            Id = "Greenshot.Greenshot";               Domain = "getgreenshot.org";  Match = "Greenshot" },
        @{ Name = "GIMP";                 Id = "GIMP.GIMP";                         Domain = "gimp.org";          Match = "GIMP" },
        @{ Name = "Paint.NET";            Id = "dotPDN.PaintDotNet";                Domain = "getpaint.net";      Match = "paint.net" },
        @{ Name = "OBS Studio";           Id = "OBSProject.OBSStudio";              Domain = "obsproject.com";    Match = "OBS Studio" },
        @{ Name = "HandBrake";            Id = "HandBrake.HandBrake";               Domain = "handbrake.fr";      Match = "HandBrake" }
    )
    "Runtimes and Frameworks" = @(
        @{ Name = "VC++ Redist AIO";      Id = "abbodi1406.vcredist";               Domain = "microsoft.com";     Match = "Microsoft Visual C++" },
        @{ Name = ".NET Desktop 8";       Id = "Microsoft.DotNet.DesktopRuntime.8"; Domain = "dotnet.microsoft.com"; Match = "Microsoft Windows Desktop Runtime - 8" },
        @{ Name = ".NET Desktop 6";       Id = "Microsoft.DotNet.DesktopRuntime.6"; Domain = "dotnet.microsoft.com"; Match = "Microsoft Windows Desktop Runtime - 6" },
        @{ Name = "DirectX Runtime";      Id = "Microsoft.DirectX";                 Domain = "microsoft.com";     Match = "DirectX" },
        @{ Name = "Java 21 JRE (Temurin)";Id = "EclipseAdoptium.Temurin.21.JRE";    Domain = "adoptium.net";      Match = "Eclipse Temurin JRE" }
    )
    "Pro Tools and Network" = @(
        @{ Name = "Git";                  Id = "Git.Git";                           Domain = "git-scm.com";       Match = "Git" },
        @{ Name = "VS Code";              Id = "Microsoft.VisualStudioCode";        Domain = "code.visualstudio.com"; Match = "Visual Studio Code" },
        @{ Name = "Python 3.12";          Id = "Python.Python.3.12";                Domain = "python.org";        Match = "Python 3.12" },
        @{ Name = "PuTTY";                Id = "PuTTY.PuTTY";                       Domain = "putty.org";         Match = "PuTTY" },
        @{ Name = "WinSCP";               Id = "WinSCP.WinSCP";                     Domain = "winscp.net";        Match = "WinSCP" },
        @{ Name = "Advanced IP Scanner";  Id = "Famatech.AdvancedIPScanner";        Domain = "advanced-ip-scanner.com"; Match = "Advanced IP Scanner" },
        @{ Name = "Wireshark";            Id = "WiresharkFoundation.Wireshark";     Domain = "wireshark.org";     Match = "Wireshark" },
        @{ Name = "Tailscale VPN";        Id = "Tailscale.Tailscale";               Domain = "tailscale.com";     Match = "Tailscale" }
    )
}

# --- FORM UTAMA (RESIZABLE & MAXIMIZABLE) ---
$MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = "IT Administration and ISO Compliance Suite v7.33"
$MainForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$MainForm.ClientSize = New-Object System.Drawing.Size(1104, 735)
$MainForm.StartPosition = "CenterScreen"
$MainForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$MainForm.MaximizeBox = $false
$MainForm.MinimizeBox = $true
$MainForm.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$MainForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$HeaderPanel = New-Object System.Windows.Forms.Panel
$HeaderPanel.Dock = "Top"
$HeaderPanel.Height = 50
$HeaderPanel.BackColor = [System.Drawing.Color]::FromArgb(24, 34, 56)
$MainForm.Controls.Add($HeaderPanel)

$PicHeader = New-Object System.Windows.Forms.PictureBox
$PicHeader.Location = New-Object System.Drawing.Point(14, 11)
$PicHeader.Size = New-Object System.Drawing.Size(28, 28)
$PicHeader.SizeMode = "StretchImage"
$PicHeader.Image = Get-WinBitmap -Dll "imageres.dll" -Index 102 -Size 28
$HeaderPanel.Controls.Add($PicHeader)

$LblTitle = New-Object System.Windows.Forms.Label
$LblTitle.Text = "IT ADMINISTRATION, WINUTIL AND ISO COMPLIANCE SUITE v7.33"
$LblTitle.ForeColor = [System.Drawing.Color]::White
$LblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)
$LblTitle.Location = New-Object System.Drawing.Point(50, 13)
$LblTitle.AutoSize = $true
$HeaderPanel.Controls.Add($LblTitle)

# ImageList untuk Tab Header (9 Tab Lengkap)
$TabImageList = New-Object System.Windows.Forms.ImageList
$TabImageList.ImageSize = New-Object System.Drawing.Size(16, 16)
$TabImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$TabImageList.Images.Add("apps",    (Get-WinBitmap -Dll "shell32.dll"  -Index 162 -Size 16))
$TabImageList.Images.Add("tweaks",  (Get-WinBitmap -Dll "imageres.dll" -Index 109 -Size 16))
$TabImageList.Images.Add("config",  (Get-WinBitmap -Dll "shell32.dll"  -Index 21  -Size 16))
$TabImageList.Images.Add("admin",   (Get-WinBitmap -Dll "imageres.dll" -Index 73  -Size 16))
$TabImageList.Images.Add("iso",     (Get-WinBitmap -Dll "imageres.dll" -Index 101 -Size 16))
$TabImageList.Images.Add("manage",  (Get-WinBitmap -Dll "shell32.dll"  -Index 13  -Size 16))
$TabImageList.Images.Add("driver",  (Get-WinBitmap -Dll "devmgr.dll"   -Index 4   -Size 16))
$TabImageList.Images.Add("trouble", (Get-WinBitmap -Dll "imageres.dll" -Index 102 -Size 16))
$TabImageList.Images.Add("hwscan",  (Get-WinBitmap -Dll "shell32.dll"  -Index 15  -Size 16))

$TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Location = New-Object System.Drawing.Point(12, 58)
$TabControl.Size = New-Object System.Drawing.Size(1080, 498)
$TabControl.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$TabControl.ImageList = $TabImageList
$TabControl.Multiline = $false
$TabControl.Padding = New-Object System.Drawing.Point(3, 4)
$MainForm.Controls.Add($TabControl)

$LblLog = New-Object System.Windows.Forms.Label
$LblLog.Text = "Log Eksekusi dan Output Real-Time:"
$LblLog.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$LblLog.Location = New-Object System.Drawing.Point(14, 570)
$LblLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$LblLog.AutoSize = $true
$MainForm.Controls.Add($LblLog)

$BtnClearLog = New-ActionButton $MainForm "Bersihkan Log" 968 566 124 25 $null "shell32.dll" 31 14
$BtnClearLog.Font = New-Object System.Drawing.Font("Segoe UI", 8.2)
$BtnClearLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$BtnClearLog.Add_Click({ $txtLog.Clear() })

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Location = New-Object System.Drawing.Point(12, 595)
$txtLog.Size = New-Object System.Drawing.Size(1080, 126)
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 31)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(80, 250, 123)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$MainForm.Controls.Add($txtLog)

# ==============================================================================
# TAB 1: INSTALL / UPGRADE APPLICATIONS (GAYA CTT WINUTIL - TOP TOOLBAR)
# ==============================================================================
$TabApps = New-Object System.Windows.Forms.TabPage
$TabApps.Text = "Apps"
$TabApps.ImageKey = "apps"
$TabApps.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabApps)

$AppsTopBar = New-Object System.Windows.Forms.Panel
$AppsTopBar.Dock = [System.Windows.Forms.DockStyle]::Top
$AppsTopBar.Height = 76
$AppsTopBar.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabApps.Controls.Add($AppsTopBar)

# Baris 1 TopBar: Tombol Aksi Utama (Mirip Baris Tombol Atas CTT WinUtil)
$btnInstallSel = New-ActionButton $AppsTopBar "Install / Upgrade Selected" 10 6 215 32 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 162 15
$btnInstallSel.Font = New-Object System.Drawing.Font("Segoe UI", 8.8, [System.Drawing.FontStyle]::Bold)
$btnInstallSel.Add_Click({
    $selected = $AllAppCheckboxes | Where-Object { $_.Checked }
    if ($selected.Count -eq 0) { Write-Log "Centang minimal 1 aplikasi terlebih dahulu!" "WARN"; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Log "Winget tidak ditemukan di PC ini!" "ERROR"; return }

    $btnInstallSel.Enabled = $false
    $btnUpgradeAll.Enabled = $false
    try {
        Write-Log "Memulai Install / Upgrade $($selected.Count) aplikasi terpilih (GUI tetap aktif)..." "INFO"
        $idx = 0
        foreach ($cb in $selected) {
            $idx++
            $info = $cb.Tag
            $name = $info.Name
            $id   = $info.Id
            $verb = if ($info.Status -eq "UpdateAvailable") { "upgrade" } else { "install" }
            Write-Log "[$idx/$($selected.Count)] Memproses $name [$id] ($verb)..." "INFO"

            $exitCode = Invoke-ProcAsync -FilePath "winget" -ArgumentList "$verb --id `"$id`" --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow
            if ($exitCode -eq 0 -or $exitCode -eq -1978335189) {
                Write-Log "$name berhasil diproses / sudah versi terbaru." "SUCCESS"
            } else {
                Write-Log "$name selesai dengan exit code: $exitCode" "WARN"
            }
            $cb.Checked = $false
        }
        Write-Log "Memperbarui label status aplikasi..." "INFO"
        Refresh-AppInstallStates -CheckWingetUpdates $true
        Build-AppsUI -Filter $TxtSearchApp.Text.Trim()
    } finally {
        $btnInstallSel.Enabled = $true
        $btnUpgradeAll.Enabled = $true
    }
})

$btnUpgradeAll = New-ActionButton $AppsTopBar "Upgrade All Applications" 232 6 190 32 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 46 15
$btnUpgradeAll.Add_Click({
    Start-Process "cmd.exe" -ArgumentList "/c winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements"
})

$btnCheckAppStat = New-ActionButton $AppsTopBar "Cek Status & Update" 429 6 170 32 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "shell32.dll" 238 15
$btnCheckAppStat.Add_Click({
    Refresh-AppInstallStates -CheckWingetUpdates $true
    Build-AppsUI -Filter $TxtSearchApp.Text.Trim()
})

$btnPresetOffice = New-ActionButton $AppsTopBar "Preset Laptop Kantor" 606 6 170 32 $null "shell32.dll" 15 15
$btnPresetOffice.Add_Click({
    $defs = @("Google Chrome", "WhatsApp", "WinRAR", "7-Zip", "Adobe Acrobat Reader", "AnyDesk", "Google Drive")
    $AllAppCheckboxes | ForEach-Object {
        $info = $_.Tag
        $_.Checked = ($defs -contains $info.Name) -and ($info.Status -ne "Installed")
    }
    Write-Log "Preset Laptop Kantor dicentang (hanya yang belum terpasang / butuh update)." "INFO"
})

$btnClearApps = New-ActionButton $AppsTopBar "Clear Selection" 783 6 140 32 $null "shell32.dll" 131 15
$btnClearApps.Add_Click({ $AllAppCheckboxes | ForEach-Object { $_.Checked = $false } })

# Baris 2 TopBar: Pencarian, Filter Status & Statistik Ringkas
$LblSearch = New-Object System.Windows.Forms.Label
$LblSearch.Text = "Cari:"
$LblSearch.Location = New-Object System.Drawing.Point(10, 48)
$LblSearch.AutoSize = $true
$AppsTopBar.Controls.Add($LblSearch)

$TxtSearchApp = New-Object System.Windows.Forms.TextBox
$TxtSearchApp.Location = New-Object System.Drawing.Point(46, 45)
$TxtSearchApp.Size = New-Object System.Drawing.Size(200, 23)
$AppsTopBar.Controls.Add($TxtSearchApp)

$LblFilterStatus = New-Object System.Windows.Forms.Label
$LblFilterStatus.Text = "Filter Status:"
$LblFilterStatus.Location = New-Object System.Drawing.Point(256, 48)
$LblFilterStatus.AutoSize = $true
$AppsTopBar.Controls.Add($LblFilterStatus)

$CmbStatusFilter = New-Object System.Windows.Forms.ComboBox
$CmbStatusFilter.Location = New-Object System.Drawing.Point(334, 45)
$CmbStatusFilter.Size = New-Object System.Drawing.Size(150, 23)
$CmbStatusFilter.DropDownStyle = "DropDownList"
$CmbStatusFilter.Items.AddRange(@("Semua Aplikasi", "Update Tersedia", "Belum Terinstall", "Sudah Terinstall"))
$CmbStatusFilter.SelectedIndex = 0
$AppsTopBar.Controls.Add($CmbStatusFilter)

$LblAppCount = New-Object System.Windows.Forms.Label
$LblAppCount.Text = "Memindai status aplikasi di background..."
$LblAppCount.ForeColor = [System.Drawing.Color]::DimGray
$LblAppCount.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$LblAppCount.Location = New-Object System.Drawing.Point(496, 48)
$LblAppCount.AutoSize = $true
$AppsTopBar.Controls.Add($LblAppCount)

# Area Daftar Aplikasi (Dock = Fill agar otomatis mengisi seluruh sisa layar)
$AppFlowPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$AppFlowPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$AppFlowPanel.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 6)
$AppFlowPanel.AutoScroll = $true
$AppFlowPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$AppFlowPanel.WrapContents = $true
$AppFlowPanel.Add_MouseEnter({ $AppFlowPanel.Focus() })
$TabApps.Controls.Add($AppFlowPanel)
$AppFlowPanel.BringToFront()

$AllAppCheckboxes = New-Object System.Collections.Generic.List[System.Windows.Forms.CheckBox]
$script:AppStatusMap = @{}
$script:LocalRegApps = @()
$script:WingetUpgradeIds = @()

function Refresh-AppInstallStates {
    param([bool]$CheckWingetUpdates = $true)
    Write-Log "Memindai status aplikasi terinstal dan ketersediaan update (Async)..." "INFO"

    $scanRes = Invoke-AsyncTask -ScriptBlock {
        param($Catalog, $DoWinget)
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $localReg = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.DisplayName)
        } | Select-Object DisplayName, DisplayIcon, InstallLocation

        $appxNames = (Get-AppxPackage -ErrorAction SilentlyContinue).Name

        $upgIds = @()
        $wingetRaw = ""
        if ($DoWinget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            try {
                $upgOut = winget upgrade --include-unknown --accept-source-agreements 2>$null | Out-String
                foreach ($cat in $Catalog.Keys) {
                    foreach ($item in $Catalog[$cat]) {
                        if ($upgOut -match [regex]::Escape($item.Id)) {
                            $upgIds += $item.Id
                        }
                    }
                }
                $wingetRaw = winget list --accept-source-agreements 2>$null | Out-String
            } catch {}
        }

        $statusMap = @{}
        foreach ($cat in $Catalog.Keys) {
            foreach ($item in $Catalog[$cat]) {
                $id = $item.Id
                $kw = $item.Match
                $isInstalled = $false
                if ($localReg | Where-Object { $_.DisplayName -like "*$kw*" }) {
                    $isInstalled = $true
                } elseif ($appxNames | Where-Object { $_ -like "*$kw*" }) {
                    $isInstalled = $true
                } elseif ($wingetRaw -and ($wingetRaw -match [regex]::Escape($id))) {
                    $isInstalled = $true
                }

                if ($upgIds -contains $id) {
                    $statusMap[$id] = "UpdateAvailable"
                } elseif ($isInstalled) {
                    $statusMap[$id] = "Installed"
                } else {
                    $statusMap[$id] = "NotInstalled"
                }
            }
        }
        return [PSCustomObject]@{
            LocalReg   = $localReg
            UpgradeIds = $upgIds
            StatusMap  = $statusMap
        }
    } -Parameters @{ Catalog = $AppCatalog; DoWinget = $CheckWingetUpdates } -DisableControls @($btnCheckAppStat)

    if ($scanRes) {
        $script:LocalRegApps     = $scanRes.LocalReg
        $script:WingetUpgradeIds = $scanRes.UpgradeIds
        $script:AppStatusMap     = $scanRes.StatusMap
    }
    Write-Log "Pemindaian status aplikasi selesai!" "SUCCESS"
}

function Build-AppsUI {
    param([string]$Filter = "")
    $statusFilter = if ($CmbStatusFilter.SelectedItem) { $CmbStatusFilter.SelectedItem.ToString() } else { "Semua Aplikasi" }

    $AppFlowPanel.SuspendLayout()
    $AppFlowPanel.Controls.Clear()
    $AllAppCheckboxes.Clear()

    $cntInstalled = 0
    $cntUpdate    = 0
    $cntNotInst   = 0

    foreach ($catName in $AppCatalog.Keys) {
        $items = @()
        foreach ($it in $AppCatalog[$catName]) {
            $st = if ($script:AppStatusMap.ContainsKey($it.Id)) { $script:AppStatusMap[$it.Id] } else { "NotInstalled" }

            if ($Filter -and ($it.Name -notlike "*$Filter*") -and ($catName -notlike "*$Filter*")) { continue }
            if ($statusFilter -eq "Update Tersedia" -and $st -ne "UpdateAvailable") { continue }
            if ($statusFilter -eq "Belum Terinstall" -and $st -ne "NotInstalled") { continue }
            if ($statusFilter -eq "Sudah Terinstall" -and $st -ne "Installed") { continue }

            $items += $it
        }
        if ($items.Count -eq 0) { continue }

        $boxH = [math]::Max(64, ($items.Count * 26) + 32)
        $grp = New-Object System.Windows.Forms.GroupBox
        $grp.Text = "$catName ($($items.Count))"
        $grp.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
        $grp.Size = New-Object System.Drawing.Size(336, $boxH)
        $grp.Margin = New-Object System.Windows.Forms.Padding(4)

        $iy = 22
        foreach ($it in $items) {
            $st = if ($script:AppStatusMap.ContainsKey($it.Id)) { $script:AppStatusMap[$it.Id] } else { "NotInstalled" }

            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $it.Name
            $cb.Tag = @{ Id = $it.Id; Name = $it.Name; Status = $st }
            $cb.Font = New-Object System.Drawing.Font("Segoe UI", 8.3)
            $cb.Location = New-Object System.Drawing.Point(8, $iy)
            $cb.Size = New-Object System.Drawing.Size(202, 22)
            $grp.Controls.Add($cb)
            $AllAppCheckboxes.Add($cb)

            $pb = New-Object System.Windows.Forms.PictureBox
            $pb.Location = New-Object System.Drawing.Point(212, ($iy + 2))
            $pb.Size = New-Object System.Drawing.Size(18, 18)
            $pb.SizeMode = "StretchImage"
            $bmp = Get-CatalogAppIcon -AppName $it.Match -Domain $it.Domain -LocalInstalledList $script:LocalRegApps
            if ($bmp) {
                $pb.Image = $bmp
            } else {
                $pb.Image = ([System.Drawing.SystemIcons]::Application).ToBitmap()
            }
            $grp.Controls.Add($pb)

            $lblBadge = New-Object System.Windows.Forms.Label
            $lblBadge.Location = New-Object System.Drawing.Point(235, ($iy + 2))
            $lblBadge.Size = New-Object System.Drawing.Size(92, 18)
            $lblBadge.TextAlign = "MiddleCenter"
            $lblBadge.Font = New-Object System.Drawing.Font("Segoe UI", 7.2, [System.Drawing.FontStyle]::Bold)

            switch ($st) {
                "Installed" {
                    $lblBadge.Text = "Terpasang"
                    $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(212, 239, 223)
                    $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(20, 90, 50)
                    $cntInstalled++
                }
                "UpdateAvailable" {
                    $lblBadge.Text = "Update Baru"
                    $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(253, 235, 208)
                    $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(156, 100, 12)
                    $cntUpdate++
                }
                default {
                    $lblBadge.Text = "Belum"
                    $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(234, 236, 238)
                    $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(86, 101, 115)
                    $cntNotInst++
                }
            }
            $grp.Controls.Add($lblBadge)

            $iy += 26
        }
        $grp.Add_MouseEnter({ $AppFlowPanel.Focus() })
        $AppFlowPanel.Controls.Add($grp)
        [System.Windows.Forms.Application]::DoEvents()
    }

    $LblAppCount.Text = "Terpasang: $cntInstalled | Update Baru: $cntUpdate | Belum: $cntNotInst"
    $AppFlowPanel.ResumeLayout()
}

$TxtSearchApp.Add_TextChanged({ Build-AppsUI -Filter $TxtSearchApp.Text.Trim() })
$CmbStatusFilter.Add_SelectedIndexChanged({ Build-AppsUI -Filter $TxtSearchApp.Text.Trim() })
# TAB 2: TWEAKS (GAYA CTT WINUTIL - TOP PRESET & ACTION TOOLBAR)
# ==============================================================================
$TabTweaks = New-Object System.Windows.Forms.TabPage
$TabTweaks.Text = "Tweaks"
$TabTweaks.ImageKey = "tweaks"
$TabTweaks.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabTweaks)

$TweaksTopBar = New-Object System.Windows.Forms.Panel
$TweaksTopBar.Dock = [System.Windows.Forms.DockStyle]::Top
$TweaksTopBar.Height = 46
$TweaksTopBar.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabTweaks.Controls.Add($TweaksTopBar)

$LblTweakPreset = New-Object System.Windows.Forms.Label
$LblTweakPreset.Text = "Recommended Selections:"
$LblTweakPreset.Font = New-Object System.Drawing.Font("Segoe UI", 8.8, [System.Drawing.FontStyle]::Bold)
$LblTweakPreset.Location = New-Object System.Drawing.Point(10, 14)
$LblTweakPreset.AutoSize = $true
$TweaksTopBar.Controls.Add($LblTweakPreset)

$btnStandardPreset = New-ActionButton $TweaksTopBar "Standard" 165 7 125 32 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 43 15
$btnStandardPreset.Add_Click({
    $std = @("RestorePoint","DebloatEdge","DisableTelemetry","DisableActivityHistory","DisableLocation","DisableConsumerFeatures","DisableRecall","SetServicesManual","DeleteTempFiles","BingSearch","RemoveWidgets","ShowExt","StickyKeys")
    $AllTweakCheckboxes | ForEach-Object { $_.Checked = ($std -contains $_.Tag) }
    Write-Log "Preset Standard dipilih." "INFO"
})

$btnMinimalPreset = New-ActionButton $TweaksTopBar "Minimal" 297 7 115 32 $null "shell32.dll" 134 15
$btnMinimalPreset.Add_Click({
    $min = @("RestorePoint","DisableTelemetry","DeleteTempFiles","ShowExt","StickyKeys")
    $AllTweakCheckboxes | ForEach-Object { $_.Checked = ($min -contains $_.Tag) }
    Write-Log "Preset Minimal dipilih." "INFO"
})

$btnClearTweaks = New-ActionButton $TweaksTopBar "Clear" 419 7 100 32 $null "shell32.dll" 131 15
$btnClearTweaks.Add_Click({ $AllTweakCheckboxes | ForEach-Object { $_.Checked = $false } })

$btnRunTweaks = New-ActionButton $TweaksTopBar "Run Tweaks" 532 7 165 32 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 109 15
$btnRunTweaks.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnRunTweaks.Add_Click({
    $sel = $AllTweakCheckboxes | Where-Object { $_.Checked }
    if ($sel.Count -eq 0) { Write-Log "Pilih minimal 1 tweak terlebih dahulu!" "WARN"; return }

    $btnRunTweaks.Enabled = $false
    try {
        foreach ($cb in $sel) {
            [System.Windows.Forms.Application]::DoEvents()
            try {
                switch ($cb.Tag) {
                    "RestorePoint" {
                        Invoke-AsyncTask -ScriptBlock {
                            Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
                            Checkpoint-Computer -Description "WinUtil_ITAdmin" -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue
                        } | Out-Null
                    }
                    "DebloatEdge" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "HubsSidebarEnabled" 0 -Type DWORD
                        Set-ItemProperty $p "EdgeShoppingAssistantEnabled" 0 -Type DWORD
                    }
                    "DisableTelemetry" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "AllowTelemetry" 0 -Type DWORD
                        Stop-Service "DiagTrack" -Force -ErrorAction SilentlyContinue; Set-Service "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
                    }
                    "DisableActivityHistory" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "EnableActivityFeed" 0 -Type DWORD; Set-ItemProperty $p "PublishUserActivities" 0 -Type DWORD
                    }
                    "DisableLocation" {
                        $p = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "Value" "Deny" -Type String
                    }
                    "DisableStorageSense" {
                        $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "01" 0 -Type DWORD
                    }
                    "DisableHibernation" { powercfg.exe /hibernate off }
                    "DisableConsumerFeatures" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "DisableWindowsConsumerFeatures" 1 -Type DWORD
                    }
                    "DisableRecall" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "TurnOffWindowsCopilot" 1 -Type DWORD
                    }
                    "DisableGameDVR" {
                        $p = "HKCU:\System\GameConfigStore"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p "GameDVR_Enabled" 0 -Type DWORD
                    }
                    "SetServicesManual" { @("MapsBroker","RetailDemo","Fax","WMPNetworkSvc") | ForEach-Object { Set-Service $_ -StartupType Manual -ErrorAction SilentlyContinue } }
                    "DeleteTempFiles" {
                        Invoke-AsyncTask -ScriptBlock {
                            @($env:TEMP,"C:\Windows\Temp") | ForEach-Object { if (Test-Path $_) { Get-ChildItem $_ -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }
                        } | Out-Null
                    }
                    "DiskCleanup" { Start-Process "cleanmgr.exe" -ArgumentList "/verylowdisk" }
                    "UltimatePerf" { powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null | Out-Null; powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
                    "DarkMode" { $p="HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Set-ItemProperty $p "AppsUseLightTheme" 0 -Type DWORD; Set-ItemProperty $p "SystemUsesLightTheme" 0 -Type DWORD }
                    "BingSearch" { $p="HKCU:\Software\Policies\Microsoft\Windows\Explorer"; if(!(Test-Path $p)){New-Item $p -Force|Out-Null}; Set-ItemProperty $p "DisableSearchBoxSuggestions" 1 -Type DWORD }
                    "NumLock" { Set-ItemProperty "Registry::HKU\.DEFAULT\Control Panel\Keyboard" "InitialKeyboardIndicators" "2" -Type String }
                    "VerboseLogon" { Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "VerboseStatus" 1 -Type DWORD }
                    "RemoveWidgets" { $p="HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; if(!(Test-Path $p)){New-Item $p -Force|Out-Null}; Set-ItemProperty $p "AllowNewsAndInterests" 0 -Type DWORD }
                    "RemoveCopilotBtn" { Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0 -Type DWORD }
                    "TaskbarEndTask" { $p="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; if(!(Test-Path $p)){New-Item $p -Force|Out-Null}; Set-ItemProperty $p "TaskbarEndTask" 1 -Type DWORD }
                    "ClassicContext" { New-Item "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" -Value "" -Force | Out-Null }
                    "ShowHidden" { Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Hidden" 1 -Type DWORD }
                    "ShowExt" { Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" 0 -Type DWORD }
                    "StickyKeys" { Set-ItemProperty "HKCU:\Control Panel\Accessibility\StickyKeys" "Flags" "506" -Type String }
                    "SnapWindow" { Set-ItemProperty "HKCU:\Control Panel\Desktop" "WindowArrangementActive" "0" -Type String }
                    "MouseAccel" { Set-ItemProperty "HKCU:\Control Panel\Mouse" "MouseSpeed" "0" -Type String; Set-ItemProperty "HKCU:\Control Panel\Mouse" "MouseThreshold1" "0" -Type String; Set-ItemProperty "HKCU:\Control Panel\Mouse" "MouseThreshold2" "0" -Type String }
                    "VisualFX" { $v="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; if(!(Test-Path $v)){New-Item $v -Force|Out-Null}; Set-ItemProperty $v "VisualFXSetting" 3 -Type DWORD }
                    "DisableIPv6" { Disable-NetAdapterBinding -Name "*" -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue }
                    "DisableTeredo" { netsh interface teredo set state disabled | Out-Null }
                    "BlockAdobeNet" { Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "`n0.0.0.0 ic.adobe.io`n0.0.0.0 cc-api-data.adobe.io" -ErrorAction SilentlyContinue }
                    "DisableWifiSense" { $p="HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config"; if(!(Test-Path $p)){New-Item $p -Force|Out-Null}; Set-ItemProperty $p "AutoConnectAllowedOEM" 0 -Type DWORD }
                    "EnableUAC" { Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "ConsentPromptBehaviorAdmin" 5 -Type DWORD }
                }
                Write-Log "Tweak diterapkan: $($cb.Text)" "SUCCESS"
            } catch { Write-Log "Gagal tweak $($cb.Text): $($_.Exception.Message)" "ERROR" }
        }
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Write-Log "Semua tweak selesai dijalankan!" "SUCCESS"
    } finally {
        $btnRunTweaks.Enabled = $true
    }
})

$TweakFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$TweakFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$TweakFlow.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 6)
$TweakFlow.AutoScroll = $true
$TweakFlow.Add_MouseEnter({ $TweakFlow.Focus() })
$TabTweaks.Controls.Add($TweakFlow)
$TweakFlow.BringToFront()

$AllTweakCheckboxes = New-Object System.Collections.Generic.List[System.Windows.Forms.CheckBox]

$CTTTweaksMap = [ordered]@{
    "Essential Tweaks (Rekomendasi Utama)" = @(
        @{ Id="RestorePoint"; Name="Create Restore Point (Backup sebelum tweak)" },
        @{ Id="DebloatEdge"; Name="Debloat Microsoft Edge (Disable Telemetry)" },
        @{ Id="DisableTelemetry"; Name="Disable Telemetry and DiagTrack Service" },
        @{ Id="DisableActivityHistory"; Name="Disable Activity History" },
        @{ Id="DisableLocation"; Name="Disable Location Tracking" },
        @{ Id="DisableStorageSense"; Name="Disable Storage Sense" },
        @{ Id="DisableHibernation"; Name="Disable Hibernation (Hemat GB di SSD)" },
        @{ Id="DisableConsumerFeatures"; Name="Disable ConsumerFeatures (Stop Auto-Install App)" },
        @{ Id="DisableRecall"; Name="Disable Windows Copilot and AI Recall" },
        @{ Id="DisableGameDVR"; Name="Disable GameDVR and Xbox Recording" },
        @{ Id="SetServicesManual"; Name="Set Non-Essential Services to Manual" },
        @{ Id="DeleteTempFiles"; Name="Delete Temporary Files (User and Windows Temp)" },
        @{ Id="DiskCleanup"; Name="Run Disk Cleanup (cleanmgr)" },
        @{ Id="UltimatePerf"; Name="Add and Activate Ultimate Performance Profile" }
    )
    "Customize Preferences and UI Tweaks" = @(
        @{ Id="DarkMode"; Name="Dark Theme for Windows and Apps" },
        @{ Id="BingSearch"; Name="Disable Bing Search in Start Menu" },
        @{ Id="NumLock"; Name="Enable NumLock on Startup" },
        @{ Id="VerboseLogon"; Name="Enable Detailed Boot and Logon Messages" },
        @{ Id="RemoveWidgets"; Name="Remove News and Interests / Widgets" },
        @{ Id="RemoveCopilotBtn"; Name="Remove Copilot Button from Taskbar" },
        @{ Id="TaskbarEndTask"; Name="Enable 'End Task' on Taskbar Right-Click (Win11)" },
        @{ Id="ClassicContext"; Name="Set Classic Right-Click Menu (Windows 11)" },
        @{ Id="ShowHidden"; Name="Show Hidden Files and Folders" },
        @{ Id="ShowExt"; Name="Show File Extensions for Known File Types" },
        @{ Id="StickyKeys"; Name="Disable Sticky Keys Prompt" },
        @{ Id="SnapWindow"; Name="Disable Window Snapping Flyout" },
        @{ Id="MouseAccel"; Name="Disable Mouse Acceleration (1:1 Raw Input)" },
        @{ Id="VisualFX"; Name="Set Visual Effects to Best Performance" }
    )
    "Security and Network Tweaks" = @(
        @{ Id="DisableIPv6"; Name="Disable IPv6 (Prefer IPv4)" },
        @{ Id="DisableTeredo"; Name="Disable Teredo Tunneling" },
        @{ Id="BlockAdobeNet"; Name="Block Adobe Telemetry in Hosts File" },
        @{ Id="DisableWifiSense"; Name="Disable Wi-Fi Sense Auto-Connect" },
        @{ Id="EnableUAC"; Name="Set UAC to Default Secure Level" }
    )
}

foreach ($cat in $CTTTweaksMap.Keys) {
    $items = $CTTTweaksMap[$cat]
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = $cat
    $grp.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $grp.Size = New-Object System.Drawing.Size(336, 376)
    $grp.Margin = New-Object System.Windows.Forms.Padding(5)

    $ty = 24
    foreach ($tw in $items) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $tw.Name
        $cb.Tag = $tw.Id
        $cb.Font = New-Object System.Drawing.Font("Segoe UI", 8.2)
        $cb.Location = New-Object System.Drawing.Point(10, $ty)
        $cb.Size = New-Object System.Drawing.Size(318, 22)
        $grp.Controls.Add($cb)
        $AllTweakCheckboxes.Add($cb)
        $ty += 24
    }
    $grp.Add_MouseEnter({ $TweakFlow.Focus() })
    $TweakFlow.Controls.Add($grp)
}
# TAB 3: CONFIG (RESPONSIVE 3-COLUMN GRID - BORDER UTUH DI SEMUA RESOLUSI)
# ==============================================================================
$TabConfig = New-Object System.Windows.Forms.TabPage
$TabConfig.Text = "Config"
$TabConfig.ImageKey = "config"
$TabConfig.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabConfig.Padding = New-Object System.Windows.Forms.Padding(8)
$TabControl.Controls.Add($TabConfig)

$ConfigGrid = New-Object System.Windows.Forms.TableLayoutPanel
$ConfigGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$ConfigGrid.ColumnCount = 3
$ConfigGrid.RowCount = 1
[void]$ConfigGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
[void]$ConfigGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.34)))
[void]$ConfigGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
[void]$ConfigGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$TabConfig.Controls.Add($ConfigGrid)

# --- KOLOM 1: FEATURES ---
$GrpFeatures = New-Object System.Windows.Forms.GroupBox
$GrpFeatures.Text = "Features (Windows Optional)"
$GrpFeatures.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpFeatures.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpFeatures.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
$ConfigGrid.Controls.Add($GrpFeatures, 0, 0)

$PnlFeaturesScroll = New-Object System.Windows.Forms.Panel
$PnlFeaturesScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
$PnlFeaturesScroll.AutoScroll = $true
$GrpFeatures.Controls.Add($PnlFeaturesScroll)

$CTTFeatures = @(
    @{ Name="All .NET Frameworks (2.0, 3.0, 3.5, 4.8)"; Feat="NetFx3" },
    @{ Name="Hyper-V Virtualization"; Feat="Microsoft-Hyper-V-All" },
    @{ Name="Windows Subsystem for Linux (WSL)"; Feat="Microsoft-Windows-Subsystem-Linux" },
    @{ Name="Virtual Machine Platform"; Feat="VirtualMachinePlatform" },
    @{ Name="Windows Sandbox"; Feat="Containers-DisposableClientVM" },
    @{ Name="Legacy Media (WMP and DirectPlay)"; Feat="DirectPlay" },
    @{ Name="Telnet Client"; Feat="TelnetClient" },
    @{ Name="TFTP Client"; Feat="TFTP" },
    @{ Name="NFS Client (Services for NFS)"; Feat="ServicesForNFS-ClientOnly" }
)
$FeatCheckboxes = @()
$fy = 10
foreach ($f in $CTTFeatures) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $f.Name
    $cb.Tag = $f.Feat
    $cb.Font = New-Object System.Drawing.Font("Segoe UI", 8.3)
    $cb.Location = New-Object System.Drawing.Point(10, $fy)
    $cb.Size = New-Object System.Drawing.Size(312, 22)
    $PnlFeaturesScroll.Controls.Add($cb)
    $FeatCheckboxes += $cb
    $fy += 25
}

$btnInstallFeat = New-ActionButton $PnlFeaturesScroll "Install Selected Features" 12 ($fy + 8) 304 36 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 21 16
$btnInstallFeat.Add_Click({
    $sel = $FeatCheckboxes | Where-Object { $_.Checked }
    if ($sel.Count -eq 0) { Write-Log "Pilih Windows Feature dulu!" "WARN"; return }
    $btnInstallFeat.Enabled = $false
    try {
        foreach ($cb in $sel) {
            Write-Log "Mengaktifkan $($cb.Text) (Background)..." "INFO"
            $errMsg = Invoke-AsyncTask -ScriptBlock {
                param($featName)
                try {
                    Enable-WindowsOptionalFeature -Online -FeatureName $featName -All -NoRestart -ErrorAction Stop | Out-Null
                    return $null
                } catch {
                    return $_.Exception.Message
                }
            } -Parameters @{ featName = $cb.Tag }

            if (-not $errMsg) { Write-Log "$($cb.Text) aktif!" "SUCCESS" }
            else { Write-Log "Gagal $($cb.Text): $errMsg" "ERROR" }
        }
    } finally {
        $btnInstallFeat.Enabled = $true
    }
})

# --- KOLOM 2: FIXES AND WINDOWS UPDATE ---
$GrpFixes = New-Object System.Windows.Forms.GroupBox
$GrpFixes.Text = "Fixes and Windows Update"
$GrpFixes.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpFixes.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpFixes.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
$ConfigGrid.Controls.Add($GrpFixes, 1, 0)

$PnlFixesScroll = New-Object System.Windows.Forms.Panel
$PnlFixesScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
$PnlFixesScroll.AutoScroll = $true
$GrpFixes.Controls.Add($PnlFixesScroll)

$btnResetWU = New-ActionButton $PnlFixesScroll "Reset Windows Update" 14 12 306 34 $null "shell32.dll" 238 16
$btnResetWU.Add_Click({
    Invoke-AsyncTask -ScriptBlock {
        Stop-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service wuauserv, bits, cryptsvc -ErrorAction SilentlyContinue
    } -DisableControls @($btnResetWU) | Out-Null
    Write-Log "Windows Update di-reset!" "SUCCESS"
})

$btnResetNet = New-ActionButton $PnlFixesScroll "Reset Network (Winsock and DNS)" 14 52 306 34 $null "shell32.dll" 18 16
$btnResetNet.Add_Click({
    Invoke-AsyncTask -ScriptBlock {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
    } -DisableControls @($btnResetNet) | Out-Null
    Write-Log "Network di-reset!" "SUCCESS"
})

$btnSFC = New-ActionButton $PnlFixesScroll "System Corruption Scan (DISM and SFC)" 14 92 306 34 $null "imageres.dll" 102 16
$btnSFC.Add_Click({ Start-Process "cmd.exe" -ArgumentList "/c DISM /Online /Cleanup-Image /RestoreHealth" })

$btnWinReinstall = New-ActionButton $PnlFixesScroll "Fix Windows Store / Re-register Appx" 14 132 306 34 $null "shell32.dll" 162 16
$btnWinReinstall.Add_Click({
    Write-Log "Mendaftarkan ulang aplikasi bawaan Windows (Background)..." "INFO"
    Invoke-AsyncTask -ScriptBlock {
        Get-AppxPackage -AllUsers | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue }
    } -DisableControls @($btnWinReinstall) | Out-Null
    Write-Log "Re-register Appx selesai!" "SUCCESS"
})

$btnWUDefault = New-ActionButton $PnlFixesScroll "Win Update: Default Settings" 14 182 306 34 $null "shell32.dll" 46 16
$btnWUDefault.Add_Click({
    Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Windows Update dikembalikan ke Default." "SUCCESS"
})

$btnWUSecurity = New-ActionButton $PnlFixesScroll "Win Update: Security Only (Recommended)" 14 222 306 34 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "imageres.dll" 73 16
$btnWUSecurity.Add_Click({
    $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
    Set-ItemProperty $p "DeferFeatureUpdates" 1 -Type DWORD; Set-ItemProperty $p "DeferFeatureUpdatesPeriodInDays" 365 -Type DWORD
    Set-ItemProperty $p "DeferQualityUpdates" 1 -Type DWORD; Set-ItemProperty $p "DeferQualityUpdatesPeriodInDays" 4 -Type DWORD
    Write-Log "Windows Update diatur ke Security Only (Feature ditunda 365 hari)." "SUCCESS"
})

$btnWUDisable = New-ActionButton $PnlFixesScroll "Win Update: Disable All Updates" 14 262 306 34 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 16
$btnWUDisable.Add_Click({
    $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
    Set-ItemProperty $p "NoAutoUpdate" 1 -Type DWORD
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue; Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Log "Semua Windows Update DINONAKTIFKAN." "WARN"
})

# --- KOLOM 3: LEGACY WINDOWS PANELS ---
$GrpPanels = New-Object System.Windows.Forms.GroupBox
$GrpPanels.Text = "Legacy Windows Panels"
$GrpPanels.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpPanels.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpPanels.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
$ConfigGrid.Controls.Add($GrpPanels, 2, 0)

$PnlPanelsScroll = New-Object System.Windows.Forms.Panel
$PnlPanelsScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
$PnlPanelsScroll.AutoScroll = $true
$GrpPanels.Controls.Add($PnlPanelsScroll)

$panels = @(
    @{ Name="Control Panel";                  Cmd="control.exe";  Dll="shell32.dll";  Idx=21 },
    @{ Name="Network Connections (ncpa.cpl)"; Cmd="ncpa.cpl";     Dll="shell32.dll";  Idx=18 },
    @{ Name="Power Panel (powercfg.cpl)";     Cmd="powercfg.cpl"; Dll="powercpl.dll"; Idx=0  },
    @{ Name="Region and Language (intl.cpl)"; Cmd="intl.cpl";     Dll="shell32.dll";  Idx=13 },
    @{ Name="Sound Settings (mmsys.cpl)";     Cmd="mmsys.cpl";    Dll="mmsys.cpl";    Idx=0  },
    @{ Name="System Properties (sysdm.cpl)";  Cmd="sysdm.cpl";    Dll="shell32.dll";  Idx=15 },
    @{ Name="Programs and Features";          Cmd="appwiz.cpl";   Dll="appwiz.cpl";   Idx=0  },
    @{ Name="User Accounts (netplwiz)";       Cmd="netplwiz.exe"; Dll="shell32.dll";  Idx=111},
    @{ Name="Device Manager (devmgmt.msc)";   Cmd="devmgmt.msc";  Dll="devmgr.dll";   Idx=4  },
    @{ Name="Disk Management (diskmgmt.msc)"; Cmd="diskmgmt.msc"; Dll="dmdskres.dll"; Idx=0  }
)
$py = 10
foreach ($pnl in $panels) {
    $b = New-ActionButton $PnlPanelsScroll $pnl.Name 14 $py 298 31 $null $pnl.Dll $pnl.Idx 16
    $cmd = $pnl.Cmd
    $b.Add_Click({ Start-Process $cmd }.GetNewClosure())
    $py += 36
}
# TAB 4: IT ADMIN LOKAL + ON-DEMAND DOWNLOAD ASSETS
# ==============================================================================
$TabLocal = New-Object System.Windows.Forms.TabPage
$TabLocal.Text = "IT Lokal"
$TabLocal.ImageKey = "admin"
$TabLocal.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabLocal.AutoScroll = $true; $TabLocal.AutoScroll = $true; $TabControl.Controls.Add($TabLocal)

$btnSpec = New-ActionButton $TabLocal "Cek Spesifikasi Laptop" 20 18 320 38 $null "shell32.dll" 15 16
$btnSpec.Add_Click({
    $hw = Invoke-AsyncTask -ScriptBlock {
        [PSCustomObject]@{
            Sys  = Get-CimInstance Win32_ComputerSystem
            Bios = Get-CimInstance Win32_Bios
            Proc = Get-CimInstance Win32_Processor
            Disk = Get-PhysicalDisk
        }
    } -DisableControls @($btnSpec)
    if ($hw) {
        Write-Log "PC: $($hw.Sys.CSName) | Model: $($hw.Sys.Manufacturer) $($hw.Sys.Model) | SN: $($hw.Bios.SerialNumber)" "SUCCESS"
        Write-Log "CPU: $($hw.Proc.Name.Trim()) | RAM: $([math]::Round($hw.Sys.TotalPhysicalMemory/1GB,2)) GB" "INFO"
        $hw.Disk | ForEach-Object { Write-Log "Disk: $($_.FriendlyName) ($($_.MediaType)) - $([math]::Round($_.Size/1GB,2)) GB [$($_.HealthStatus)]" "INFO" }
    }
})

$btnRename = New-ActionButton $TabLocal "Rename Nama PC" 360 18 320 38 $null "shell32.dll" 134 16
$btnRename.Add_Click({
    $n = Show-InputBox "Rename PC" "Nama PC saat ini: $env:COMPUTERNAME`nMasukkan Nama PC Baru:"
    if ($n) { try { Rename-Computer -NewName $n -Force -ErrorAction Stop; Write-Log "Nama PC diubah ke '$n'." "SUCCESS" } catch { Write-Log $_.Exception.Message "ERROR" } }
})

$btnBlockUSB = New-ActionButton $TabLocal "Block USB Storage" 700 18 170 38 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 16
$btnBlockUSB.Add_Click({ Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" "Start" 4; Write-Log "USB DI-BLOCK." "WARN" })

$btnUnblockUSB = New-ActionButton $TabLocal "Unblock USB" 880 18 170 38 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 7 16
$btnUnblockUSB.Add_Click({ Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" "Start" 3; Write-Log "USB DI-UNBLOCK." "SUCCESS" })

$btnSetWP = New-ActionButton $TabLocal "Terapkan Wallpaper & Lock Screen" 20 68 320 38 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "imageres.dll" 67 16
$btnSetWP.Add_Click({
    $btnSetWP.Enabled = $false
    try {
        $wpFile = Get-ToolAsset -FileName "wp.png"
        if (-not $wpFile) { return }
        $tf = "C:\Users\Public\Pictures\wp.png"
        Copy-Item $wpFile $tf -Force
        Set-ItemProperty "HKCU:\Control Panel\Desktop" "Wallpaper" $tf
        Set-ItemProperty "HKCU:\Control Panel\Desktop" "WallpaperStyle" "2"
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class WP { [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni); }' -ErrorAction SilentlyContinue
        [WP]::SystemParametersInfo(20, 0, $tf, 3) | Out-Null
        Set-UnlockedLockScreenImage -ImagePath $tf
        Write-Log "Wallpaper dan Lock Screen diterapkan (Status: Unlocked)!" "SUCCESS"
    } catch { Write-Log $_.Exception.Message "ERROR" }
    finally { $btnSetWP.Enabled = $true }
})

$btnLockWP = New-ActionButton $TabLocal "Lock Wallpaper" 360 68 155 38 $null "shell32.dll" 47 16
$btnLockWP.Add_Click({
    @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System") | ForEach-Object {
        if (!(Test-Path $_)) { New-Item $_ -Force | Out-Null }
        Set-ItemProperty $_ "NoChangingWallPaper" 1 -Type DWORD -ErrorAction SilentlyContinue
    }
    $persPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    if (!(Test-Path $persPol)) { New-Item $persPol -Force | Out-Null }
    Set-ItemProperty $persPol "NoChangingLockScreen" 1 -Type DWORD -ErrorAction SilentlyContinue

    $tf = "C:\Users\Public\Pictures\wp.png"
    if (-not (Test-Path $tf)) {
        $dl = Get-ToolAsset -FileName "wp.png"
        if ($dl) { Copy-Item $dl $tf -Force }
    }
    if (Test-Path $tf) {
        $lr = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
        if (!(Test-Path $lr)) { New-Item $lr -Force | Out-Null }
        Set-ItemProperty $lr "LockScreenImagePath" $tf -Type String
        Set-ItemProperty $lr "LockScreenImageUrl" $tf -Type String
        Set-ItemProperty $lr "LockScreenImageStatus" 1 -Type DWORD
    }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Write-Log "Wallpaper Desktop dan Lock Screen DI-LOCK." "WARN"
})

$btnUnlockWP = New-ActionButton $TabLocal "Unlock Wallpaper" 525 68 155 38 $null "imageres.dll" 79 16
$btnUnlockWP.Add_Click({
    @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System") | ForEach-Object {
        if (Test-Path $_) { Remove-ItemProperty $_ "NoChangingWallPaper" -ErrorAction SilentlyContinue }
    }
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Write-Log "Wallpaper Desktop dan Lock Screen DI-UNLOCK." "SUCCESS"
})

$btnDefender = New-ActionButton $TabLocal "Aktifkan Defender dan Firewall" 700 68 350 38 $null "imageres.dll" 73 16
$btnDefender.Add_Click({
    $err = Invoke-AsyncTask -ScriptBlock {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
            Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -ErrorAction Stop
            return $null
        } catch { return $_.Exception.Message }
    } -DisableControls @($btnDefender)
    if (-not $err) { Write-Log "Defender dan Firewall Aktif!" "SUCCESS" } else { Write-Log $err "ERROR" }
})

$btnAddIT = New-ActionButton $TabLocal "Buat/Update User IT_ADMIN" 20 118 320 38 $null "shell32.dll" 111 16
$btnAddIT.Add_Click({
    $p = Show-InputBox "User IT_ADMIN" "Masukkan Password IT_ADMIN:" "F1d4c@IT" $true; if (!$p) { return }
    $s = ConvertTo-SecureString $p -AsPlainText -Force
    try {
        if (Get-LocalUser "IT_ADMIN" -ErrorAction SilentlyContinue) { Set-LocalUser "IT_ADMIN" -Password $s -PasswordNeverExpires $true; Write-Log "User IT_ADMIN diperbarui." "SUCCESS" }
        else { New-LocalUser "IT_ADMIN" -Password $s -FullName "IT Administrator" -PasswordNeverExpires; Add-LocalGroupMember "Administrators" "IT_ADMIN"; Write-Log "Akun IT_ADMIN dibuat." "SUCCESS" }
    } catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnDemote = New-ActionButton $TabLocal "Turunkan Karyawan ke Standard" 360 118 320 38 $null "imageres.dll" 74 16
$btnDemote.Add_Click({
    Get-LocalGroupMember "Administrators" | ForEach-Object {
        $n = $_.Name.Split('\')[-1]
        if ($n -ne "IT_ADMIN" -and $n -ne "Administrator") {
            try { Remove-LocalGroupMember "Administrators" $n -ErrorAction Stop; Add-LocalGroupMember "Users" $n -ErrorAction SilentlyContinue; Write-Log "'$n' diturunkan ke Standard." "SUCCESS" }
            catch { Write-Log $_.Exception.Message "ERROR" }
        }
    }
})

$btnNewUser = New-ActionButton $TabLocal "Tambah User Karyawan Baru" 700 118 350 38 $null "shell32.dll" 269 16
$btnNewUser.Add_Click({
    $u = Show-InputBox "User Baru" "Username Karyawan Baru:"; if (!$u) { return }
    $p = Show-InputBox "Password" "Password untuk ${u}:" "" $true; if (!$p) { return }
    try { New-LocalUser $u -Password (ConvertTo-SecureString $p -AsPlainText -Force) -PasswordNeverExpires; Add-LocalGroupMember "Users" $u; Write-Log "User '$u' dibuat." "SUCCESS" }
    catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnWinLic = New-ActionButton $TabLocal "Cek Lisensi Windows" 20 168 320 38 $null "shell32.dll" 44 16
$btnWinLic.Add_Click({
    $out = Invoke-AsyncTask -ScriptBlock { (cscript //nologo C:\Windows\System32\slmgr.vbs /dli | Out-String).Trim() } -DisableControls @($btnWinLic)
    Write-Log $out "INFO"
})

$btnOffLic = New-ActionButton $TabLocal "Cek Lisensi Office" 360 168 320 38 $null "shell32.dll" 70 16
$btnOffLic.Add_Click({
    $out = Invoke-AsyncTask -ScriptBlock {
        $p = @("$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS","${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($p) { return (cscript //nologo "$p" /dstatus | Select-String "LICENSE NAME|LICENSE STATUS" | Out-String).Trim() }
        return $null
    } -DisableControls @($btnOffLic)
    if ($out) { Write-Log $out "INFO" } else { Write-Log "Office 16 tidak terdeteksi." "WARN" }
})

$btnBitlocker = New-ActionButton $TabLocal "Backup BitLocker Key (C:)" 700 168 350 38 $null "imageres.dll" 77 16
$btnBitlocker.Add_Click({
    try {
        $rk = (Get-BitLockerVolume "C:" -ErrorAction Stop).KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }
        if ($rk) { Write-Log "BitLocker Key C: -> $($rk.RecoveryPassword)" "SUCCESS" } else { Write-Log "BitLocker tidak aktif." "WARN" }
    } catch { Write-Log $_.Exception.Message "ERROR" }
})

# --- GROUP BOX KIRI BAWAH: TERAPKAN ISO ---
$GrpISO = New-Object System.Windows.Forms.GroupBox
$GrpISO.Text = "Standarisasi ISO Perusahaan (Auto-Skip & On-Demand)"
$GrpISO.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpISO.ForeColor = [System.Drawing.Color]::FromArgb(24, 34, 56)
$GrpISO.Location = New-Object System.Drawing.Point(20, 222)
$GrpISO.Size = New-Object System.Drawing.Size(505, 236)
$TabLocal.Controls.Add($GrpISO)

$LblISODesc = New-Object System.Windows.Forms.Label
$LblISODesc.Text = "Otomatis menerapkan 6 kebijakan standar ISO (skip jika sudah aktif):`r`n1. Block USB Storage`r`n2. Wallpaper dan Lock Screen (Auto-download wp.png jika belum ada)`r`n3. Lock Wallpaper & Lock Screen`r`n4. Aktifkan Defender dan Firewall`r`n5. Buat/Update User IT_ADMIN`r`n6. Turunkan Karyawan ke Standard User"
$LblISODesc.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblISODesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$LblISODesc.Location = New-Object System.Drawing.Point(15, 24)
$LblISODesc.Size = New-Object System.Drawing.Size(475, 134)
$GrpISO.Controls.Add($LblISODesc)

$btnApplyISO = New-ActionButton $GrpISO "TERAPKAN ISO SEKARANG (AUTO-SKIP)" 15 168 475 48 ([System.Drawing.Color]::FromArgb(142, 68, 173)) "imageres.dll" 101 20
$btnApplyISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnApplyISO.Add_Click({
    $btnApplyISO.Enabled = $false
    try {
        Write-Log "============================================================" "INFO"
        Write-Log "MEMULAI PENERAPAN KEBIJAKAN ISO PERUSAHAAN..." "INFO"

        $usbVal = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -ErrorAction SilentlyContinue).Start
        if ($usbVal -eq 4) {
            Write-Log "[1/6] Block USB Storage sudah aktif (Start=4) -> Melewati..." "SKIP"
        } else {
            try { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -Value 4 -ErrorAction Stop; Write-Log "[1/6] USB Storage berhasil DI-BLOCK." "SUCCESS" }
            catch { Write-Log "[1/6] Gagal Block USB: $($_.Exception.Message)" "ERROR" }
        }

        $targetWP = "C:\Users\Public\Pictures\wp.png"
        $curWP = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -ErrorAction SilentlyContinue).Wallpaper
        if (($curWP -eq $targetWP) -and (Test-Path $targetWP)) {
            Write-Log "[2/6] File Wallpaper dan Lock Screen sudah terpasang -> Melewati..." "SKIP"
        } else {
            $wpFile = Get-ToolAsset -FileName "wp.png"
            if (-not $wpFile) { Write-Log "[2/6] File 'wp.png' gagal didapatkan -> Melewati..." "WARN" }
            else {
                try {
                    Copy-Item -Path $wpFile -Destination $targetWP -Force -ErrorAction Stop
                    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -Value $targetWP
                    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "2"
                    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class WPISO { [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni); }' -ErrorAction SilentlyContinue
                    [WPISO]::SystemParametersInfo(20, 0, $targetWP, 3) | Out-Null
                    Set-UnlockedLockScreenImage -ImagePath $targetWP
                    Write-Log "[2/6] Wallpaper dan Lock Screen (wp.png) berhasil diterapkan!" "SUCCESS"
                } catch { Write-Log "[2/6] Gagal menerapkan wallpaper: $($_.Exception.Message)" "ERROR" }
            }
        }

        $wpPol1 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        $wpPol2 = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        $lsPol  = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue).NoChangingLockScreen
        $cspOk  = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
        if (($wpPol1 -eq 1) -and ($wpPol2 -eq 1) -and ($lsPol -eq 1) -and $cspOk) {
            Write-Log "[3/6] Lock Wallpaper & Lock Screen sudah aktif -> Melewati..." "SKIP"
        } else {
            try {
                @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System") | ForEach-Object {
                    if (-not (Test-Path $_)) { New-Item $_ -Force | Out-Null }
                    Set-ItemProperty $_ -Name "NoChangingWallPaper" -Value 1 -Type DWORD -ErrorAction SilentlyContinue
                }
                $persPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
                if (-not (Test-Path $persPol)) { New-Item $persPol -Force | Out-Null }
                Set-ItemProperty $persPol -Name "NoChangingLockScreen" -Value 1 -Type DWORD -ErrorAction SilentlyContinue

                if (Test-Path $targetWP) {
                    $lr = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
                    if (-not (Test-Path $lr)) { New-Item -Path $lr -Force | Out-Null }
                    Set-ItemProperty -Path $lr -Name "LockScreenImagePath" -Value $targetWP -Type String
                    Set-ItemProperty -Path $lr -Name "LockScreenImageUrl" -Value $targetWP -Type String
                    Set-ItemProperty -Path $lr -Name "LockScreenImageStatus" -Value 1 -Type DWORD
                }
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Write-Log "[3/6] Wallpaper Desktop dan Lock Screen berhasil DI-LOCK!" "SUCCESS"
            } catch { Write-Log "[3/6] Gagal Lock Wallpaper: $($_.Exception.Message)" "ERROR" }
        }

        $mpStatus = Get-MpPreference -ErrorAction SilentlyContinue
        $fwOff = Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $false }
        if ($mpStatus -and ($mpStatus.DisableRealtimeMonitoring -eq $false) -and (-not $fwOff)) {
            Write-Log "[4/6] Defender dan Firewall sudah aktif -> Melewati..." "SKIP"
        } else {
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -ErrorAction Stop
                Write-Log "[4/6] Windows Defender dan Firewall aktif!" "SUCCESS"
            } catch { Write-Log "[4/6] Gagal Defender/Firewall: $($_.Exception.Message)" "ERROR" }
        }

        $itUser = Get-LocalUser -Name "IT_ADMIN" -ErrorAction SilentlyContinue
        $itInAdmin = (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object { $_.Name.Split('\')[-1] -eq "IT_ADMIN" })
        if ($itUser -and $itUser.Enabled -and $itInAdmin) {
            Write-Log "[5/6] Akun IT_ADMIN sudah aktif -> Melewati..." "SKIP"
        } else {
            $passInput = Show-InputBox "Setup IT_ADMIN (ISO)" "Akun IT_ADMIN belum siap. Masukkan Password IT_ADMIN:" "F1d4c@IT" $true
            if ([string]::IsNullOrWhiteSpace($passInput)) { $passInput = "F1d4c@IT" }
            $secPass = ConvertTo-SecureString $passInput -AsPlainText -Force
            try {
                if ($itUser) {
                    Enable-LocalUser -Name "IT_ADMIN" -ErrorAction SilentlyContinue
                    Set-LocalUser -Name "IT_ADMIN" -Password $secPass -PasswordNeverExpires $true
                    if (-not $itInAdmin) { Add-LocalGroupMember -Group "Administrators" -Member "IT_ADMIN" }
                    Write-Log "[5/6] Akun IT_ADMIN diperbarui." "SUCCESS"
                } else {
                    New-LocalUser -Name "IT_ADMIN" -Password $secPass -FullName "IT Administrator" -PasswordNeverExpires -ErrorAction Stop
                    Add-LocalGroupMember -Group "Administrators" -Member "IT_ADMIN" -ErrorAction Stop
                    Write-Log "[5/6] Akun IT_ADMIN berhasil dibuat." "SUCCESS"
                }
            } catch { Write-Log "[5/6] Gagal setup IT_ADMIN: $($_.Exception.Message)" "ERROR" }
        }

        $otherAdmins = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object {
            $n = $_.Name.Split('\')[-1]
            ($n -ne "IT_ADMIN") -and ($n -ne "Administrator")
        }
        if (-not $otherAdmins -or $otherAdmins.Count -eq 0) {
            Write-Log "[6/6] Tidak ada user karyawan dengan hak Admin -> Melewati..." "SKIP"
        } else {
            foreach ($m in $otherAdmins) {
                $empName = $m.Name.Split('\')[-1]
                try {
                    Remove-LocalGroupMember -Group "Administrators" -Member $empName -ErrorAction Stop
                    Add-LocalGroupMember -Group "Users" -Member $empName -ErrorAction SilentlyContinue
                    Write-Log "[6/6] User karyawan '$empName' diturunkan ke Standard User." "SUCCESS"
                } catch { Write-Log "[6/6] Gagal menurunkan '$empName': $($_.Exception.Message)" "ERROR" }
            }
        }

        Write-Log "PENERAPAN KEBIJAKAN ISO SELESAI!" "SUCCESS"
        & $RefreshISODashboard
    } finally {
        $btnApplyISO.Enabled = $true
    }
})

# --- GROUP BOX KANAN BAWAH: AUTO PROVISIONING FORTICLIENT VPN KANTOR ---
$GrpVPN = New-Object System.Windows.Forms.GroupBox
$GrpVPN.Text = "Auto-Setup FortiClient VPN Kantor (On-Demand Download)"
$GrpVPN.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpVPN.ForeColor = [System.Drawing.Color]::FromArgb(24, 34, 56)
$GrpVPN.Location = New-Object System.Drawing.Point(540, 222)
$GrpVPN.Size = New-Object System.Drawing.Size(510, 236)
$TabLocal.Controls.Add($GrpVPN)

$LblVPNDesc = New-Object System.Windows.Forms.Label
$LblVPNDesc.Text = "Otomatis download (jika belum ada) dan install FortiClient VPN:`r`n- Mengunduh FortiClientVPN.exe dan vpn_master.conf saat tombol diklik`r`n- Password Backup : 12345678 (Otomatis didekripsi via FCConfig -m vpn)`r`n- Opsional: Mengganti Username VPN sesuai nama karyawan baru`r`n  sehingga karyawan cukup mengisi password saat login."
$LblVPNDesc.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblVPNDesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$LblVPNDesc.Location = New-Object System.Drawing.Point(15, 24)
$LblVPNDesc.Size = New-Object System.Drawing.Size(480, 128)
$GrpVPN.Controls.Add($LblVPNDesc)

$btnAutoVPN = New-ActionButton $GrpVPN "AUTO INSTALL DAN RESTORE VPN KANTOR" 15 168 480 48 ([System.Drawing.Color]::FromArgb(22, 160, 133)) "shell32.dll" 18 20
$btnAutoVPN.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnAutoVPN.Add_Click({
    $btnAutoVPN.Enabled = $false
    try {
        Write-Log "============================================================" "INFO"
        Write-Log "MEMULAI AUTO-PROVISIONING FORTICLIENT VPN KANTOR..." "INFO"

        $fcPaths = @(
            "C:\Program Files\Fortinet\FortiClient\FortiClient.exe",
            "${env:ProgramFiles(x86)}\Fortinet\FortiClient\FortiClient.exe"
        )
        $fcExe = $fcPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

        if (-not $fcExe) {
            $installerFile = Get-ToolAsset -FileName "FortiClientVPN.exe"
            if (-not $installerFile) { return }

            Write-Log "[1/3] Menginstal FortiClient VPN secara silent (GUI tetap aktif)..." "INFO"
            $exitInstaller = Invoke-ProcAsync -FilePath $installerFile -ArgumentList "/quiet /norestart"
            for ($w = 0; $w -lt 50; $w++) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
            $fcExe = $fcPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $fcExe) {
                Write-Log "[1/3] Installer selesai (ExitCode: $exitInstaller), namun FortiClient.exe belum muncul." "ERROR"
                return
            }
            Write-Log "[1/3] FortiClient VPN berhasil di-install!" "SUCCESS"
        } else {
            Write-Log "[1/3] FortiClient VPN sudah terpasang -> Lanjut restore profil..." "SKIP"
        }

        $masterFile = Get-ToolAsset -FileName "vpn_master.conf"
        if (-not $masterFile) { return }

        $fcConfig = Join-Path (Split-Path $fcExe) "FCConfig.exe"
        $vpnUser = Show-InputBox "Username VPN Karyawan" "Masukkan Username VPN untuk karyawan ini:`n(Kosongkan jika menggunakan username bawaan master)" "" $false

        Write-Log "[2/3] Mengimpor konfigurasi vpn_master.conf (-m vpn) ke FortiClient..." "INFO"
        Stop-Process -Name "FortiClient" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500

        $exitImp = Invoke-ProcAsync -FilePath $fcConfig -ArgumentList "-m vpn -f `"$masterFile`" -o import -i 1 -p 12345678" -NoNewWindow

        if (-not [string]::IsNullOrWhiteSpace($vpnUser)) {
            @(
                "HKLM:\SOFTWARE\Fortinet\FortiClient\IPSec\Tunnels\VPN Kantor",
                "HKCU:\Software\Fortinet\FortiClient\IPSec\Tunnels\VPN Kantor"
            ) | ForEach-Object {
                if (Test-Path $_) {
                    Set-ItemProperty -Path $_ -Name "Username" -Value $vpnUser.Trim() -Type String -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $_ -Name "PromptUsername" -Value 0 -Type DWORD -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $_ -Name "SavePassword" -Value 0 -Type DWORD -ErrorAction SilentlyContinue
                }
            }
        }

        Restart-Service -Name "FA_Scheduler" -Force -ErrorAction SilentlyContinue

        if ($exitImp -eq 0) {
            Write-Log "[3/3] Profil 'VPN Kantor' berhasil di-restore! Silakan buka FortiClient dari Start Menu." "SUCCESS"
        } else {
            Write-Log "[3/3] FCConfig selesai dengan kode $exitImp. Cek FortiClient dari Start Menu." "WARN"
        }
    } catch {
        Write-Log "Gagal mengimpor vpn_master.conf: $($_.Exception.Message)" "ERROR"
    } finally {
        $btnAutoVPN.Enabled = $true
    }
})

# ==============================================================================
# TAB 5: DASHBOARD ISO (AUDIT STATUS LENGKAP PERANGKAT - RESPONSIVE & BORDER UTUH)
# ==============================================================================
$TabISO = New-Object System.Windows.Forms.TabPage
$TabISO.Text = "Audit ISO"
$TabISO.ImageKey = "iso"
$TabISO.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabISO.Padding = New-Object System.Windows.Forms.Padding(8)
$TabControl.Controls.Add($TabISO)

# Bar Tombol Bawah Audit ISO (Selalu Terlihat Utuh di Bagian Bawah)
$IsoBottomBar = New-Object System.Windows.Forms.Panel
$IsoBottomBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$IsoBottomBar.Height = 44
$TabISO.Controls.Add($IsoBottomBar)

# Grid 2 Kolom (44% Spesifikasi : 56% Status Keamanan)
$IsoGrid = New-Object System.Windows.Forms.TableLayoutPanel
$IsoGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$IsoGrid.ColumnCount = 2
$IsoGrid.RowCount = 1
[void]$IsoGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 44)))
[void]$IsoGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 56)))
[void]$IsoGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$TabISO.Controls.Add($IsoGrid)
$IsoGrid.BringToFront()

$GrpISOSpec = New-Object System.Windows.Forms.GroupBox
$GrpISOSpec.Text = "Spesifikasi Hardware dan Identitas Laptop"
$GrpISOSpec.Font = New-Object System.Drawing.Font("Segoe UI", 9.2, [System.Drawing.FontStyle]::Bold)
$GrpISOSpec.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpISOSpec.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
$GrpISOSpec.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 8)
$IsoGrid.Controls.Add($GrpISOSpec, 0, 0)

$txtISOSpec = New-Object System.Windows.Forms.TextBox
$txtISOSpec.Multiline = $true
$txtISOSpec.ReadOnly = $true
$txtISOSpec.ScrollBars = "Vertical"
$txtISOSpec.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtISOSpec.BackColor = [System.Drawing.Color]::White
$txtISOSpec.Font = New-Object System.Drawing.Font("Consolas", 9.2)
$GrpISOSpec.Controls.Add($txtISOSpec)

$GrpISOStatus = New-Object System.Windows.Forms.GroupBox
$GrpISOStatus.Text = "Status Keamanan ISO, Akun dan Lisensi"
$GrpISOStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9.2, [System.Drawing.FontStyle]::Bold)
$GrpISOStatus.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpISOStatus.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
$IsoGrid.Controls.Add($GrpISOStatus, 1, 0)

$PnlIsoStatusScroll = New-Object System.Windows.Forms.Panel
$PnlIsoStatusScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
$PnlIsoStatusScroll.AutoScroll = $true
$GrpISOStatus.Controls.Add($PnlIsoStatusScroll)

$StatusLabels = @{}
$StatusFields = @(
    @{ Key="PCName";       Label="Nama PC / Hostname" },
    @{ Key="USBStatus";    Label="Status Block USB Storage" },
    @{ Key="WPStatus";     Label="Status Lock Wallpaper & LS" },
    @{ Key="DefStatus";    Label="Status Defender dan Firewall" },
    @{ Key="ITAdminStat";  Label="Status Profil IT_ADMIN" },
    @{ Key="EmpStat";      Label="Status Profil Karyawan" },
    @{ Key="WinLic";       Label="License Windows" },
    @{ Key="OffLic";       Label="License Office" },
    @{ Key="BitLocker";    Label="Status BitLocker (Drive C:)" }
)

$sy = 10
foreach ($sf in $StatusFields) {
    $lblK = New-Object System.Windows.Forms.Label
    $lblK.Text = "$($sf.Label) :"
    $lblK.Font = New-Object System.Drawing.Font("Segoe UI", 8.8, [System.Drawing.FontStyle]::Bold)
    $lblK.Location = New-Object System.Drawing.Point(12, $sy)
    $lblK.Size = New-Object System.Drawing.Size(205, 22)
    $PnlIsoStatusScroll.Controls.Add($lblK)

    $lblV = New-Object System.Windows.Forms.Label
    $lblV.Text = "Memuat..."
    $lblV.Font = New-Object System.Drawing.Font("Segoe UI", 8.8, [System.Drawing.FontStyle]::Bold)
    $lblV.Location = New-Object System.Drawing.Point(222, $sy)
    $lblV.Size = New-Object System.Drawing.Size(340, 32)
    $PnlIsoStatusScroll.Controls.Add($lblV)

    $StatusLabels[$sf.Key] = $lblV
    $sy += 34
}
$RefreshISODashboard = {
    Write-Log "Memindai status spesifikasi, kepatuhan ISO, dan lisensi (Async)..." "INFO"

    $audit = Invoke-AsyncTask -ScriptBlock {
        $res = [ordered]@{}

        try {
            $sys  = Get-CimInstance Win32_ComputerSystem
            $bios = Get-CimInstance Win32_Bios
            $proc = Get-CimInstance Win32_Processor
            $os   = Get-CimInstance Win32_OperatingSystem
            $ramSlots = Get-CimInstance Win32_PhysicalMemory
            $totalRamGB = [math]::Round(($sys.TotalPhysicalMemory / 1GB), 2)

            $specLines = @(
                "Nama PC       : $($sys.CSName)",
                "Manufaktur    : $($sys.Manufacturer)",
                "Model Laptop  : $($sys.Model)",
                "Serial Number : $($bios.SerialNumber)",
                "OS            : $($os.Caption)",
                "Processor     : $($proc.Name.Trim())",
                "Total RAM     : $totalRamGB GB ($($ramSlots.Count) Slot)"
            )
            foreach ($r in $ramSlots) {
                $specLines += "  - $($r.DeviceLocator): $([math]::Round($r.Capacity/1GB,2)) GB ($($r.Speed) MHz)"
            }
            $specLines += ""
            $specLines += "[ STORAGE / DISK ]"
            Get-PhysicalDisk | ForEach-Object {
                $specLines += "  - $($_.FriendlyName)"
                $specLines += "    Tipe: $($_.MediaType) | $([math]::Round($_.Size/1GB,2)) GB | Health: $($_.HealthStatus)"
            }
            $res["SpecText"] = ($specLines -join "`r`n")
        } catch {
            $res["SpecText"] = "Gagal membaca spesifikasi: $($_.Exception.Message)"
        }

        $res["USBStart"] = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -ErrorAction SilentlyContinue).Start
        $res["WP1"] = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        $res["WP2"] = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        $res["LS1"] = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue).NoChangingLockScreen
        $res["CSP"] = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"

        $mp = Get-MpPreference -ErrorAction SilentlyContinue
        $res["DefenderOff"] = if ($mp) { $mp.DisableRealtimeMonitoring } else { $true }
        $res["FWEnabledCount"] = (Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true }).Count

        $itAcc = Get-LocalUser -Name "IT_ADMIN" -ErrorAction SilentlyContinue
        $res["ITExists"]  = [bool]$itAcc
        $res["ITEnabled"] = if ($itAcc) { [bool]$itAcc.Enabled } else { $false }
        $res["AdminMembers"] = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] })
        $res["StdUsers"]     = @(Get-LocalGroupMember -Group "Users" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] } | Where-Object { $_ -notmatch "Authenticated Users|INTERACTIVE" })

        try {
            $winLicObj = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($winLicObj) {
                $res["WinLicStatus"] = $winLicObj.LicenseStatus
                $res["WinLicName"]   = $winLicObj.Name
            }
        } catch {}

        $ospp = @("$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS","${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($ospp) {
            $res["OfficeFound"] = $true
            $offOut = cscript //nologo "$ospp" /dstatus | Select-String "LICENSE NAME|LICENSE STATUS"
            if ($offOut) {
                $res["OfficeText"] = (($offOut -join " | ") -replace "LICENSE NAME:\s*", "" -replace "LICENSE STATUS:\s*", "").Trim()
            }
        } else {
            $res["OfficeFound"] = $false
        }

        try {
            $blVol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            $res["BLStatus"] = $blVol.ProtectionStatus
            $res["BLMethod"] = $blVol.EncryptionMethod
            $res["BLPct"]    = $blVol.EncryptionPercentage
            $res["BLVolStat"]= $blVol.VolumeStatus
        } catch {
            $res["BLError"] = $true
        }

        return $res
    } -DisableControls @($btnRefreshISO)

    if (-not $audit) { return }

    $txtISOSpec.Text = $audit["SpecText"]

    $StatusLabels["PCName"].Text = $env:COMPUTERNAME
    $StatusLabels["PCName"].ForeColor = [System.Drawing.Color]::FromArgb(24, 34, 56)

    if ($audit["USBStart"] -eq 4) {
        $StatusLabels["USBStatus"].Text = "TERBLOKIR / BLOCKED (Sesuai ISO)"
        $StatusLabels["USBStatus"].ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $StatusLabels["USBStatus"].Text = "TERBUKA / UNBLOCKED (Belum ISO)"
        $StatusLabels["USBStatus"].ForeColor = [System.Drawing.Color]::Crimson
    }

    $wp1 = $audit["WP1"]; $wp2 = $audit["WP2"]; $ls1 = $audit["LS1"]; $csp = $audit["CSP"]
    if (($wp1 -eq 1 -or $wp2 -eq 1) -and ($ls1 -eq 1 -and $csp)) {
        $StatusLabels["WPStatus"].Text = "TERKUNCI / LOCKED (Desktop & Lock Screen)"
        $StatusLabels["WPStatus"].ForeColor = [System.Drawing.Color]::ForestGreen
    } elseif ($wp1 -eq 1 -or $wp2 -eq 1 -or $ls1 -eq 1 -or $csp) {
        $StatusLabels["WPStatus"].Text = "TERKUNCI SEBAGIAN (Partial Lock)"
        $StatusLabels["WPStatus"].ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $StatusLabels["WPStatus"].Text = "TIDAK TERKUNCI / UNLOCKED"
        $StatusLabels["WPStatus"].ForeColor = [System.Drawing.Color]::Crimson
    }

    if (($audit["DefenderOff"] -eq $false) -and ($audit["FWEnabledCount"] -ge 3)) {
        $StatusLabels["DefStatus"].Text = "AKTIF (Defender Real-time dan 3 Firewall ON)"
        $StatusLabels["DefStatus"].ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $StatusLabels["DefStatus"].Text = "NONAKTIF / SEBAGIAN MATI"
        $StatusLabels["DefStatus"].ForeColor = [System.Drawing.Color]::Crimson
    }

    $adminMembers = $audit["AdminMembers"]
    if ($audit["ITExists"] -and $audit["ITEnabled"] -and ($adminMembers -contains "IT_ADMIN")) {
        $StatusLabels["ITAdminStat"].Text = "ADA dan AKTIF (Grup Administrators)"
        $StatusLabels["ITAdminStat"].ForeColor = [System.Drawing.Color]::ForestGreen
    } elseif ($audit["ITExists"]) {
        $StatusLabels["ITAdminStat"].Text = "ADA (Bukan Admin / Nonaktif)"
        $StatusLabels["ITAdminStat"].ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $StatusLabels["ITAdminStat"].Text = "BELUM DIBUAT"
        $StatusLabels["ITAdminStat"].ForeColor = [System.Drawing.Color]::Crimson
    }

    $empAdmins = $adminMembers | Where-Object { $_ -ne "IT_ADMIN" -and $_ -ne "Administrator" }
    $stdUsers  = $audit["StdUsers"]
    if (-not $empAdmins -or $empAdmins.Count -eq 0) {
        $uList = if ($stdUsers) { ($stdUsers -join ", ") } else { "Standar" }
        $StatusLabels["EmpStat"].Text = "AMAN - Standard User ($uList)"
        $StatusLabels["EmpStat"].ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $StatusLabels["EmpStat"].Text = "MASIH ADMIN: $($empAdmins -join ', ')"
        $StatusLabels["EmpStat"].ForeColor = [System.Drawing.Color]::Crimson
    }

    if ($audit.Contains("WinLicStatus")) {
        $licState = switch ($audit["WinLicStatus"]) {
            1 { "Licensed (Aktif Permanen)" }
            2 { "OOB Grace Period" }
            5 { "Notification / Belum Aktivasi" }
            default { "Status Kode: $($audit['WinLicStatus'])" }
        }
        $StatusLabels["WinLic"].Text = "$licState - $($audit['WinLicName'])"
        $StatusLabels["WinLic"].ForeColor = if ($audit["WinLicStatus"] -eq 1) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DarkOrange }
    } else {
        $StatusLabels["WinLic"].Text = "Tidak Terdeteksi / Belum Aktivasi"
        $StatusLabels["WinLic"].ForeColor = [System.Drawing.Color]::Crimson
    }

    if ($audit["OfficeFound"]) {
        if ($audit.Contains("OfficeText") -and $audit["OfficeText"]) {
            $StatusLabels["OffLic"].Text = $audit["OfficeText"]
            $StatusLabels["OffLic"].ForeColor = if ($audit["OfficeText"] -match "LICENSED") { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DarkOrange }
        } else {
            $StatusLabels["OffLic"].Text = "Office Terpasang (Status tidak terbaca)"
            $StatusLabels["OffLic"].ForeColor = [System.Drawing.Color]::DarkOrange
        }
    } else {
        $StatusLabels["OffLic"].Text = "Office 16/2019/2021/365 Tidak Terdeteksi"
        $StatusLabels["OffLic"].ForeColor = [System.Drawing.Color]::DimGray
    }

    if (-not $audit.Contains("BLError")) {
        if ($audit["BLStatus"] -eq "On") {
            $StatusLabels["BitLocker"].Text = "AKTIF / ON ($($audit['BLMethod']) - $($audit['BLPct'])%)"
            $StatusLabels["BitLocker"].ForeColor = [System.Drawing.Color]::ForestGreen
        } else {
            $StatusLabels["BitLocker"].Text = "NONAKTIF / OFF ($($audit['BLVolStat']))"
            $StatusLabels["BitLocker"].ForeColor = [System.Drawing.Color]::DarkOrange
        }
    } else {
        $StatusLabels["BitLocker"].Text = "Tidak Tersedia / Butuh Admin"
        $StatusLabels["BitLocker"].ForeColor = [System.Drawing.Color]::DimGray
    }

    Write-Log "Dashboard ISO selesai diperbarui." "SUCCESS"
}


$btnRefreshISO = New-ActionButton $IsoBottomBar "Refresh Status Audit ISO" 4 4 245 36 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 238 18
$btnRefreshISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.2, [System.Drawing.FontStyle]::Bold)
$btnRefreshISO.Add_Click($RefreshISODashboard)

$btnJumpApplyISO = New-ActionButton $IsoBottomBar "Jalankan Terapkan ISO Sekarang" 258 4 275 36 ([System.Drawing.Color]::FromArgb(142, 68, 173)) "imageres.dll" 101 18
$btnJumpApplyISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.2, [System.Drawing.FontStyle]::Bold)
$btnJumpApplyISO.Add_Click({ $btnApplyISO.PerformClick() })
# TAB 6: STARTUP APPS & UNINSTALL APPS (RESPONSIVE SPLIT + DOCK BOTTOM BUTTONS)
# ==============================================================================
$TabManage = New-Object System.Windows.Forms.TabPage
$TabManage.Text = "Startup & Uninstall"
$TabManage.ImageKey = "manage"
$TabManage.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabManage.Padding = New-Object System.Windows.Forms.Padding(8)
$TabControl.Controls.Add($TabManage)

$DefaultAppBitmap = ([System.Drawing.SystemIcons]::Application).ToBitmap()

$StartupImageList = New-Object System.Windows.Forms.ImageList
$StartupImageList.ImageSize = New-Object System.Drawing.Size(20, 20)
$StartupImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

$UninstallImageList = New-Object System.Windows.Forms.ImageList
$UninstallImageList.ImageSize = New-Object System.Drawing.Size(20, 20)
$UninstallImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

# Grid 2 Kolom (50% : 50%) yang otomatis menyesuaikan ukuran jendela Normal & Maximize
$ManageGrid = New-Object System.Windows.Forms.TableLayoutPanel
$ManageGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$ManageGrid.ColumnCount = 2
$ManageGrid.RowCount = 1
[void]$ManageGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$ManageGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$ManageGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$TabManage.Controls.Add($ManageGrid)

# --- KOLOM KIRI: STARTUP APPS MANAGER ---
$GrpStartup = New-Object System.Windows.Forms.GroupBox
$GrpStartup.Text = "Startup Apps Manager (Multi-Select & Info Dampak)"
$GrpStartup.Font = New-Object System.Drawing.Font("Segoe UI", 9.2, [System.Drawing.FontStyle]::Bold)
$GrpStartup.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpStartup.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
$ManageGrid.Controls.Add($GrpStartup, 0, 0)

# Top Search Bar Startup
$StartupTopBar = New-Object System.Windows.Forms.Panel
$StartupTopBar.Dock = [System.Windows.Forms.DockStyle]::Top
$StartupTopBar.Height = 36
$GrpStartup.Controls.Add($StartupTopBar)

$TxtSearchStartup = New-Object System.Windows.Forms.TextBox
$TxtSearchStartup.Location = New-Object System.Drawing.Point(8, 6)
$TxtSearchStartup.Size = New-Object System.Drawing.Size(390, 24)
$TxtSearchStartup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$TxtSearchStartup.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$StartupTopBar.Controls.Add($TxtSearchStartup)

$btnRefreshStartup = New-ActionButton $StartupTopBar "Refresh" 406 5 102 26 $null "shell32.dll" 238 14
$btnRefreshStartup.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnRefreshStartup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

# Bottom Button Bar Startup (Selalu Terlihat di Bagian Bawah)
$StartupBottomBar = New-Object System.Windows.Forms.Panel
$StartupBottomBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$StartupBottomBar.Height = 44
$GrpStartup.Controls.Add($StartupBottomBar)

# Host Table Startup (Dock = Fill)
$StartupTableHost = New-Object System.Windows.Forms.Panel
$StartupTableHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$StartupTableHost.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 4)
$GrpStartup.Controls.Add($StartupTableHost)
$StartupTableHost.BringToFront()

$LvStartup = New-Object System.Windows.Forms.ListView
$LvStartup.Dock = [System.Windows.Forms.DockStyle]::Fill
$LvStartup.View = [System.Windows.Forms.View]::Details
$LvStartup.CheckBoxes = $true
$LvStartup.FullRowSelect = $true
$LvStartup.GridLines = $true
$LvStartup.SmallImageList = $StartupImageList
$LvStartup.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LvStartup.Columns.Add("Aplikasi Startup", 185) | Out-Null
$LvStartup.Columns.Add("Status", 72) | Out-Null
$LvStartup.Columns.Add("Dampak / Keamanan (Aman Dimatikan?)", 230) | Out-Null
$StartupTableHost.Controls.Add($LvStartup)

$LvStartup.Add_Resize({
    $w = $LvStartup.ClientSize.Width
    if ($w -gt 200) {
        $LvStartup.Columns[0].Width = [int]($w * 0.38)
        $LvStartup.Columns[1].Width = 74
        $LvStartup.Columns[2].Width = $w - $LvStartup.Columns[0].Width - 76
    }
})

$script:StartupItemsCache = @()

function Set-StartupApprovedState {
    param([string]$ApprovedPath, [string]$EntryName, [bool]$Enable)
    if (-not (Test-Path $ApprovedPath)) { New-Item -Path $ApprovedPath -Force | Out-Null }
    $bytes = New-Object byte[] 12
    $bytes[0] = if ($Enable) { 2 } else { 3 }
    Set-ItemProperty -Path $ApprovedPath -Name $EntryName -Value $bytes -Type Binary -ErrorAction Stop
}

$LoadStartupApps = {
    $rawList = Invoke-AsyncTask -ScriptBlock {
        function Get-StateLocal([string]$ApprovedPath, [string]$EntryName) {
            if (-not (Test-Path $ApprovedPath)) { return $true }
            $val = (Get-ItemProperty -Path $ApprovedPath -Name $EntryName -ErrorAction SilentlyContinue).$EntryName
            if ($val -is [byte[]] -and $val.Length -ge 1) { return (($val[0] -band 1) -eq 0) }
            return $true
        }

        function Get-StartupImpactInfo([string]$Name, [string]$Command) {
            $txt = "$Name $Command"
            if ($txt -match "SecurityHealth|Windows Defender|MsMpEng|FortiClient|FortiTray|CrowdStrike|Sentinel|Kaspersky|Bitdefender|ESET|Sophos|Endpoint") {
                return @{
                    Text  = "Sistem/Keamanan - Jangan matikan"
                    Level = "Critical"
                }
            }
            if ($txt -match "Realtek|RtkAud|Waves|Nahimic|Dolby|Synaptics|ETD|Elan|Touchpad|Intel.*Graphics|igfx|NVIDIA|Radeon|AMD|Bluetooth|BTTray|Logi|Corsair|Razer|OneDrive|GoogleDrive") {
                return @{
                    Text  = "Perhatian - Kontrol Audio/Sync/Tray"
                    Level = "Caution"
                }
            }
            if ($txt -match "Teams|Discord|Spotify|Steam|EpicGames|Zoom|WhatsApp|Telegram|Skype|Adobe|CCXProcess|AdobeGC|Update|Helper|Launcher|CCleaner|AnyDesk|RustDesk|uTorrent|IDMan") {
                return @{
                    Text  = "Aman Dimatikan - Hemat RAM & Boot"
                    Level = "SafeHigh"
                }
            }
            return @{
                Text  = "Aman Dimatikan - App Pihak Ketiga"
                Level = "Safe"
            }
        }

        $out = @()
        $regSources = @(
            @{ Scope="User (HKCU)"; RunPath="HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"; AppPath="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" },
            @{ Scope="Machine (HKLM)"; RunPath="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; AppPath="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" },
            @{ Scope="Machine 32-bit"; RunPath="HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; AppPath="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32" }
        )
        foreach ($src in $regSources) {
            if (Test-Path $src.RunPath) {
                $props = (Get-Item $src.RunPath).Property
                foreach ($pName in $props) {
                    $cmdVal = (Get-ItemProperty -Path $src.RunPath -Name $pName -ErrorAction SilentlyContinue).$pName
                    $imp = Get-StartupImpactInfo -Name $pName -Command $cmdVal
                    $out += [PSCustomObject]@{
                        Name         = $pName
                        Command      = $cmdVal
                        Scope        = $src.Scope
                        ApprovedPath = $src.AppPath
                        Enabled      = (Get-StateLocal $src.AppPath $pName)
                        ImpactText   = $imp.Text
                        ImpactLevel  = $imp.Level
                    }
                }
            }
        }
        $folderSources = @(
            @{ Scope="Folder User"; Dir="$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"; AppPath="HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" },
            @{ Scope="Folder AllUsers"; Dir="$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"; AppPath="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" }
        )
        foreach ($fsrc in $folderSources) {
            if (Test-Path $fsrc.Dir) {
                Get-ChildItem -Path $fsrc.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "desktop.ini" } | ForEach-Object {
                    $imp = Get-StartupImpactInfo -Name $_.Name -Command $_.FullName
                    $out += [PSCustomObject]@{
                        Name         = $_.Name
                        Command      = $_.FullName
                        Scope        = $fsrc.Scope
                        ApprovedPath = $fsrc.AppPath
                        Enabled      = (Get-StateLocal $fsrc.AppPath $_.Name)
                        ImpactText   = $imp.Text
                        ImpactLevel  = $imp.Level
                    }
                }
            }
        }
        return $out
    } -DisableControls @($btnRefreshStartup)

    $StartupImageList.Images.Clear()
    $StartupImageList.Images.Add("default", $DefaultAppBitmap)

    $list = New-Object System.Collections.Generic.List[PSObject]
    $imgIdx = 1
    foreach ($it in $rawList) {
        $bmp = Resolve-AppIcon -RawPath $it.Command
        $key = "default"
        if ($bmp) {
            $key = "st_$imgIdx"
            $StartupImageList.Images.Add($key, $bmp)
            $imgIdx++
        }
        $list.Add([PSCustomObject]@{
            Name         = $it.Name
            Command      = $it.Command
            Scope        = $it.Scope
            ApprovedPath = $it.ApprovedPath
            Enabled      = $it.Enabled
            ImpactText   = $it.ImpactText
            ImpactLevel  = $it.ImpactLevel
            IconKey      = $key
        })
    }

    $script:StartupItemsCache = $list.ToArray()
    & $RenderStartupList
}

$RenderStartupList = {
    $filter = $TxtSearchStartup.Text.Trim()
    $LvStartup.BeginUpdate()
    $LvStartup.Items.Clear()
    foreach ($item in $script:StartupItemsCache) {
        if ($filter -and ($item.Name -notlike "*$filter*") -and ($item.ImpactText -notlike "*$filter*")) { continue }
        $lvi = New-Object System.Windows.Forms.ListViewItem($item.Name)
        $lvi.ImageKey = $item.IconKey
        $lvi.Tag = $item
        $statusStr = if ($item.Enabled) { "AKTIF" } else { "NONAKTIF" }
        $lvi.SubItems.Add($statusStr) | Out-Null
        $lvi.SubItems.Add($item.ImpactText) | Out-Null

        if (-not $item.Enabled) {
            $lvi.ForeColor = [System.Drawing.Color]::DimGray
        } elseif ($item.ImpactLevel -eq "Critical") {
            $lvi.ForeColor = [System.Drawing.Color]::Crimson
        } elseif ($item.ImpactLevel -eq "Caution") {
            $lvi.ForeColor = [System.Drawing.Color]::FromArgb(180, 95, 6)
        } else {
            $lvi.ForeColor = [System.Drawing.Color]::FromArgb(20, 100, 50)
        }
        $LvStartup.Items.Add($lvi) | Out-Null
    }
    $LvStartup.EndUpdate()
}

$TxtSearchStartup.Add_TextChanged($RenderStartupList)
$btnRefreshStartup.Add_Click({ & $LoadStartupApps; Write-Log "Daftar Startup Apps diperbarui ($($script:StartupItemsCache.Count) item)." "INFO" })

function Apply-StartupSelection {
    param([bool]$TargetEnable)
    if ($LvStartup.CheckedItems.Count -eq 0) {
        Write-Log "Centang minimal 1 aplikasi startup terlebih dahulu!" "WARN"
        return
    }
    $actionLabel = if ($TargetEnable) { "MENGAKTIFKAN" } else { "MENONAKTIFKAN" }
    Write-Log "$actionLabel $($LvStartup.CheckedItems.Count) aplikasi startup terpilih..." "INFO"

    foreach ($lvi in $LvStartup.CheckedItems) {
        $obj = $lvi.Tag
        if (-not $obj) { continue }
        try {
            Set-StartupApprovedState -ApprovedPath $obj.ApprovedPath -EntryName $obj.Name -Enable $TargetEnable
            $statusTxt = if ($TargetEnable) { "DIAKTIFKAN" } else { "DINONAKTIFKAN" }
            Write-Log "Startup '$($obj.Name)' ($($obj.ImpactText)) berhasil $statusTxt." "SUCCESS"
        } catch {
            Write-Log "Gagal mengubah startup '$($obj.Name)': $($_.Exception.Message)" "ERROR"
        }
    }
    & $LoadStartupApps
}

$btnEnableStartup = New-ActionButton $StartupBottomBar "Enable Selected" 8 4 162 34 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 101 15
$btnEnableStartup.Font = New-Object System.Drawing.Font("Segoe UI", 8.8, [System.Drawing.FontStyle]::Bold)
$btnEnableStartup.Add_Click({ Apply-StartupSelection -TargetEnable $true })

$btnDisableStartup = New-ActionButton $StartupBottomBar "Disable Selected" 176 4 168 34 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 15
$btnDisableStartup.Font = New-Object System.Drawing.Font("Segoe UI", 8.8, [System.Drawing.FontStyle]::Bold)
$btnDisableStartup.Add_Click({ Apply-StartupSelection -TargetEnable $false })

$btnClearStartupSel = New-ActionButton $StartupBottomBar "Clear Check" 350 4 135 34 $null "shell32.dll" 131 15
$btnClearStartupSel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnClearStartupSel.Add_Click({
    foreach ($it in $LvStartup.Items) { $it.Checked = $false }
})

# --- KOLOM KANAN: UNINSTALL INSTALLED APPS ---
$GrpUninstall = New-Object System.Windows.Forms.GroupBox
$GrpUninstall.Text = "Uninstall Installed Apps (Multi-Select)"
$GrpUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 9.2, [System.Drawing.FontStyle]::Bold)
$GrpUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpUninstall.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
$ManageGrid.Controls.Add($GrpUninstall, 1, 0)

# Top Search Bar Uninstall
$UninstallTopBar = New-Object System.Windows.Forms.Panel
$UninstallTopBar.Dock = [System.Windows.Forms.DockStyle]::Top
$UninstallTopBar.Height = 36
$GrpUninstall.Controls.Add($UninstallTopBar)

$TxtSearchUninstall = New-Object System.Windows.Forms.TextBox
$TxtSearchUninstall.Location = New-Object System.Drawing.Point(8, 6)
$TxtSearchUninstall.Size = New-Object System.Drawing.Size(390, 24)
$TxtSearchUninstall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$TxtSearchUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$UninstallTopBar.Controls.Add($TxtSearchUninstall)

$btnRefreshUninstall = New-ActionButton $UninstallTopBar "Refresh" 406 5 102 26 $null "shell32.dll" 238 14
$btnRefreshUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnRefreshUninstall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

# Bottom Button Bar Uninstall (Selalu Terlihat di Bagian Bawah)
$UninstallBottomBar = New-Object System.Windows.Forms.Panel
$UninstallBottomBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$UninstallBottomBar.Height = 44
$GrpUninstall.Controls.Add($UninstallBottomBar)

# Host Table Uninstall (Dock = Fill)
$UninstallTableHost = New-Object System.Windows.Forms.Panel
$UninstallTableHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$UninstallTableHost.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 4)
$GrpUninstall.Controls.Add($UninstallTableHost)
$UninstallTableHost.BringToFront()

$LvUninstall = New-Object System.Windows.Forms.ListView
$LvUninstall.Dock = [System.Windows.Forms.DockStyle]::Fill
$LvUninstall.View = [System.Windows.Forms.View]::Details
$LvUninstall.CheckBoxes = $true
$LvUninstall.FullRowSelect = $true
$LvUninstall.GridLines = $true
$LvUninstall.SmallImageList = $UninstallImageList
$LvUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 8.8)
$LvUninstall.Columns.Add("Nama Aplikasi", 240) | Out-Null
$LvUninstall.Columns.Add("Versi", 85) | Out-Null
$LvUninstall.Columns.Add("Publisher", 150) | Out-Null
$UninstallTableHost.Controls.Add($LvUninstall)

$LvUninstall.Add_Resize({
    $w = $LvUninstall.ClientSize.Width
    if ($w -gt 200) {
        $LvUninstall.Columns[0].Width = [int]($w * 0.52)
        $LvUninstall.Columns[1].Width = [int]($w * 0.18)
        $LvUninstall.Columns[2].Width = $w - $LvUninstall.Columns[0].Width - $LvUninstall.Columns[1].Width - 2
    }
})

$script:InstalledAppsCache = @()

$LoadInstalledApps = {
    $rawApps = Invoke-AsyncTask -ScriptBlock {
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        Get-ItemProperty $regPaths -ErrorAction SilentlyContinue | Where-Object {
            (-not [string]::IsNullOrWhiteSpace($_.DisplayName)) -and
            ($_.SystemComponent -ne 1) -and
            (-not [string]::IsNullOrWhiteSpace($_.UninstallString) -or -not [string]::IsNullOrWhiteSpace($_.QuietUninstallString))
        } | Sort-Object DisplayName -Unique | Select-Object DisplayName, DisplayVersion, Publisher, DisplayIcon, InstallLocation, UninstallString, QuietUninstallString
    } -DisableControls @($btnRefreshUninstall)

    $UninstallImageList.Images.Clear()
    $UninstallImageList.Images.Add("default", $DefaultAppBitmap)

    $list = New-Object System.Collections.Generic.List[PSObject]
    $uIdx = 1
    foreach ($app in $rawApps) {
        $ver = if ($app.DisplayVersion) { $app.DisplayVersion.Trim() } else { "-" }
        $pub = if ($app.Publisher) { $app.Publisher.Trim() } else { "-" }

        $iconCandidate = $app.DisplayIcon
        if ([string]::IsNullOrWhiteSpace($iconCandidate) -and -not [string]::IsNullOrWhiteSpace($app.InstallLocation) -and (Test-Path $app.InstallLocation)) {
            $firstExe = Get-ChildItem -Path $app.InstallLocation -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($firstExe) { $iconCandidate = $firstExe.FullName }
        }
        if ([string]::IsNullOrWhiteSpace($iconCandidate)) {
            $iconCandidate = $app.UninstallString
        }

        $bmp = Resolve-AppIcon -RawPath $iconCandidate
        $key = "default"
        if ($bmp) {
            $key = "un_$uIdx"
            $UninstallImageList.Images.Add($key, $bmp)
            $uIdx++
        }

        $list.Add([PSCustomObject]@{
            DisplayName          = $app.DisplayName.Trim()
            Version              = $ver
            Publisher            = $pub
            UninstallString      = $app.UninstallString
            QuietUninstallString = $app.QuietUninstallString
            IconKey              = $key
        })
    }
    $script:InstalledAppsCache = $list.ToArray()
    & $RenderUninstallList
}

$RenderUninstallList = {
    $filter = $TxtSearchUninstall.Text.Trim()
    $LvUninstall.BeginUpdate()
    $LvUninstall.Items.Clear()
    foreach ($app in $script:InstalledAppsCache) {
        if ($filter -and ($app.DisplayName -notlike "*$filter*") -and ($app.Publisher -notlike "*$filter*")) { continue }
        $lvi = New-Object System.Windows.Forms.ListViewItem($app.DisplayName)
        $lvi.ImageKey = $app.IconKey
        $lvi.Tag = $app
        $lvi.SubItems.Add($app.Version) | Out-Null
        $lvi.SubItems.Add($app.Publisher) | Out-Null
        $LvUninstall.Items.Add($lvi) | Out-Null
    }
    $LvUninstall.EndUpdate()
}

$TxtSearchUninstall.Add_TextChanged($RenderUninstallList)
$btnRefreshUninstall.Add_Click({ & $LoadInstalledApps; Write-Log "Daftar aplikasi terinstal diperbarui ($($script:InstalledAppsCache.Count) aplikasi)." "INFO" })

$btnApplyUninstall = New-ActionButton $UninstallBottomBar "Uninstall Selected (Apply)" 8 4 265 34 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 31 15
$btnApplyUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 8.8, [System.Drawing.FontStyle]::Bold)
$btnApplyUninstall.Add_Click({
    if ($LvUninstall.CheckedItems.Count -eq 0) {
        Write-Log "Centang minimal 1 aplikasi yang ingin di-uninstall!" "WARN"
        return
    }

    $targets = @()
    foreach ($lvi in $LvUninstall.CheckedItems) {
        if ($lvi.Tag) { $targets += $lvi.Tag }
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Apakah Anda yakin ingin menghapus $($targets.Count) aplikasi terpilih secara berurutan?",
        "Konfirmasi Multi-Uninstall",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnApplyUninstall.Enabled = $false
    try {
        Write-Log "Memulai proses uninstall $($targets.Count) aplikasi (GUI tetap aktif)..." "INFO"
        foreach ($app in $targets) {
            Write-Log "Menghapus '$($app.DisplayName)'..." "INFO"
            try {
                if (-not [string]::IsNullOrWhiteSpace($app.QuietUninstallString)) {
                    $code = Invoke-ProcAsync -FilePath "cmd.exe" -ArgumentList "/c $($app.QuietUninstallString)" -NoNewWindow
                    Write-Log "'$($app.DisplayName)' selesai diproses (ExitCode: $code)." "SUCCESS"
                } elseif ($app.UninstallString -match "MsiExec\.exe\s*[/\-][IX]\s*(\{[0-9A-Fa-f\-]+\})") {
                    $guid = $Matches[1]
                    $code = Invoke-ProcAsync -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -NoNewWindow
                    Write-Log "'$($app.DisplayName)' (MSI) di-uninstall (ExitCode: $code)." "SUCCESS"
                } else {
                    $uCmd = $app.UninstallString.Trim()
                    $code = Invoke-ProcAsync -FilePath "cmd.exe" -ArgumentList "/c $uCmd"
                    Write-Log "'$($app.DisplayName)' selesai dijalankan (ExitCode: $code)." "SUCCESS"
                }
            } catch {
                Write-Log "Gagal menghapus '$($app.DisplayName)': $($_.Exception.Message)" "ERROR"
            }
        }
        Write-Log "Antrean uninstall selesai! Memperbarui daftar aplikasi..." "SUCCESS"
        & $LoadInstalledApps
    } finally {
        $btnApplyUninstall.Enabled = $true
    }
})

$btnClearUninstallSel = New-ActionButton $UninstallBottomBar "Clear Selection" 280 4 175 34 $null "shell32.dll" 131 15
$btnClearUninstallSel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnClearUninstallSel.Add_Click({
    foreach ($it in $LvUninstall.Items) { $it.Checked = $false }
})
# TAB 7: DRIVER MANAGER (TOP FILTER BAR + FILL TABLE + BOTTOM ACTION BAR)
# ==============================================================================
$TabDriver = New-Object System.Windows.Forms.TabPage
$TabDriver.Text = "Drivers"
$TabDriver.ImageKey = "driver"
$TabDriver.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabDriver)

$DriverImageList = New-Object System.Windows.Forms.ImageList
$DriverImageList.ImageSize = New-Object System.Drawing.Size(18, 18)
$DriverImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$DriverImageList.Images.Add("ok",      (Get-WinBitmap -Dll "imageres.dll" -Index 101 -Size 18))
$DriverImageList.Images.Add("update",  (Get-WinBitmap -Dll "shell32.dll"  -Index 46  -Size 18))
$DriverImageList.Images.Add("missing", (Get-WinBitmap -Dll "imageres.dll" -Index 79  -Size 18))

# Panel Atas: Filter Kategori, Check All / Uncheck All & Summary
$DriversTopBar = New-Object System.Windows.Forms.Panel
$DriversTopBar.Dock = [System.Windows.Forms.DockStyle]::Top
$DriversTopBar.Height = 42
$DriversTopBar.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabDriver.Controls.Add($DriversTopBar)

$LblDrvFilter = New-Object System.Windows.Forms.Label
$LblDrvFilter.Text = "Filter:"
$LblDrvFilter.Location = New-Object System.Drawing.Point(12, 12)
$LblDrvFilter.AutoSize = $true
$DriversTopBar.Controls.Add($LblDrvFilter)

$CmbDriverFilter = New-Object System.Windows.Forms.ComboBox
$CmbDriverFilter.Location = New-Object System.Drawing.Point(54, 9)
$CmbDriverFilter.Size = New-Object System.Drawing.Size(255, 24)
$CmbDriverFilter.DropDownStyle = "DropDownList"
$CmbDriverFilter.Items.AddRange(@(
    "Semua Kategori & Status",
    "Update / Belum Terinstall",
    "Missing / Unknown Devices (Butuh Driver)",
    "Display & Graphics (VGA / GPU)",
    "Network, Wi-Fi & Bluetooth",
    "Audio & Sound",
    "Biometric & Fingerprint",
    "Camera & Imaging",
    "Chipset, System & Storage",
    "Input, Touchpad & USB",
    "Printers & Other Devices"
))
$CmbDriverFilter.SelectedIndex = 0
$DriversTopBar.Controls.Add($CmbDriverFilter)

$btnCheckAllDrivers = New-ActionButton $DriversTopBar "Check All" 316 7 102 28 $null "imageres.dll" 101 14
$btnCheckAllDrivers.Font = New-Object System.Drawing.Font("Segoe UI", 8.2, [System.Drawing.FontStyle]::Bold)
$btnCheckAllDrivers.Add_Click({
    $LvDrivers.BeginUpdate()
    foreach ($it in $LvDrivers.Items) { $it.Checked = $true }
    $LvDrivers.EndUpdate()
    Write-Log "Semua driver yang tampil ($($LvDrivers.Items.Count) item) dicentang." "INFO"
})

$btnUncheckAllDrivers = New-ActionButton $DriversTopBar "Uncheck All" 424 7 112 28 $null "shell32.dll" 131 14
$btnUncheckAllDrivers.Font = New-Object System.Drawing.Font("Segoe UI", 8.2)
$btnUncheckAllDrivers.Add_Click({
    $LvDrivers.BeginUpdate()
    foreach ($it in $LvDrivers.Items) { $it.Checked = $false }
    $LvDrivers.EndUpdate()
    Write-Log "Semua centang driver dihapus." "INFO"
})

$LblDriverSummary = New-Object System.Windows.Forms.Label
$LblDriverSummary.Text = "Siap memindai driver..."
$LblDriverSummary.ForeColor = [System.Drawing.Color]::DimGray
$LblDriverSummary.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$LblDriverSummary.Location = New-Object System.Drawing.Point(546, 12)
$LblDriverSummary.AutoSize = $true
$DriversTopBar.Controls.Add($LblDriverSummary)

# Panel Bawah: Seluruh Tombol Aksi Driver (Selalu Terlihat Baik Normal Maupun Maximize)
$DriversBottomBar = New-Object System.Windows.Forms.Panel
$DriversBottomBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$DriversBottomBar.Height = 46
$DriversBottomBar.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabDriver.Controls.Add($DriversBottomBar)

# Wrapper Padding untuk Table ListView
$DriversTableHost = New-Object System.Windows.Forms.Panel
$DriversTableHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$DriversTableHost.Padding = New-Object System.Windows.Forms.Padding(12, 2, 12, 4)
$TabDriver.Controls.Add($DriversTableHost)
$DriversTableHost.BringToFront()

$LvDrivers = New-Object System.Windows.Forms.ListView
$LvDrivers.Dock = [System.Windows.Forms.DockStyle]::Fill
$LvDrivers.View = [System.Windows.Forms.View]::Details
$LvDrivers.CheckBoxes = $true
$LvDrivers.FullRowSelect = $true
$LvDrivers.GridLines = $true
$LvDrivers.ShowGroups = $true
$LvDrivers.SmallImageList = $DriverImageList
$LvDrivers.Font = New-Object System.Drawing.Font("Segoe UI", 8.8)
$LvDrivers.Columns.Add("Nama Perangkat / Paket Driver Kompatibel", 450) | Out-Null
$LvDrivers.Columns.Add("Status", 165) | Out-Null
$LvDrivers.Columns.Add("Versi / Hardware ID", 195) | Out-Null
$LvDrivers.Columns.Add("Provider / Ukuran", 210) | Out-Null
$DriversTableHost.Controls.Add($LvDrivers)

# Auto-Fit Lebar Kolom Tabel Driver saat Normal maupun Maximize
$LvDrivers.Add_Resize({
    $w = $LvDrivers.ClientSize.Width
    if ($w -gt 300) {
        $LvDrivers.Columns[0].Width = [int]($w * 0.44)
        $LvDrivers.Columns[1].Width = [int]($w * 0.16)
        $LvDrivers.Columns[2].Width = [int]($w * 0.19)
        $LvDrivers.Columns[3].Width = $w - ($LvDrivers.Columns[0].Width + $LvDrivers.Columns[1].Width + $LvDrivers.Columns[2].Width) - 2
    }
})

$script:DriverCacheList = @()

$DriverGroupOrder = @(
    "Missing / Unknown Devices (Butuh Driver)",
    "Display & Graphics (VGA / GPU)",
    "Network, Wi-Fi & Bluetooth",
    "Audio & Sound",
    "Biometric & Fingerprint",
    "Camera & Imaging",
    "Chipset, System & Storage",
    "Input, Touchpad & USB",
    "Printers & Other Devices"
)

$RenderDriverList = {
    $mode = if ($CmbDriverFilter.SelectedItem) { $CmbDriverFilter.SelectedItem.ToString() } else { "Semua Kategori & Status" }
    $LvDrivers.BeginUpdate()
    $LvDrivers.Items.Clear()
    $LvDrivers.Groups.Clear()

    $groupMap = @{}
    foreach ($gName in $DriverGroupOrder) {
        $lvg = New-Object System.Windows.Forms.ListViewGroup($gName, $gName)
        [void]$LvDrivers.Groups.Add($lvg)
        $groupMap[$gName] = $lvg
    }

    foreach ($d in $script:DriverCacheList) {
        if ($mode -eq "Update / Belum Terinstall" -and $d.StateType -ne "WUDriver") { continue }
        if (($DriverGroupOrder -contains $mode) -and ($d.HwGroup -ne $mode)) { continue }

        $lvi = New-Object System.Windows.Forms.ListViewItem($d.Title)
        $lvi.ImageKey = $d.IconKey
        $lvi.Tag = $d
        $lvi.SubItems.Add($d.StatusText) | Out-Null
        $lvi.SubItems.Add($d.VersionOrId) | Out-Null
        $lvi.SubItems.Add($d.ProviderOrSize) | Out-Null

        if ($groupMap.ContainsKey($d.HwGroup)) {
            $lvi.Group = $groupMap[$d.HwGroup]
        }

        if ($d.StateType -eq "MissingDevice") {
            $lvi.ForeColor = [System.Drawing.Color]::Crimson
            $lvi.Checked = $true
        } elseif ($d.StateType -eq "WUDriver") {
            $lvi.ForeColor = [System.Drawing.Color]::FromArgb(156, 100, 12)
            $lvi.Checked = $true
        }
        $LvDrivers.Items.Add($lvi) | Out-Null
    }
    $LvDrivers.EndUpdate()
}

$CmbDriverFilter.Add_SelectedIndexChanged($RenderDriverList)

$ScanDriversAction = {
    param([bool]$IncludeWindowsUpdate = $true)
    Write-Log "Memindai driver berdasarkan kategori hardware & Windows Update..." "INFO"
    $LblDriverSummary.Text = "Sedang memindai driver (Async)..."

    $scanOut = Invoke-AsyncTask -ScriptBlock {
        param($DoWU)
        function Resolve-HwCategory([string]$Name, [string]$DevClass, [bool]$IsMissing) {
            if ($IsMissing) { return "Missing / Unknown Devices (Butuh Driver)" }
            $txt = "$Name $DevClass"
            if ($txt -match "Biometric|Fingerprint|Goodix|Synaptics WBDI|Validity|ELAN WBF") { return "Biometric & Fingerprint" }
            if ($txt -match "Display|Graphics|NVIDIA|Radeon|AMD|Intel\(R\) UHD|Intel\(R\) Iris|VGA|Monitor") { return "Display & Graphics (VGA / GPU)" }
            if ($txt -match "Network|Wi-Fi|Wireless|Ethernet|Realtek PCIe|Bluetooth|LAN|802\.11|AX20|AX21|MediaTek Wi-Fi") { return "Network, Wi-Fi & Bluetooth" }
            if ($txt -match "Audio|Sound|Realtek\(R\) Audio|High Definition Audio|Microphone|Speaker|Conexant|Nahimic|Dolby") { return "Audio & Sound" }
            if ($txt -match "Camera|Webcam|Imaging|Integrated Camera|IR Camera|Scanner") { return "Camera & Imaging" }
            if ($txt -match "Chipset|System|ACPI|PCI|NVMe|SATA|AHCI|Storage|RAID|Thermal|Management Engine|SMBus|Serial IO") { return "Chipset, System & Storage" }
            if ($txt -match "HID|Touchpad|Mouse|Keyboard|USB|I2C|Precision Touchpad") { return "Input, Touchpad & USB" }
            return "Printers & Other Devices"
        }

        $items = @()

        $problemDevs = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
            $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22
        }
        foreach ($pd in $problemDevs) {
            $hwId = if ($pd.HardwareID -and $pd.HardwareID.Count -gt 0) { $pd.HardwareID[0] } else { $pd.DeviceID }
            $dName = if ([string]::IsNullOrWhiteSpace($pd.Name)) { "Unknown Device ($hwId)" } else { $pd.Name }
            $items += [PSCustomObject]@{
                Title          = $dName
                StatusText     = "Belum Terinstall (Err:$($pd.ConfigManagerErrorCode))"
                VersionOrId    = $hwId
                ProviderOrSize = if ($pd.Manufacturer) { $pd.Manufacturer } else { "Unknown Vendor" }
                StateType      = "MissingDevice"
                HwGroup        = "Missing / Unknown Devices (Butuh Driver)"
                IconKey        = "missing"
                UpdateId       = $null
            }
        }

        if ($DoWU) {
            try {
                $session = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                $searchResult = $searcher.Search("IsInstalled=0 and Type='Driver'")
                foreach ($upd in $searchResult.Updates) {
                    $sizeMB = [math]::Round(($upd.MaxDownloadSize / 1MB), 2)
                    $ver = if ($upd.DriverVerDate) { $upd.DriverVerDate.ToString("yyyy-MM-dd") } else { "Compatible Driver" }
                    $prov = if ($upd.DriverManufacturer) { "$($upd.DriverManufacturer) ($sizeMB MB)" } else { "$sizeMB MB" }
                    $grpName = Resolve-HwCategory -Name $upd.Title -DevClass $upd.DriverClass -IsMissing $false
                    $items += [PSCustomObject]@{
                        Title          = $upd.Title
                        StatusText     = "Tersedia (Install / Update)"
                        VersionOrId    = $ver
                        ProviderOrSize = $prov
                        StateType      = "WUDriver"
                        HwGroup        = $grpName
                        IconKey        = "update"
                        UpdateId       = $upd.Identity.UpdateID
                    }
                }
            } catch {}
        }

        $signed = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.DeviceName) -and $_.DeviceClass -notin @("LEGACYDRIVER","VOLUME","SOFTWARECOMPONENT")
        } | Sort-Object DeviceName -Unique

        foreach ($sd in $signed) {
            $grpName = Resolve-HwCategory -Name $sd.DeviceName -DevClass $sd.DeviceClass -IsMissing $false
            $items += [PSCustomObject]@{
                Title          = $sd.DeviceName
                StatusText     = "Terpasang (Aktif)"
                VersionOrId    = if ($sd.DriverVersion) { "v$($sd.DriverVersion)" } else { "-" }
                ProviderOrSize = if ($sd.DriverProviderName) { $sd.DriverProviderName } else { "-" }
                StateType      = "InstalledDriver"
                HwGroup        = $grpName
                IconKey        = "ok"
                UpdateId       = $null
            }
        }

        return $items
    } -Parameters @{ DoWU = $IncludeWindowsUpdate } -DisableControls @($btnScanDrivers, $btnInstallDrivers)

    if ($scanOut) {
        $script:DriverCacheList = $scanOut
        $cntMissing = ($scanOut | Where-Object { $_.StateType -eq "MissingDevice" }).Count
        $cntWU      = ($scanOut | Where-Object { $_.StateType -eq "WUDriver" }).Count
        $cntInst    = ($scanOut | Where-Object { $_.StateType -eq "InstalledDriver" }).Count
        $LblDriverSummary.Text = "Missing: $cntMissing | Update/Kompatibel: $cntWU | Terpasang: $cntInst"
        Write-Log "Scan Driver selesai: $cntMissing missing, $cntWU update/kompatibel tersedia, $cntInst terpasang." "SUCCESS"
        & $RenderDriverList
    }
}

$btnScanDrivers = New-ActionButton $DriversBottomBar "Scan Driver Kompatibel & Update" 12 5 250 36 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 238 16
$btnScanDrivers.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnScanDrivers.Add_Click({ & $ScanDriversAction -IncludeWindowsUpdate $true })

$btnInstallDrivers = New-ActionButton $DriversBottomBar "Install / Update Selected Drivers" 270 5 250 36 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 162 16
$btnInstallDrivers.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnInstallDrivers.Add_Click({
    $checked = @()
    foreach ($lvi in $LvDrivers.CheckedItems) {
        if ($lvi.Tag) { $checked += $lvi.Tag }
    }
    if ($checked.Count -eq 0) {
        Write-Log "Centang minimal 1 driver pada daftar terlebih dahulu!" "WARN"
        return
    }

    $wuTargets = @($checked | Where-Object { $_.StateType -eq "WUDriver" -and $_.UpdateId } | ForEach-Object { $_.UpdateId })
    $hasMissing = ($checked | Where-Object { $_.StateType -eq "MissingDevice" }).Count -gt 0

    Write-Log "Memulai proses instalasi / update driver terpilih (GUI tetap aktif)..." "INFO"

    if ($wuTargets.Count -gt 0) {
        $installRes = Invoke-AsyncTask -ScriptBlock {
            param($TargetIds)
            $logs = @()
            try {
                $session = New-Object -ComObject Microsoft.Update.Session
                $searcher = $session.CreateUpdateSearcher()
                $searchResult = $searcher.Search("IsInstalled=0 and Type='Driver'")
                $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
                foreach ($u in $searchResult.Updates) {
                    if ($TargetIds -contains $u.Identity.UpdateID) {
                        if (-not $u.EulaAccepted) { $u.AcceptEula() }
                        [void]$toDownload.Add($u)
                    }
                }
                if ($toDownload.Count -gt 0) {
                    $downloader = $session.CreateUpdateDownloader()
                    $downloader.Updates = $toDownload
                    [void]$downloader.Download()

                    $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
                    foreach ($u in $toDownload) {
                        if ($u.IsDownloaded) { [void]$toInstall.Add($u) }
                    }
                    if ($toInstall.Count -gt 0) {
                        $installer = $session.CreateUpdateInstaller()
                        $installer.Updates = $toInstall
                        $res = $installer.Install()
                        $logs += "Instalasi $($toInstall.Count) driver selesai (ResultCode: $($res.ResultCode), RebootRequired: $($res.RebootRequired))."
                    }
                }
            } catch {
                $logs += "ERROR: $($_.Exception.Message)"
            }
            return $logs
        } -Parameters @{ TargetIds = $wuTargets } -DisableControls @($btnScanDrivers, $btnInstallDrivers)

        foreach ($line in $installRes) {
            if ($line -like "ERROR*") { Write-Log $line "ERROR" } else { Write-Log $line "SUCCESS" }
        }
    }

    if ($hasMissing -or $wuTargets.Count -eq 0) {
        Write-Log "Memicu pemindaian ulang perangkat Plug-and-Play (pnputil /scan-devices)..." "INFO"
        Invoke-ProcAsync -FilePath "pnputil.exe" -ArgumentList "/scan-devices" -NoNewWindow | Out-Null
        Write-Log "Pemindaian PnP selesai." "SUCCESS"
    }

    & $ScanDriversAction -IncludeWindowsUpdate $true
})

$btnInstallInf = New-ActionButton $DriversBottomBar "Install Driver dari Folder (INF)" 528 5 250 36 $null "shell32.dll" 4 16
$btnInstallInf.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Pilih folder yang berisi file driver (.inf) untuk diinstal ke sistem:"
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $folder = $fbd.SelectedPath
        Write-Log "Menginstal semua driver .INF dari '$folder' menggunakan pnputil..." "INFO"
        $code = Invoke-ProcAsync -FilePath "pnputil.exe" -ArgumentList "/add-driver `"$folder\*.inf`" /subdirs /install" -NoNewWindow
        if ($code -eq 0 -or $code -eq 3010) {
            Write-Log "Driver dari folder '$folder' berhasil diinstal (ExitCode: $code)." "SUCCESS"
        } else {
            Write-Log "pnputil selesai dengan kode: $code" "WARN"
        }
        & $ScanDriversAction -IncludeWindowsUpdate $false
    }
})

$btnBackupDrivers = New-ActionButton $DriversBottomBar "Backup All 3rd-Party Drivers" 786 5 264 36 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "shell32.dll" 6 16
$btnBackupDrivers.Add_Click({
    $model = ((Get-CimInstance Win32_ComputerSystem).Model -replace '[\\/:*?"<>|]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($model)) { $model = "Laptop" }
    $backupDir = Join-Path $ScriptDir "DriverBackup_$model"
    if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }

    Write-Log "Mem-backup seluruh driver pihak ketiga ke '$backupDir'..." "INFO"
    $btnBackupDrivers.Enabled = $false
    try {
        $code = Invoke-ProcAsync -FilePath "pnputil.exe" -ArgumentList "/export-driver * `"$backupDir`"" -NoNewWindow
        if ($code -eq 0) {
            Write-Log "Backup driver selesai! Tersimpan di: $backupDir" "SUCCESS"
        } else {
            Write-Log "Backup driver selesai dengan kode: $code" "WARN"
        }
    } finally {
        $btnBackupDrivers.Enabled = $true
    }
})
# TAB 8: TROUBLESHOOT & AUTO-REPAIR (HARDWARE & SOFTWARE - 2x6 GRID TANPA GAP)
# ==============================================================================
$TabTroubleshoot = New-Object System.Windows.Forms.TabPage
$TabTroubleshoot.Text = "Troubleshoot"
$TabTroubleshoot.ImageKey = "troubleshoot"
$TabTroubleshoot.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabTroubleshoot)

$TsOuterHost = New-Object System.Windows.Forms.Panel
$TsOuterHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$TsOuterHost.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 8)
$TabTroubleshoot.Controls.Add($TsOuterHost)

$TsGrid = New-Object System.Windows.Forms.TableLayoutPanel
$TsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$TsGrid.ColumnCount = 2
$TsGrid.RowCount = 1
[void]$TsGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$TsGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$TsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$TsOuterHost.Controls.Add($TsGrid)

function New-TsCardsGrid {
    param($ParentGroup)
    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tbl.ColumnCount = 2
    $tbl.RowCount = 6
    $tbl.Margin = New-Object System.Windows.Forms.Padding(0)
    $tbl.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    for ($r = 0; $r -lt 6; $r++) {
        [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 16.6667)))
    }
    $ParentGroup.Controls.Add($tbl)
    return $tbl
}

$GrpTsHwOuter = New-Object System.Windows.Forms.GroupBox
$GrpTsHwOuter.Text = "Hardware && Peripherals Troubleshooter (Klik untuk Perbaikan Otomatis)"
$GrpTsHwOuter.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpTsHwOuter.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpTsHwOuter.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
$GrpTsHwOuter.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 4)
$TsGrid.Controls.Add($GrpTsHwOuter, 0, 0)
$GrpTsHw = New-TsCardsGrid -ParentGroup $GrpTsHwOuter

$GrpTsSwOuter = New-Object System.Windows.Forms.GroupBox
$GrpTsSwOuter.Text = "Software, OS && System Services Troubleshooter (Klik untuk Perbaikan Otomatis)"
$GrpTsSwOuter.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpTsSwOuter.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpTsSwOuter.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
$GrpTsSwOuter.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 4)
$TsGrid.Controls.Add($GrpTsSwOuter, 1, 0)
$GrpTsSw = New-TsCardsGrid -ParentGroup $GrpTsSwOuter

function New-TroubleshootCard {
    param(
        $ParentGrid,
        [int]$Col,
        [int]$Row,
        [string]$Title,
        [string]$Desc,
        [string]$IconDll,
        [int]$IconIndex,
        [scriptblock]$OnClickAction
    )
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = [System.Windows.Forms.DockStyle]::Fill
    $card.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $card.BackColor = [System.Drawing.Color]::White
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $card.Cursor = [System.Windows.Forms.Cursors]::Hand

    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.Location = New-Object System.Drawing.Point(8, 12)
    $pb.Size = New-Object System.Drawing.Size(26, 26)
    $pb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
    $bmp = Get-WinBitmap -Dll $IconDll -Index $IconIndex -Size 26
    if ($bmp) { $pb.Image = $bmp }
    $card.Controls.Add($pb)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = $Title
    $lblTitle.UseMnemonic = $false
    $lblTitle.AutoEllipsis = $true
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(24, 34, 56)
    $lblTitle.Location = New-Object System.Drawing.Point(40, 4)
    $lblTitle.Size = New-Object System.Drawing.Size(180, 16)
    $card.Controls.Add($lblTitle)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = $Desc
    $lblDesc.UseMnemonic = $false
    $lblDesc.Font = New-Object System.Drawing.Font("Segoe UI", 7.3)
    $lblDesc.ForeColor = [System.Drawing.Color]::FromArgb(80, 90, 105)
    $lblDesc.Location = New-Object System.Drawing.Point(40, 20)
    $lblDesc.Size = New-Object System.Drawing.Size(180, 28)
    $card.Controls.Add($lblDesc)

    $card.Add_Resize({
        $availW = $card.ClientSize.Width - 44
        if ($availW -gt 40) {
            $lblTitle.Width = $availW
            $lblDesc.Width  = $availW
        }
        $pb.Top = [int](($card.ClientSize.Height - $pb.Height) / 2)
    }.GetNewClosure())

    $hoverIn  = { $card.BackColor = [System.Drawing.Color]::FromArgb(235, 245, 255) }.GetNewClosure()
    $hoverOut = { $card.BackColor = [System.Drawing.Color]::White }.GetNewClosure()
    $clickRun = {
        $card.Enabled = $false
        $card.BackColor = [System.Drawing.Color]::FromArgb(220, 230, 242)
        try {
            & $OnClickAction
        } finally {
            $card.BackColor = [System.Drawing.Color]::White
            $card.Enabled = $true
        }
    }.GetNewClosure()

    foreach ($c in @($card, $pb, $lblTitle, $lblDesc)) {
        $c.Add_MouseEnter($hoverIn)
        $c.Add_MouseLeave($hoverOut)
        $c.Add_Click($clickRun)
    }

    $ParentGrid.Controls.Add($card, $Col, $Row)
}

$HwTroubleshooters = @(
    @{ Title="Fix Audio & Sound";        Desc="Restart Audiosrv & aktifkan ulang perangkat suara";      Dll="mmsys.cpl";    Idx=0;   Act={
        Write-Log "Memperbaiki layanan Audio & Sound..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Restart-Service AudioEndpointBuilder, Audiosrv -Force -ErrorAction SilentlyContinue
            Get-PnpDevice -Class AudioEndpoint, MEDIA -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Layanan Audio & Sound berhasil di-restart!" "SUCCESS"
    }},
    @{ Title="Fix Fingerprint & Hello";  Desc="Reset layanan biometrik (WbioSrvc) & sensor sidik jari";  Dll="imageres.dll"; Idx=77;  Act={
        Write-Log "Mereset layanan Windows Biometric (Fingerprint / Face)..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Stop-Service WbioSrvc -Force -ErrorAction SilentlyContinue
            Get-PnpDevice -Class Biometric -ErrorAction SilentlyContinue | Disable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 700
            Get-PnpDevice -Class Biometric -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
            Start-Service WbioSrvc -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Sensor Fingerprint & layanan WbioSrvc berhasil disegarkan!" "SUCCESS"
    }},
    @{ Title="Fix Wi-Fi & WLAN Adapter"; Desc="Restart WlanSvc & segarkan kartu jaringan nirkabel";     Dll="shell32.dll";  Idx=18;  Act={
        Write-Log "Mereset layanan WLAN AutoConfig & adapter Wi-Fi..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Restart-Service WlanSvc -Force -ErrorAction SilentlyContinue
            Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match "Wi-Fi|Wireless|802\.11" } | Restart-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Adapter Wi-Fi & WlanSvc berhasil di-restart!" "SUCCESS"
    }},
    @{ Title="Fix Bluetooth Service";    Desc="Restart bthserv & sambungkan ulang modul Bluetooth";      Dll="fsquirt.exe";  Idx=0;   Act={
        Write-Log "Mereset layanan Bluetooth Support..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Restart-Service bthserv -Force -ErrorAction SilentlyContinue
            Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Layanan Bluetooth berhasil disegarkan!" "SUCCESS"
    }},
    @{ Title="Fix Camera & Webcam";      Desc="Buka blokir privasi kamera & restart FrameServer";       Dll="imageres.dll"; Idx=67;  Act={
        Write-Log "Memperbaiki akses privasi & layanan Webcam..." "INFO"
        $p = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
        if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
        Set-ItemProperty $p "Value" "Allow" -Type String -ErrorAction SilentlyContinue
        Invoke-AsyncTask -ScriptBlock {
            Restart-Service FrameServer -Force -ErrorAction SilentlyContinue
            Get-PnpDevice -Class Camera, Image -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Privasi Webcam diizinkan & layanan kamera di-restart!" "SUCCESS"
    }},
    @{ Title="Fix Touchpad & HID";       Desc="Aktifkan ulang driver Touchpad, Mouse & HID Input";      Dll="main.cpl";     Idx=0;   Act={
        Write-Log "Menyegarkan perangkat HID & Touchpad..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Get-PnpDevice -Class HIDClass, Mouse -Status Error -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
            pnputil.exe /scan-devices | Out-Null
        } | Out-Null
        Write-Log "Pemindaian & aktivasi HID / Touchpad selesai!" "SUCCESS"
    }},
    @{ Title="Fix Battery & Power";      Desc="Reset skema daya & buat laporan baterai di Desktop";     Dll="powercpl.dll"; Idx=0;   Act={
        $rep = "$env:USERPROFILE\Desktop\Battery_Report.html"
        Write-Log "Mereset skema power & membuat Battery Report..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            param($outHtml)
            powercfg -restoredefaultschemes | Out-Null
            powercfg /batteryreport /output $outHtml | Out-Null
        } -Parameters @{ outHtml = $rep } | Out-Null
        Write-Log "Power scheme di-reset & laporan disimpan di: $rep" "SUCCESS"
    }},
    @{ Title="Fix Printer Spooler";      Desc="Hapus antrean cetak macet & restart Print Spooler";      Dll="shell32.dll";  Idx=16;  Act={
        Write-Log "Membersihkan antrean Print Spooler..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Stop-Service Spooler -Force -ErrorAction SilentlyContinue
            Remove-Item "C:\Windows\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
            Start-Service Spooler -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Antrean cetak dibersihkan & Print Spooler aktif kembali!" "SUCCESS"
    }},
    @{ Title="Fix USB Port Suspend";     Desc="Cegah Windows mematikan daya port USB / dongle";        Dll="shell32.dll";  Idx=7;   Act={
        Write-Log "Menonaktifkan USB Selective Suspend..." "INFO"
        powercfg /SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
        powercfg /SETACTIVE SCHEME_CURRENT 2>$null
        Write-Log "USB Selective Suspend dinonaktifkan!" "SUCCESS"
    }},
    @{ Title="Fix Display & GPU";        Desc="Segarkan Display Adapter saat layar berkedip/blank";      Dll="desk.cpl";     Idx=0;   Act={
        Write-Log "Menyegarkan perangkat Display / GPU..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Get-PnpDevice -Class Display -Status Error -ErrorAction SilentlyContinue | Enable-PnpDevice -Confirm:$false -ErrorAction SilentlyContinue
            pnputil.exe /scan-devices | Out-Null
        } | Out-Null
        Write-Log "Display Adapter & PnP layar selesai disegarkan!" "SUCCESS"
    }},
    @{ Title="Re-Scan PnP Hardware";     Desc="Paksa Windows deteksi ulang hardware yang baru colok";    Dll="devmgr.dll";   Idx=4;   Act={
        Write-Log "Memindai ulang seluruh perangkat Plug & Play..." "INFO"
        Invoke-ProcAsync -FilePath "pnputil.exe" -ArgumentList "/scan-devices" -NoNewWindow | Out-Null
        Write-Log "Pemindaian hardware Plug & Play selesai!" "SUCCESS"
    }},
    @{ Title="Win Device Diagnostic";    Desc="Buka wizard diagnostik hardware bawaan Windows";        Dll="imageres.dll"; Idx=102; Act={
        Start-Process "msdt.exe" -ArgumentList "-id DeviceDiagnostic"
        Write-Log "Wizard Hardware and Devices Troubleshooter dibuka." "INFO"
    }}
)

for ($i = 0; $i -lt $HwTroubleshooters.Count; $i++) {
    $item = $HwTroubleshooters[$i]
    $c = $i % 2
    $r = [int][Math]::Floor($i / 2)
    New-TroubleshootCard -ParentGrid $GrpTsHw -Col $c -Row $r -Title $item.Title -Desc $item.Desc -IconDll $item.Dll -IconIndex $item.Idx -OnClickAction $item.Act
}

$SwTroubleshooters = @(
    @{ Title="Fix Explorer & Icon";      Desc="Restart Taskbar/Desktop & bersihkan cache ikon";        Dll="explorer.exe"; Idx=0;   Act={
        Write-Log "Merestart Windows Explorer & menyegarkan icon cache..." "INFO"
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Process "explorer.exe"
        Write-Log "Windows Explorer berhasil di-restart!" "SUCCESS"
    }},
    @{ Title="Fix Start Menu & Search";  Desc="Atasi Start Menu macet & kolom pencarian tidak jalan";   Dll="shell32.dll";  Idx=22;  Act={
        Write-Log "Merestart layanan Windows Search & StartMenuExperienceHost..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Restart-Service WSearch -Force -ErrorAction SilentlyContinue
            Get-Process StartMenuExperienceHost, SearchHost, SearchApp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Start Menu & Windows Search berhasil disegarkan!" "SUCCESS"
    }},
    @{ Title="Fix Windows Update";       Desc="Hapus cache SoftwareDistribution & restart service";    Dll="shell32.dll";  Idx=238; Act={
        Write-Log "Membersihkan cache Windows Update & merestart service..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Stop-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
            Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service cryptsvc, bits, wuauserv -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Windows Update service & cache berhasil diperbaiki!" "SUCCESS"
    }},
    @{ Title="Fix Microsoft Store";      Desc="Reset cache Store (wsreset) jika gagal download app";   Dll="appwiz.cpl";   Idx=0;   Act={
        Start-Process "wsreset.exe"
        Write-Log "Menjalankan wsreset.exe untuk mereset cache Microsoft Store..." "INFO"
    }},
    @{ Title="Fix Network & DNS";        Desc="Flush DNS, reset Winsock & perbarui IP internet";       Dll="shell32.dll";  Idx=18;  Act={
        Write-Log "Melakukan Flush DNS, Reset Winsock & Renew IP..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            ipconfig /flushdns | Out-Null
            netsh winsock reset | Out-Null
            ipconfig /renew | Out-Null
        } | Out-Null
        Write-Log "Konfigurasi DNS & Winsock jaringan diperbarui!" "SUCCESS"
    }},
    @{ Title="Fix Windows Installer";    Desc="Daftarkan ulang layanan MSI jika gagal install app";    Dll="shell32.dll";  Idx=162; Act={
        Write-Log "Mendaftarkan ulang Windows Installer (msiexec)..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            msiexec.exe /unregister | Out-Null
            msiexec.exe /regserver | Out-Null
            Start-Service msiserver -ErrorAction SilentlyContinue
        } | Out-Null
        Write-Log "Layanan Windows Installer (MSI) aktif & terdaftar ulang!" "SUCCESS"
    }},
    @{ Title="Cek BSOD Minidump";        Desc="Periksa riwayat file crash Blue Screen terbaru";        Dll="shell32.dll";  Idx=70;  Act={
        $dumps = Get-ChildItem "C:\Windows\Minidump\*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
        if ($dumps) {
            foreach ($d in $dumps) {
                Write-Log "BSOD Dump ditemukan: $($d.Name) | Waktu: $($d.LastWriteTime)" "WARN"
            }
        } else {
            Write-Log "Tidak ditemukan file crash BSOD di C:\Windows\Minidump (Sistem Stabil)." "SUCCESS"
        }
    }},
    @{ Title="Fix System Files (SFC)";   Desc="Pindai & perbaiki file sistem Windows yang rusak";      Dll="imageres.dll"; Idx=102; Act={
        Start-Process "cmd.exe" -ArgumentList "/k sfc /scannow"
        Write-Log "Menjalankan System File Checker (sfc /scannow)..." "INFO"
    }},
    @{ Title="Fix Win Image (DISM)";     Desc="Pulihkan komponen inti Windows via DISM online";        Dll="imageres.dll"; Idx=101; Act={
        Start-Process "cmd.exe" -ArgumentList "/k DISM /Online /Cleanup-Image /RestoreHealth"
        Write-Log "Menjalankan DISM RestoreHealth..." "INFO"
    }},
    @{ Title="Fix Time Sync & NTP";      Desc="Sinkronisasi jam sistem agar browser/SSL tidak error";  Dll="timedate.cpl"; Idx=0;   Act={
        Write-Log "Menyinkronkan waktu sistem dengan server NTP..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            Start-Service w32time -ErrorAction SilentlyContinue
            w32tm /resync /force | Out-Null
        } | Out-Null
        Write-Log "Jam & zona waktu sistem berhasil disinkronkan!" "SUCCESS"
    }},
    @{ Title="Fix Core Services";        Desc="Pastikan Task Scheduler, DHCP, DNS & EventLog aktif";   Dll="shell32.dll";  Idx=43;  Act={
        Write-Log "Memastikan layanan inti Windows dalam status Running..." "INFO"
        Invoke-AsyncTask -ScriptBlock {
            foreach ($svc in @("Schedule","Dhcp","Dnscache","EventLog","RpcSs","Winmgmt")) {
                Set-Service $svc -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service $svc -ErrorAction SilentlyContinue
            }
        } | Out-Null
        Write-Log "Seluruh layanan inti Windows dipastikan aktif!" "SUCCESS"
    }},
    @{ Title="System Health Report";     Desc="Buat diagnosa kesehatan lengkap laptop (60 detik)";      Dll="imageres.dll"; Idx=109; Act={
        Start-Process "perfmon.exe" -ArgumentList "/report"
        Write-Log "Membuka Windows Resource and Performance Monitor Report..." "INFO"
    }}
)

for ($i = 0; $i -lt $SwTroubleshooters.Count; $i++) {
    $item = $SwTroubleshooters[$i]
    $c = $i % 2
    $r = [int][Math]::Floor($i / 2)
    New-TroubleshootCard -ParentGrid $GrpTsSw -Col $c -Row $r -Title $item.Title -Desc $item.Desc -IconDll $item.Dll -IconIndex $item.Idx -OnClickAction $item.Act
}
# TAB 9: HARDWARE SCAN & INTERACTIVE QC DIAGNOSTICS + REPORT GENERATOR
# ==============================================================================
$TabHwScan = New-Object System.Windows.Forms.TabPage
$TabHwScan.Text = "HW Scan"
$TabHwScan.ImageKey = "hwscan"
$TabHwScan.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabHwScan.Padding = New-Object System.Windows.Forms.Padding(8)
$TabControl.Controls.Add($TabHwScan)

$HwGrid = New-Object System.Windows.Forms.TableLayoutPanel
$HwGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$HwGrid.ColumnCount = 2
$HwGrid.RowCount = 1
[void]$HwGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 53)))
[void]$HwGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 47)))
[void]$HwGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$TabHwScan.Controls.Add($HwGrid)

# --- KOLOM KIRI: DAFTAR PENGECEKAN HARDWARE (TABLE DOCK FILL + BOTTOM BAR) ---
$GrpHwChecklist = New-Object System.Windows.Forms.GroupBox
$GrpHwChecklist.Text = "Daftar Pengecekan Hardware & Status Sensor"
$GrpHwChecklist.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpHwChecklist.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpHwChecklist.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
$HwGrid.Controls.Add($GrpHwChecklist, 0, 0)

$HwLeftBottomBar = New-Object System.Windows.Forms.Panel
$HwLeftBottomBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$HwLeftBottomBar.Height = 44
$GrpHwChecklist.Controls.Add($HwLeftBottomBar)

$HwTableHost = New-Object System.Windows.Forms.Panel
$HwTableHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$HwTableHost.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
$GrpHwChecklist.Controls.Add($HwTableHost)
$HwTableHost.BringToFront()

$LvHwScan = New-Object System.Windows.Forms.ListView
$LvHwScan.Dock = [System.Windows.Forms.DockStyle]::Fill
$LvHwScan.View = [System.Windows.Forms.View]::Details
$LvHwScan.FullRowSelect = $true
$LvHwScan.GridLines = $true
$LvHwScan.Font = New-Object System.Drawing.Font("Segoe UI", 8.6)
$LvHwScan.Columns.Add("Komponen Hardware", 155) | Out-Null
$LvHwScan.Columns.Add("Deteksi Perangkat / Sensor", 250) | Out-Null
$LvHwScan.Columns.Add("Hasil QC", 105) | Out-Null
$HwTableHost.Controls.Add($LvHwScan)

$LvHwScan.Add_Resize({
    $w = $LvHwScan.ClientSize.Width
    if ($w -gt 200) {
        $LvHwScan.Columns[0].Width = [int]($w * 0.30)
        $LvHwScan.Columns[1].Width = [int]($w * 0.49)
        $LvHwScan.Columns[2].Width = $w - $LvHwScan.Columns[0].Width - $LvHwScan.Columns[1].Width - 2
    }
})

$script:HwScanState = [ordered]@{
    "LCD"         = @{ Name="LCD / Layar Monitor";   Detected="Belum dipindai"; Result="UNTESTED" }
    "Speaker"     = @{ Name="Speaker Stereo (L/R)";  Detected="Belum dipindai"; Result="UNTESTED" }
    "Microphone"  = @{ Name="Microphone Input";      Detected="Belum dipindai"; Result="UNTESTED" }
    "Keyboard"    = @{ Name="Keyboard Internal";     Detected="Belum dipindai"; Result="UNTESTED" }
    "Touchpad"    = @{ Name="Touchpad / Mouse";      Detected="Belum dipindai"; Result="UNTESTED" }
    "Webcam"      = @{ Name="Webcam / Kamera";       Detected="Belum dipindai"; Result="UNTESTED" }
    "Fingerprint" = @{ Name="Fingerprint Reader";    Detected="Belum dipindai"; Result="UNTESTED" }
    "FaceRec"     = @{ Name="Face Recognition (IR)"; Detected="Belum dipindai"; Result="UNTESTED" }
    "Battery"     = @{ Name="Battery Health";        Detected="Belum dipindai"; Result="UNTESTED" }
    "Storage"     = @{ Name="Storage / SSD Health";  Detected="Belum dipindai"; Result="UNTESTED" }
    "Network"     = @{ Name="Wi-Fi & Bluetooth";     Detected="Belum dipindai"; Result="UNTESTED" }
}

function Update-HwScanListView {
    $LvHwScan.BeginUpdate()
    $LvHwScan.Items.Clear()
    foreach ($k in $script:HwScanState.Keys) {
        $item = $script:HwScanState[$k]
        $lvi = New-Object System.Windows.Forms.ListViewItem($item.Name)
        $lvi.Tag = $k
        $lvi.SubItems.Add($item.Detected) | Out-Null
        $lvi.SubItems.Add($item.Result) | Out-Null

        switch ($item.Result) {
            "PASS"          { $lvi.ForeColor = [System.Drawing.Color]::ForestGreen }
            "FAIL"          { $lvi.ForeColor = [System.Drawing.Color]::Crimson }
            "NOT SUPPORTED" { $lvi.ForeColor = [System.Drawing.Color]::DimGray }
            default         { $lvi.ForeColor = [System.Drawing.Color]::FromArgb(180, 95, 6) }
        }
        $LvHwScan.Items.Add($lvi) | Out-Null
    }
    $LvHwScan.EndUpdate()
}

function Set-HwResult {
    param([string]$Key, [string]$Result, [string]$Detail = $null)
    if ($script:HwScanState.Contains($Key)) {
        $script:HwScanState[$Key].Result = $Result
        if ($Detail) { $script:HwScanState[$Key].Detected = $Detail }
        Update-HwScanListView
        Write-Log "Hardware QC [$($script:HwScanState[$Key].Name)] -> $Result" $(if($Result -eq "PASS"){"SUCCESS"}elseif($Result -eq "FAIL"){"ERROR"}else{"INFO"})
    }
}

$btnAutoDetectHw = New-ActionButton $HwLeftBottomBar "1. Auto-Scan Semua Hardware" 8 4 295 34 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 238 15
$btnAutoDetectHw.Font = New-Object System.Drawing.Font("Segoe UI", 8.6, [System.Drawing.FontStyle]::Bold)

$btnExportHwReport = New-ActionButton $HwLeftBottomBar "2. Buat Laporan QC" 310 4 215 34 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 70 15
$btnExportHwReport.Font = New-Object System.Drawing.Font("Segoe UI", 8.6, [System.Drawing.FontStyle]::Bold)

# --- KOLOM KANAN: PENGUJIAN INTERAKTIF KOMPONEN ---
$GrpHwInteractive = New-Object System.Windows.Forms.GroupBox
$GrpHwInteractive.Text = "Pengujian Interaktif Komponen & Tombol Verifikasi"
$GrpHwInteractive.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpHwInteractive.Dock = [System.Windows.Forms.DockStyle]::Fill
$GrpHwInteractive.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
$HwGrid.Controls.Add($GrpHwInteractive, 1, 0)

$HwRightBottomBar = New-Object System.Windows.Forms.Panel
$HwRightBottomBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$HwRightBottomBar.Height = 44
$GrpHwInteractive.Controls.Add($HwRightBottomBar)

$HwInteractiveScroll = New-Object System.Windows.Forms.Panel
$HwInteractiveScroll.Dock = [System.Windows.Forms.DockStyle]::Fill
$HwInteractiveScroll.AutoScroll = $true
$GrpHwInteractive.Controls.Add($HwInteractiveScroll)
$HwInteractiveScroll.BringToFront()

# Tombol-tombol Uji Interaktif
$btnTestLcd = New-ActionButton $HwInteractiveScroll "Test LCD (Dead Pixel)" 10 6 225 34 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "imageres.dll" 109 15
$btnTestLcd.Add_Click({
    $lcdForm = New-Object System.Windows.Forms.Form
    $lcdForm.FormBorderStyle = "None"
    $lcdForm.WindowState = "Maximized"
    $lcdForm.TopMost = $true
    $lcdForm.BackColor = [System.Drawing.Color]::Red
    $lcdForm.Cursor = [System.Windows.Forms.Cursors]::Hand

    $colors = @(
        @{ C=[System.Drawing.Color]::Red;   N="MERAH (Red) - Cek sub-pixel mati" },
        @{ C=[System.Drawing.Color]::Lime;  N="HIJAU (Green) - Cek sub-pixel mati" },
        @{ C=[System.Drawing.Color]::Blue;  N="BIRU (Blue) - Cek sub-pixel mati" },
        @{ C=[System.Drawing.Color]::White; N="PUTIH (White) - Cek noda / backlight bleed / kotoran" },
        @{ C=[System.Drawing.Color]::Black; N="HITAM (Black) - Cek stuck pixel / light bleed" }
    )
    $script:lcdIdx = 0

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "LCD TEST: $($colors[0].N)`n[Klik Layar / Spasi = Ganti Warna | ESC = Selesai]"
    $lblHint.AutoSize = $true
    $lblHint.BackColor = [System.Drawing.Color]::FromArgb(180, 0, 0, 0)
    $lblHint.ForeColor = [System.Drawing.Color]::White
    $lblHint.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblHint.Padding = New-Object System.Windows.Forms.Padding(12)
    $lblHint.Location = New-Object System.Drawing.Point(25, 25)
    $lcdForm.Controls.Add($lblHint)

    $nextColor = {
        $script:lcdIdx++
        if ($script:lcdIdx -ge $colors.Count) {
            $lcdForm.Close()
        } else {
            $lcdForm.BackColor = $colors[$script:lcdIdx].C
            $lblHint.Text = "LCD TEST: $($colors[$script:lcdIdx].N)`n[Klik Layar / Spasi = Ganti Warna | ESC = Selesai]"
        }
    }
    $lcdForm.Add_Click($nextColor)
    $lblHint.Add_Click($nextColor)
    $lcdForm.Add_KeyDown({
        if ($_.KeyCode -eq "Escape") { $lcdForm.Close() }
        elseif ($_.KeyCode -eq "Space" -or $_.KeyCode -eq "Right") { & $nextColor }
    })
    [void]$lcdForm.ShowDialog()

    $ans = [System.Windows.Forms.MessageBox]::Show("Apakah layar LCD bersih tanpa dead pixel, garis, atau kedip?", "Konfirmasi Hasil Test LCD", "YesNo", "Question")
    Set-HwResult -Key "LCD" -Result $(if($ans -eq "Yes"){"PASS"}else{"FAIL"})
})

$btnTestSpeaker = New-ActionButton $HwInteractiveScroll "Test Speaker (L / R)" 242 6 225 34 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "mmsys.cpl" 0 15
$btnTestSpeaker.Add_Click({
    Write-Log "Memutar nada uji Speaker Kiri (440Hz), Kanan (660Hz), dan Stereo..." "INFO"
    Invoke-AsyncTask -ScriptBlock {
        function Play-ToneWav([int]$Freq, [int]$ChannelMode) {
            $sampleRate = 44100
            $durationSec = 1
            $numSamples = $sampleRate * $durationSec
            $ms = New-Object System.IO.MemoryStream
            $bw = New-Object System.IO.BinaryWriter($ms)
            $dataLen = $numSamples * 4
            $bw.Write([Text.Encoding]::ASCII.GetBytes("RIFF"))
            $bw.Write([int](36 + $dataLen))
            $bw.Write([Text.Encoding]::ASCII.GetBytes("WAVEfmt "))
            $bw.Write([int]16)
            $bw.Write([short]1)
            $bw.Write([short]2)
            $bw.Write([int]$sampleRate)
            $bw.Write([int]($sampleRate * 4))
            $bw.Write([short]4)
            $bw.Write([short]16)
            $bw.Write([Text.Encoding]::ASCII.GetBytes("data"))
            $bw.Write([int]$dataLen)
            for ($i = 0; $i -lt $numSamples; $i++) {
                $val = [short]([Math]::Sin(2 * [Math]::PI * $Freq * $i / $sampleRate) * 18000)
                $left  = if ($ChannelMode -eq 1 -or $ChannelMode -eq 3) { $val } else { [short]0 }
                $right = if ($ChannelMode -eq 2 -or $ChannelMode -eq 3) { $val } else { [short]0 }
                $bw.Write($left)
                $bw.Write($right)
            }
            $bw.Flush()
            $ms.Position = 0
            $sp = New-Object System.Media.SoundPlayer($ms)
            $sp.PlaySync()
            $sp.Dispose()
            $bw.Dispose()
            $ms.Dispose()
        }
        Play-ToneWav -Freq 440 -ChannelMode 1
        Start-Sleep -Milliseconds 150
        Play-ToneWav -Freq 660 -ChannelMode 2
        Start-Sleep -Milliseconds 150
        Play-ToneWav -Freq 528 -ChannelMode 3
    } -DisableControls @($btnTestSpeaker) | Out-Null

    $ans = [System.Windows.Forms.MessageBox]::Show("Apakah suara speaker Kiri, Kanan, dan Stereo terdengar jelas tanpa pecah?", "Konfirmasi Test Speaker", "YesNo", "Question")
    Set-HwResult -Key "Speaker" -Result $(if($ans -eq "Yes"){"PASS"}else{"FAIL"})
})

$btnTestMic = New-ActionButton $HwInteractiveScroll "Test Microphone (3 Detik)" 10 46 225 34 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "shell32.dll" 168 15
$btnTestMic.Add_Click({
    $micCount = [WinAudioDiagHelper]::waveInGetNumDevs()
    if ($micCount -eq 0) {
        Set-HwResult -Key "Microphone" -Result "NOT SUPPORTED" -Detail "Tidak ada perangkat input suara"
        return
    }
    $wavPath = Join-Path $env:TEMP "qc_mic_test.wav"
    if (Test-Path $wavPath) { Remove-Item $wavPath -Force -ErrorAction SilentlyContinue }

    $btnTestMic.Enabled = $false
    try {
        Write-Log "Merekam suara dari Microphone selama 3 detik... Silakan berbicara!" "INFO"
        [WinAudioDiagHelper]::SendMci("open new Type waveaudio Alias qcmic") | Out-Null
        [WinAudioDiagHelper]::SendMci("record qcmic") | Out-Null
        for ($i = 0; $i -lt 30; $i++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        [WinAudioDiagHelper]::SendMci("stop qcmic") | Out-Null
        [WinAudioDiagHelper]::SendMci("save qcmic `"$wavPath`"") | Out-Null
        [WinAudioDiagHelper]::SendMci("close qcmic") | Out-Null

        if (Test-Path $wavPath) {
            Write-Log "Memutar ulang rekaman suara Microphone..." "INFO"
            $sp = New-Object System.Media.SoundPlayer($wavPath)
            $sp.PlaySync()
            $sp.Dispose()
        }
        $ans = [System.Windows.Forms.MessageBox]::Show("Apakah suara rekaman microphone terdengar kembali dengan jelas?", "Konfirmasi Test Microphone", "YesNo", "Question")
        Set-HwResult -Key "Microphone" -Result $(if($ans -eq "Yes"){"PASS"}else{"FAIL"})
    } finally {
        $btnTestMic.Enabled = $true
    }
})

$btnTestWebcam = New-ActionButton $HwInteractiveScroll "Test Webcam / Kamera" 242 46 225 34 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "imageres.dll" 67 15
$btnTestWebcam.Add_Click({
    $camForm = New-Object System.Windows.Forms.Form
    $camForm.Text = "QC Webcam Live Preview"
    $camForm.Size = New-Object System.Drawing.Size(540, 475)
    $camForm.StartPosition = "CenterParent"
    $camForm.FormBorderStyle = "FixedDialog"
    $camForm.MaximizeBox = $false

    $picCam = New-Object System.Windows.Forms.PictureBox
    $picCam.Location = New-Object System.Drawing.Point(15, 14)
    $picCam.Size = New-Object System.Drawing.Size(494, 330)
    $picCam.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 31)
    $picCam.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $camForm.Controls.Add($picCam)

    $lblCamStat = New-Object System.Windows.Forms.Label
    $lblCamStat.Text = "Menginisialisasi kamera..."
    $lblCamStat.Location = New-Object System.Drawing.Point(15, 350)
    $lblCamStat.Size = New-Object System.Drawing.Size(310, 24)
    $lblCamStat.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    $camForm.Controls.Add($lblCamStat)

    $btnOpenWinCam = New-ActionButton $camForm "Buka App Camera Win" 330 347 179 28 $null "imageres.dll" 67 14
    $btnOpenWinCam.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $btnOpenWinCam.Add_Click({ Start-Process "microsoft.windows.camera:" })

    $btnCamPass = New-ActionButton $camForm "Kamera Jernih (PASS)" 15 385 240 38 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 101 16
    $btnCamFail = New-ActionButton $camForm "Kamera Bermasalah (FAIL)" 269 385 240 38 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 16

    $script:camHwnd = [IntPtr]::Zero
    $script:camResult = "UNTESTED"
    $script:camConnected = $false

    $camTimer = New-Object System.Windows.Forms.Timer
    $camTimer.Interval = 65
    $camTimer.Add_Tick({
        if ($script:camConnected -and $script:camHwnd -ne [IntPtr]::Zero) {
            [WinCamPreviewHelper]::SendMessage($script:camHwnd, [WinCamPreviewHelper]::WM_CAP_GRAB_FRAME, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            [WinCamPreviewHelper]::SendMessage($script:camHwnd, [WinCamPreviewHelper]::WM_CAP_EDIT_COPY, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            try {
                if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
                    $img = [System.Windows.Forms.Clipboard]::GetImage()
                    if ($img) {
                        $old = $picCam.Image
                        $picCam.Image = $img
                        if ($old) { $old.Dispose() }
                    }
                }
            } catch {}
        }
    })

    $camForm.Add_Shown({
        [System.Windows.Forms.Application]::DoEvents()
        $style = [WinCamPreviewHelper]::WS_CHILD
        $script:camHwnd = [WinCamPreviewHelper]::capCreateCaptureWindowW("CamQC", $style, 0, 0, 640, 480, $camForm.Handle, 0)
        if ($script:camHwnd -ne [IntPtr]::Zero) {
            for ($devIdx = 0; $devIdx -le 3; $devIdx++) {
                $resConn = [WinCamPreviewHelper]::SendMessage($script:camHwnd, [WinCamPreviewHelper]::WM_CAP_DRIVER_CONNECT, [IntPtr]$devIdx, [IntPtr]::Zero)
                if ($resConn -ne [IntPtr]::Zero) {
                    $script:camConnected = $true
                    $lblCamStat.Text = "Kamera aktif (Driver Index #$devIdx)"
                    $lblCamStat.ForeColor = [System.Drawing.Color]::ForestGreen
                    $camTimer.Start()
                    break
                }
            }
        }
        if (-not $script:camConnected) {
            $lblCamStat.Text = "Preview langsung dikunci driver - klik 'Buka App Camera Win'"
            $lblCamStat.ForeColor = [System.Drawing.Color]::DarkOrange
        }
    })

    $camForm.Add_FormClosing({
        $camTimer.Stop()
        $camTimer.Dispose()
        if ($script:camHwnd -ne [IntPtr]::Zero) {
            [WinCamPreviewHelper]::SendMessage($script:camHwnd, [WinCamPreviewHelper]::WM_CAP_DRIVER_DISCONNECT, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            [WinCamPreviewHelper]::DestroyWindow($script:camHwnd) | Out-Null
        }
        if ($picCam.Image) { $picCam.Image.Dispose() }
    })

    $btnCamPass.Add_Click({ $script:camResult = "PASS"; $camForm.Close() })
    $btnCamFail.Add_Click({ $script:camResult = "FAIL"; $camForm.Close() })
    [void]$camForm.ShowDialog()

    if ($script:camResult -ne "UNTESTED") {
        Set-HwResult -Key "Webcam" -Result $script:camResult
    }
})

$btnTestBio = New-ActionButton $HwInteractiveScroll "Test Fingerprint & Face Hello" 10 86 457 34 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "imageres.dll" 77 15
$btnTestBio.Add_Click({
    Start-Process "ms-settings:signinoptions"
    Write-Log "Membuka Windows Hello Sign-in Options untuk pengujian Fingerprint & Face Recognition..." "INFO"
    if ($script:HwScanState["Fingerprint"].Result -ne "NOT SUPPORTED") {
        $ansFp = [System.Windows.Forms.MessageBox]::Show("Apakah sensor Fingerprint merespons dan terbaca normal?", "Konfirmasi Fingerprint", "YesNo", "Question")
        Set-HwResult -Key "Fingerprint" -Result $(if($ansFp -eq "Yes"){"PASS"}else{"FAIL"})
    }
    if ($script:HwScanState["FaceRec"].Result -ne "NOT SUPPORTED") {
        $ansFace = [System.Windows.Forms.MessageBox]::Show("Apakah sensor Face Recognition (IR Camera) merespons normal?", "Konfirmasi Face Recognition", "YesNo", "Question")
        Set-HwResult -Key "FaceRec" -Result $(if($ansFace -eq "Yes"){"PASS"}else{"FAIL"})
    }
})

# Panel Interaktif Uji Keyboard & Touchpad Langsung
$GrpKbTp = New-Object System.Windows.Forms.GroupBox
$GrpKbTp.Text = "Live Tester Keyboard & Touchpad (Tekan Tombol / Gerakkan Kursor)"
$GrpKbTp.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$GrpKbTp.Location = New-Object System.Drawing.Point(10, 126)
$GrpKbTp.Size = New-Object System.Drawing.Size(457, 212)
$HwInteractiveScroll.Controls.Add($GrpKbTp)

$TxtKbTest = New-Object System.Windows.Forms.TextBox
$TxtKbTest.Location = New-Object System.Drawing.Point(10, 20)
$TxtKbTest.Size = New-Object System.Drawing.Size(436, 25)
$TxtKbTest.Font = New-Object System.Drawing.Font("Consolas", 9.5, [System.Drawing.FontStyle]::Bold)
$TxtKbTest.Text = "Klik di sini lalu tekan tombol Keyboard untuk menguji..."
$TxtKbTest.ForeColor = [System.Drawing.Color]::DimGray
$GrpKbTp.Controls.Add($TxtKbTest)

$LblLastKey = New-Object System.Windows.Forms.Label
$LblLastKey.Text = "Tombol Terakhir: -  |  Jumlah Tombol Teruji: 0"
$LblLastKey.Font = New-Object System.Drawing.Font("Segoe UI", 8.3, [System.Drawing.FontStyle]::Bold)
$LblLastKey.ForeColor = [System.Drawing.Color]::FromArgb(24, 34, 56)
$LblLastKey.Location = New-Object System.Drawing.Point(10, 50)
$LblLastKey.Size = New-Object System.Drawing.Size(436, 18)
$GrpKbTp.Controls.Add($LblLastKey)

$script:TestedKeysSet = New-Object System.Collections.Generic.HashSet[string]
$TxtKbTest.Add_Enter({
    if ($TxtKbTest.Text -like "Klik di sini*") {
        $TxtKbTest.Text = ""
        $TxtKbTest.ForeColor = [System.Drawing.Color]::Black
    }
})
$TxtKbTest.Add_KeyDown({
    $kName = $_.KeyCode.ToString()
    [void]$script:TestedKeysSet.Add($kName)
    $LblLastKey.Text = "Tombol Terakhir: [$kName] (Code: $($_.KeyValue))  |  Total Unik: $($script:TestedKeysSet.Count)"
})

$PnlTouchpadPad = New-Object System.Windows.Forms.Panel
$PnlTouchpadPad.Location = New-Object System.Drawing.Point(10, 72)
$PnlTouchpadPad.Size = New-Object System.Drawing.Size(436, 90)
$PnlTouchpadPad.BackColor = [System.Drawing.Color]::FromArgb(235, 241, 248)
$PnlTouchpadPad.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$GrpKbTp.Controls.Add($PnlTouchpadPad)

$LblTpStat = New-Object System.Windows.Forms.Label
$LblTpStat.Text = "AREA UJI TOUCHPAD / MOUSE`nGerakkan kursor, Klik Kiri, Klik Kanan, atau Scroll di area biru ini"
$LblTpStat.Font = New-Object System.Drawing.Font("Segoe UI", 8.3)
$LblTpStat.ForeColor = [System.Drawing.Color]::FromArgb(40, 60, 90)
$LblTpStat.Location = New-Object System.Drawing.Point(8, 8)
$LblTpStat.Size = New-Object System.Drawing.Size(418, 72)
$LblTpStat.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$PnlTouchpadPad.Controls.Add($LblTpStat)

$script:TpClicks = @{ Left=$false; Right=$false; Move=$false }
$UpdateTpLabel = {
    param([string]$Coord = "")
    $l = if ($script:TpClicks.Left) { "OK" } else { "-" }
    $r = if ($script:TpClicks.Right) { "OK" } else { "-" }
    $m = if ($script:TpClicks.Move) { "OK" } else { "-" }
    $LblTpStat.Text = "Gerak Kursor: [$m] $Coord`nKlik Kiri: [$l]   |   Klik Kanan: [$r]"
}
$PnlTouchpadPad.Add_MouseMove({ $script:TpClicks.Move = $true; & $UpdateTpLabel "($($_.X), $($_.Y))" })
$LblTpStat.Add_MouseMove({ $script:TpClicks.Move = $true; & $UpdateTpLabel "($($_.X), $($_.Y))" })
$PnlTouchpadPad.Add_MouseDown({
    if ($_.Button -eq "Left") { $script:TpClicks.Left = $true }
    if ($_.Button -eq "Right") { $script:TpClicks.Right = $true }
    & $UpdateTpLabel "($($_.X), $($_.Y))"
})
$LblTpStat.Add_MouseDown({
    if ($_.Button -eq "Left") { $script:TpClicks.Left = $true }
    if ($_.Button -eq "Right") { $script:TpClicks.Right = $true }
    & $UpdateTpLabel "($($_.X), $($_.Y))"
})

$btnKbPass = New-ActionButton $GrpKbTp "Keyboard PASS" 10 170 105 32 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 101 14
$btnKbPass.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$btnKbPass.Add_Click({ Set-HwResult -Key "Keyboard" -Result "PASS" })

$btnKbFail = New-ActionButton $GrpKbTp "Keyboard FAIL" 120 170 102 32 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 14
$btnKbFail.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$btnKbFail.Add_Click({ Set-HwResult -Key "Keyboard" -Result "FAIL" })

$btnTpPass = New-ActionButton $GrpKbTp "Touchpad PASS" 234 170 105 32 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 101 14
$btnTpPass.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$btnTpPass.Add_Click({ Set-HwResult -Key "Touchpad" -Result "PASS" })

$btnTpFail = New-ActionButton $GrpKbTp "Touchpad FAIL" 344 170 102 32 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 14
$btnTpFail.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$btnTpFail.Add_Click({ Set-HwResult -Key "Touchpad" -Result "FAIL" })

# Tombol Mark Manual di HwRightBottomBar (Selalu Terlihat di Bagian Bawah)
$btnMarkSelPass = New-ActionButton $HwRightBottomBar "Tandai Baris Terpilih: PASS" 8 4 225 34 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 101 15
$btnMarkSelPass.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnMarkSelPass.Add_Click({
    if ($LvHwScan.SelectedItems.Count -eq 0) { Write-Log "Pilih 1 baris komponen di tabel kiri terlebih dahulu!" "WARN"; return }
    Set-HwResult -Key $LvHwScan.SelectedItems[0].Tag -Result "PASS"
})

$btnMarkSelFail = New-ActionButton $HwRightBottomBar "Tandai Baris Terpilih: FAIL" 240 4 225 34 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 15
$btnMarkSelFail.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnMarkSelFail.Add_Click({
    if ($LvHwScan.SelectedItems.Count -eq 0) { Write-Log "Pilih 1 baris komponen di tabel kiri terlebih dahulu!" "WARN"; return }
    Set-HwResult -Key $LvHwScan.SelectedItems[0].Tag -Result "FAIL"
})
# Logika Auto-Scan Hardware & Battery Health
$RunHardwareAutoScan = {
    Write-Log "Memindai ketersediaan sensor hardware, Battery Health, dan Storage S.M.A.R.T..." "INFO"
    $hwDiag = Invoke-AsyncTask -ScriptBlock {
        $pnp = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
        $res = @{}

        # LCD / Monitor
        $mon = Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue | Select-Object -First 1
        $vid = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        $res["LCD"] = if ($vid) { "$($vid.Name) ($($vid.CurrentHorizontalResolution)x$($vid.CurrentVerticalResolution))" } else { "Standard Display" }

        # Speaker & Audio
        $aud = $pnp | Where-Object { $_.PNPClass -in @("MEDIA","AudioEndpoint") -and $_.Status -eq "OK" } | Select-Object -First 1
        $res["Speaker"] = if ($aud) { $aud.Name } else { $null }

        # Microphone
        $mic = $pnp | Where-Object { $_.Name -match "Microphone|Mic Array|Audio Input" -and $_.Status -eq "OK" } | Select-Object -First 1
        $res["Microphone"] = if ($mic) { $mic.Name } else { $null }

        # Keyboard & Touchpad
        $kb = $pnp | Where-Object { $_.PNPClass -eq "Keyboard" -and $_.Status -eq "OK" } | Select-Object -First 1
        $tp = $pnp | Where-Object { $_.PNPClass -in @("Mouse","HIDClass") -and $_.Name -match "Touchpad|Trackpad|HID-compliant mouse|Synaptics|ELAN|Precision" -and $_.Status -eq "OK" } | Select-Object -First 1
        $res["Keyboard"] = if ($kb) { $kb.Name } else { "Standard Keyboard" }
        $res["Touchpad"] = if ($tp) { $tp.Name } else { "HID Pointer Device" }

        # Webcam
        $cam = $pnp | Where-Object { $_.PNPClass -in @("Camera","Image") -and $_.Status -eq "OK" } | Select-Object -First 1
        $res["Webcam"] = if ($cam) { $cam.Name } else { $null }

        # Fingerprint
        $fp = $pnp | Where-Object { $_.PNPClass -eq "Biometric" -or $_.Name -match "Fingerprint|Biometric|Goodix|Validity|Synaptics WBDI" } | Select-Object -First 1
        $res["Fingerprint"] = if ($fp) { "$($fp.Name) [$($fp.Status)]" } else { $null }

        # Face Recognition (IR Camera)
        $ir = $pnp | Where-Object { $_.Name -match "IR Camera|Infrared|Windows Hello" } | Select-Object -First 1
        $res["FaceRec"] = if ($ir) { "$($ir.Name) [$($ir.Status)]" } else { $null }

        # Battery Health (WMI Root\WMI)
        try {
            $batStatic = Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryStaticData" -ErrorAction Stop | Select-Object -First 1
            $batFull   = Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryFullChargedCapacity" -ErrorAction Stop | Select-Object -First 1
            $batCycle  = Get-CimInstance -Namespace "root\wmi" -ClassName "BatteryCycleCount" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($batStatic -and $batFull -and $batStatic.DesignedCapacity -gt 0) {
                $healthPct = [math]::Round(($batFull.FullChargedCapacity / $batStatic.DesignedCapacity) * 100, 1)
                $cyc = if ($batCycle) { $batCycle.CycleCount } else { 0 }
                $res["BatteryInfo"] = "Health: $healthPct% ($($batFull.FullChargedCapacity)/$($batStatic.DesignedCapacity) mWh | Cycle: $cyc)"
                $res["BatteryPass"] = ($healthPct -ge 60)
            }
        } catch {}

        # Storage Health
        try {
            $disks = Get-PhysicalDisk -ErrorAction Stop
            $dSummary = ($disks | ForEach-Object { "$($_.FriendlyName) [$($_.HealthStatus)]" }) -join "; "
            $allHealthy = -not ($disks | Where-Object { $_.HealthStatus -ne "Healthy" })
            $res["StorageInfo"] = $dSummary
            $res["StoragePass"] = $allHealthy
        } catch {}

        # Wi-Fi & Bluetooth
        $wifi = $pnp | Where-Object { $_.Name -match "Wi-Fi|Wireless|802\.11" -and $_.Status -eq "OK" } | Select-Object -First 1
        $bt   = $pnp | Where-Object { $_.PNPClass -eq "Bluetooth" -and $_.Status -eq "OK" } | Select-Object -First 1
        $res["NetInfo"] = "Wi-Fi: $(if($wifi){'OK'}else{'N/A'}) | Bluetooth: $(if($bt){'OK'}else{'N/A'})"
        $res["NetPass"] = [bool]$wifi

        return $res
    } -DisableControls @($btnAutoDetectHw)

    if ($hwDiag) {
        $script:HwScanState["LCD"].Detected = $hwDiag["LCD"]
        $script:HwScanState["Keyboard"].Detected = $hwDiag["Keyboard"]
        $script:HwScanState["Touchpad"].Detected = $hwDiag["Touchpad"]

        if ($hwDiag["Speaker"]) { $script:HwScanState["Speaker"].Detected = $hwDiag["Speaker"] }
        else { $script:HwScanState["Speaker"].Detected = "Tidak terdeteksi"; $script:HwScanState["Speaker"].Result = "NOT SUPPORTED" }

        if ($hwDiag["Microphone"]) { $script:HwScanState["Microphone"].Detected = $hwDiag["Microphone"] }
        else { $script:HwScanState["Microphone"].Detected = "Tidak terdeteksi"; $script:HwScanState["Microphone"].Result = "NOT SUPPORTED" }

        if ($hwDiag["Webcam"]) { $script:HwScanState["Webcam"].Detected = $hwDiag["Webcam"] }
        else { $script:HwScanState["Webcam"].Detected = "Tidak terdeteksi"; $script:HwScanState["Webcam"].Result = "NOT SUPPORTED" }

        if ($hwDiag["Fingerprint"]) { $script:HwScanState["Fingerprint"].Detected = $hwDiag["Fingerprint"] }
        else { $script:HwScanState["Fingerprint"].Detected = "Tidak tersedia di laptop ini"; $script:HwScanState["Fingerprint"].Result = "NOT SUPPORTED" }

        if ($hwDiag["FaceRec"]) { $script:HwScanState["FaceRec"].Detected = $hwDiag["FaceRec"] }
        else { $script:HwScanState["FaceRec"].Detected = "IR Camera tidak tersedia"; $script:HwScanState["FaceRec"].Result = "NOT SUPPORTED" }

        if ($hwDiag.ContainsKey("BatteryInfo")) {
            $script:HwScanState["Battery"].Detected = $hwDiag["BatteryInfo"]
            $script:HwScanState["Battery"].Result   = if ($hwDiag["BatteryPass"]) { "PASS" } else { "FAIL" }
        } else {
            $script:HwScanState["Battery"].Detected = "Tidak ada baterai / PC Desktop"
            $script:HwScanState["Battery"].Result   = "NOT SUPPORTED"
        }

        if ($hwDiag.ContainsKey("StorageInfo")) {
            $script:HwScanState["Storage"].Detected = $hwDiag["StorageInfo"]
            $script:HwScanState["Storage"].Result   = if ($hwDiag["StoragePass"]) { "PASS" } else { "FAIL" }
        }

        $script:HwScanState["Network"].Detected = $hwDiag["NetInfo"]
        $script:HwScanState["Network"].Result   = if ($hwDiag["NetPass"]) { "PASS" } else { "FAIL" }

        Update-HwScanListView
        Write-Log "Auto-Scan Hardware selesai! Lanjutkan uji interaktif pada komponen yang berstatus UNTESTED." "SUCCESS"
    }
}

$btnAutoDetectHw.Add_Click($RunHardwareAutoScan)

$btnExportHwReport.Add_Click({
    $sys  = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_Bios
    $os   = Get-CimInstance Win32_OperatingSystem
    $now  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $repDir = Join-Path $ScriptDir "QC_Reports"
    if (-not (Test-Path $repDir)) { New-Item -Path $repDir -ItemType Directory -Force | Out-Null }

    $htmlPath = Join-Path $repDir "Hardware_QC_$($env:COMPUTERNAME)_$stamp.html"

    $passCnt = 0; $failCnt = 0; $untestedCnt = 0; $nsCnt = 0
    $rowsHtml = ""
    foreach ($k in $script:HwScanState.Keys) {
        $it = $script:HwScanState[$k]
        $badgeColor = switch ($it.Result) {
            "PASS"          { $passCnt++; "#1e8449" }
            "FAIL"          { $failCnt++; "#c0392b" }
            "NOT SUPPORTED" { $nsCnt++; "#7f8c8d" }
            default         { $untestedCnt++; "#d68910" }
        }
        $rowsHtml += "<tr><td><b>$($it.Name)</b></td><td>$($it.Detected)</td><td style='color:$badgeColor;font-weight:bold;'>$($it.Result)</td></tr>`r`n"
    }

    $overall = if ($failCnt -gt 0) { "FAILED ($failCnt Komponen Bermasalah)" } elseif ($untestedCnt -gt 0) { "INCOMPLETE ($untestedCnt Belum Diuji)" } else { "PASSED (LULUS QC HARDWARE)" }
    $overallColor = if ($failCnt -gt 0) { "#c0392b" } elseif ($untestedCnt -gt 0) { "#d68910" } else { "#1e8449" }

    $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Hardware QC Report - $($env:COMPUTERNAME)</title>
<style>
  body { font-family: 'Segoe UI', Arial, sans-serif; margin: 30px; color: #182238; background: #f8f9fa; }
  .card { background: #fff; padding: 24px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); max-width: 900px; margin: auto; }
  h1 { margin-top: 0; color: #182238; border-bottom: 2px solid #2980b9; padding-bottom: 10px; }
  .meta { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 20px; font-size: 14px; }
  .status-box { padding: 12px 16px; border-radius: 6px; color: #fff; background: $overallColor; font-weight: bold; font-size: 16px; margin-bottom: 20px; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th, td { border: 1px solid #dce1e7; padding: 10px 12px; text-align: left; }
  th { background: #182238; color: #fff; }
  tr:nth-child(even) { background: #f4f6f9; }
</style>
</head>
<body>
<div class="card">
  <h1>LAPORAN QUALITY CONTROL (QC) HARDWARE LAPTOP</h1>
  <div class="meta">
    <div><b>Hostname / Nama PC:</b> $($sys.CSName)</div>
    <div><b>Tanggal Pemeriksaan:</b> $now</div>
    <div><b>Model Perangkat:</b> $($sys.Manufacturer) $($sys.Model)</div>
    <div><b>Serial Number (BIOS):</b> $($bios.SerialNumber)</div>
    <div><b>Sistem Operasi:</b> $($os.Caption)</div>
    <div><b>Ringkasan Hasil:</b> PASS: $passCnt | FAIL: $failCnt | UNTESTED: $untestedCnt | N/A: $nsCnt</div>
  </div>
  <div class="status-box">STATUS AKHIR QC: $overall</div>
  <table>
    <thead><tr><th>Komponen Hardware</th><th>Detail Sensor / Spesifikasi</th><th>Status Hasil</th></tr></thead>
    <tbody>
      $rowsHtml
    </tbody>
  </table>
</div>
</body>
</html>
"@
    [System.IO.File]::WriteAllText($htmlPath, $htmlContent, (New-Object System.Text.UTF8Encoding $false))
    Write-Log "Laporan Hasil QC Hardware berhasil dibuat: $htmlPath" "SUCCESS"
    Start-Process $htmlPath
})

Update-HwScanListView

$MainForm.Add_Shown({ 
    [System.Windows.Forms.Application]::DoEvents()
    Refresh-AppInstallStates -CheckWingetUpdates $true
    Build-AppsUI
    & $RefreshISODashboard
    & $LoadStartupApps
    & $LoadInstalledApps
    & $ScanDriversAction -IncludeWindowsUpdate $false
    & $RunHardwareAutoScan
    Write-Log "IT Administration and ISO Compliance Suite v7.33 siap! Semua modul & tombol aksi aktif." "SUCCESS"
})

[void]$MainForm.ShowDialog()
