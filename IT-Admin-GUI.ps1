
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

# Native Win32 Icon Extractor untuk mengambil ikon bawaan Windows (shell32.dll / imageres.dll)
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

# Folder kerja: jika dari flashdisk pakai folder skrip, jika dari GitHub (irm | iex) pakai C:\ITAdminTools
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

# --- FORM UTAMA ---
$MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = "IT Administration and ISO Compliance Suite v7.6 (Async Anti-Freeze)"
$MainForm.Size = New-Object System.Drawing.Size(1080, 765)
$MainForm.StartPosition = "CenterScreen"
$MainForm.FormBorderStyle = "FixedSingle"
$MainForm.MaximizeBox = $false
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
$LblTitle.Text = "IT ADMINISTRATION, WINUTIL AND ISO COMPLIANCE SUITE v7.6"
$LblTitle.ForeColor = [System.Drawing.Color]::White
$LblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)
$LblTitle.Location = New-Object System.Drawing.Point(50, 13)
$LblTitle.AutoSize = $true
$HeaderPanel.Controls.Add($LblTitle)

# ImageList untuk Tab Header (Ikon di setiap Tab tanpa angka)
$TabImageList = New-Object System.Windows.Forms.ImageList
$TabImageList.ImageSize = New-Object System.Drawing.Size(18, 18)
$TabImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$TabImageList.Images.Add("apps",    (Get-WinBitmap -Dll "shell32.dll"  -Index 162 -Size 18))
$TabImageList.Images.Add("tweaks",  (Get-WinBitmap -Dll "imageres.dll" -Index 109 -Size 18))
$TabImageList.Images.Add("config",  (Get-WinBitmap -Dll "shell32.dll"  -Index 21  -Size 18))
$TabImageList.Images.Add("admin",   (Get-WinBitmap -Dll "imageres.dll" -Index 73  -Size 18))
$TabImageList.Images.Add("iso",     (Get-WinBitmap -Dll "imageres.dll" -Index 101 -Size 18))
$TabImageList.Images.Add("manage",  (Get-WinBitmap -Dll "shell32.dll"  -Index 13  -Size 18))

$TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Location = New-Object System.Drawing.Point(12, 58)
$TabControl.Size = New-Object System.Drawing.Size(1040, 498)
$TabControl.ImageList = $TabImageList
$TabControl.Padding = New-Object System.Drawing.Point(10, 5)
$MainForm.Controls.Add($TabControl)

$LblLog = New-Object System.Windows.Forms.Label
$LblLog.Text = "Log Eksekusi dan Output Real-Time:"
$LblLog.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$LblLog.Location = New-Object System.Drawing.Point(14, 563)
$LblLog.AutoSize = $true
$MainForm.Controls.Add($LblLog)

$BtnClearLog = New-ActionButton $MainForm "Bersihkan Log" 928 559 124 25 $null "shell32.dll" 31 14
$BtnClearLog.Font = New-Object System.Drawing.Font("Segoe UI", 8.2)
$BtnClearLog.Add_Click({ $txtLog.Clear() })

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Location = New-Object System.Drawing.Point(12, 588)
$txtLog.Size = New-Object System.Drawing.Size(1040, 125)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 31)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(80, 250, 123)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$MainForm.Controls.Add($txtLog)

# ==============================================================================
# TAB: INSTALL / UPGRADE APPLICATIONS (ASYNC NON-BLOCKING)
# ==============================================================================
$TabApps = New-Object System.Windows.Forms.TabPage
$TabApps.Text = "Install / Upgrade Apps"
$TabApps.ImageKey = "apps"
$TabApps.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabApps)

$LblSearch = New-Object System.Windows.Forms.Label
$LblSearch.Text = "Cari:"
$LblSearch.Location = New-Object System.Drawing.Point(12, 14)
$LblSearch.AutoSize = $true
$TabApps.Controls.Add($LblSearch)

$TxtSearchApp = New-Object System.Windows.Forms.TextBox
$TxtSearchApp.Location = New-Object System.Drawing.Point(48, 11)
$TxtSearchApp.Size = New-Object System.Drawing.Size(185, 24)
$TabApps.Controls.Add($TxtSearchApp)

$LblFilterStatus = New-Object System.Windows.Forms.Label
$LblFilterStatus.Text = "Filter Status:"
$LblFilterStatus.Location = New-Object System.Drawing.Point(242, 14)
$LblFilterStatus.AutoSize = $true
$TabApps.Controls.Add($LblFilterStatus)

$CmbStatusFilter = New-Object System.Windows.Forms.ComboBox
$CmbStatusFilter.Location = New-Object System.Drawing.Point(322, 11)
$CmbStatusFilter.Size = New-Object System.Drawing.Size(145, 24)
$CmbStatusFilter.DropDownStyle = "DropDownList"
$CmbStatusFilter.Items.AddRange(@("Semua Aplikasi", "Update Tersedia", "Belum Terinstall", "Sudah Terinstall"))
$CmbStatusFilter.SelectedIndex = 0
$TabApps.Controls.Add($CmbStatusFilter)

$LblAppCount = New-Object System.Windows.Forms.Label
$LblAppCount.Text = "Memindai status aplikasi di background..."
$LblAppCount.ForeColor = [System.Drawing.Color]::DimGray
$LblAppCount.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$LblAppCount.Location = New-Object System.Drawing.Point(480, 14)
$LblAppCount.AutoSize = $true
$TabApps.Controls.Add($LblAppCount)

$AppFlowPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$AppFlowPanel.Location = New-Object System.Drawing.Point(10, 42)
$AppFlowPanel.Size = New-Object System.Drawing.Size(1012, 370)
$AppFlowPanel.AutoScroll = $true
$AppFlowPanel.FlowDirection = "TopDown"
$AppFlowPanel.WrapContents = $true
$TabApps.Controls.Add($AppFlowPanel)

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
        $grp.Size = New-Object System.Drawing.Size(324, $boxH)
        $grp.Margin = New-Object System.Windows.Forms.Padding(4)

        $iy = 22
        foreach ($it in $items) {
            $st = if ($script:AppStatusMap.ContainsKey($it.Id)) { $script:AppStatusMap[$it.Id] } else { "NotInstalled" }

            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $it.Name
            $cb.Tag = @{ Id = $it.Id; Name = $it.Name; Status = $st }
            $cb.Font = New-Object System.Drawing.Font("Segoe UI", 8.3)
            $cb.Location = New-Object System.Drawing.Point(8, $iy)
            $cb.Size = New-Object System.Drawing.Size(195, 22)
            $grp.Controls.Add($cb)
            $AllAppCheckboxes.Add($cb)

            $pb = New-Object System.Windows.Forms.PictureBox
            $pb.Location = New-Object System.Drawing.Point(205, ($iy + 2))
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
            $lblBadge.Location = New-Object System.Drawing.Point(228, ($iy + 2))
            $lblBadge.Size = New-Object System.Drawing.Size(88, 18)
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
        $AppFlowPanel.Controls.Add($grp)
        [System.Windows.Forms.Application]::DoEvents()
    }

    $LblAppCount.Text = "Terpasang: $cntInstalled | Update Baru: $cntUpdate | Belum: $cntNotInst"
    $AppFlowPanel.ResumeLayout()
}

$TxtSearchApp.Add_TextChanged({ Build-AppsUI -Filter $TxtSearchApp.Text.Trim() })
$CmbStatusFilter.Add_SelectedIndexChanged({ Build-AppsUI -Filter $TxtSearchApp.Text.Trim() })

$btnInstallSel = New-ActionButton $TabApps "Install / Upgrade Selected" 10 420 220 38 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 162 16
$btnInstallSel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
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

$btnUpgradeAll = New-ActionButton $TabApps "Upgrade All Applications" 238 420 195 38 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 46 16
$btnUpgradeAll.Add_Click({
    Start-Process "cmd.exe" -ArgumentList "/c winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements"
})

$btnCheckAppStat = New-ActionButton $TabApps "Cek Status & Update" 441 420 175 38 ([System.Drawing.Color]::FromArgb(52, 73, 94)) "shell32.dll" 238 16
$btnCheckAppStat.Add_Click({
    Refresh-AppInstallStates -CheckWingetUpdates $true
    Build-AppsUI -Filter $TxtSearchApp.Text.Trim()
})

$btnPresetOffice = New-ActionButton $TabApps "Preset Laptop Kantor" 624 420 175 38 $null "shell32.dll" 15 16
$btnPresetOffice.Add_Click({
    $defs = @("Google Chrome", "WhatsApp", "WinRAR", "7-Zip", "Adobe Acrobat Reader", "AnyDesk", "Google Drive")
    $AllAppCheckboxes | ForEach-Object {
        $info = $_.Tag
        $_.Checked = ($defs -contains $info.Name) -and ($info.Status -ne "Installed")
    }
    Write-Log "Preset Laptop Kantor dicentang (hanya yang belum terpasang / butuh update)." "INFO"
})

$btnClearApps = New-ActionButton $TabApps "Clear Selection" 807 420 140 38 $null "shell32.dll" 131 16
$btnClearApps.Add_Click({ $AllAppCheckboxes | ForEach-Object { $_.Checked = $false } })

# ==============================================================================
# TAB: TWEAKS (TANPA '(CTT)')
# ==============================================================================
$TabTweaks = New-Object System.Windows.Forms.TabPage
$TabTweaks.Text = "Tweaks"
$TabTweaks.ImageKey = "tweaks"
$TabTweaks.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabTweaks)

$TweakFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$TweakFlow.Location = New-Object System.Drawing.Point(10, 10)
$TweakFlow.Size = New-Object System.Drawing.Size(1012, 400)
$TweakFlow.AutoScroll = $true
$TabTweaks.Controls.Add($TweakFlow)

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
    $grp.Size = New-Object System.Drawing.Size(324, 385)
    $grp.Margin = New-Object System.Windows.Forms.Padding(5)

    $ty = 24
    foreach ($tw in $items) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $tw.Name
        $cb.Tag = $tw.Id
        $cb.Font = New-Object System.Drawing.Font("Segoe UI", 8.2)
        $cb.Location = New-Object System.Drawing.Point(10, $ty)
        $cb.Size = New-Object System.Drawing.Size(306, 22)
        $grp.Controls.Add($cb)
        $AllTweakCheckboxes.Add($cb)
        $ty += 24
    }
    $TweakFlow.Controls.Add($grp)
}

$btnRunTweaks = New-ActionButton $TabTweaks "Run Selected Tweaks" 15 420 205 38 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 109 16
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
                        Set-ItemProperty $p -Name "HubsSidebarEnabled" -Value 0 -Type DWORD
                        Set-ItemProperty $p -Name "EdgeShoppingAssistantEnabled" -Value 0 -Type DWORD
                    }
                    "DisableTelemetry" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p -Name "AllowTelemetry" -Value 0 -Type DWORD
                        Stop-Service "DiagTrack" -Force -ErrorAction SilentlyContinue; Set-Service "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
                    }
                    "DisableActivityHistory" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p -Name "EnableActivityFeed" -Value 0 -Type DWORD; Set-ItemProperty $p -Name "PublishUserActivities" -Value 0 -Type DWORD
                    }
                    "DisableLocation" {
                        $p = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p -Name "Value" -Value "Deny" -Type String
                    }
                    "DisableStorageSense" {
                        $p = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p -Name "01" -Value 0 -Type DWORD
                    }
                    "DisableHibernation" { powercfg.exe /hibernate off }
                    "DisableConsumerFeatures" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWORD
                    }
                    "DisableRecall" {
                        $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p -Name "TurnOffWindowsCopilot" -Value 1 -Type DWORD
                    }
                    "DisableGameDVR" {
                        $p = "HKCU:\System\GameConfigStore"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
                        Set-ItemProperty $p -Name "GameDVR_Enabled" -Value 0 -Type DWORD
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

$btnStandardPreset = New-ActionButton $TabTweaks "Standard Preset" 228 420 185 38 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 43 16
$btnStandardPreset.Add_Click({
    $std = @("RestorePoint","DebloatEdge","DisableTelemetry","DisableActivityHistory","DisableLocation","DisableConsumerFeatures","DisableRecall","SetServicesManual","DeleteTempFiles","BingSearch","RemoveWidgets","ShowExt","StickyKeys")
    $AllTweakCheckboxes | ForEach-Object { $_.Checked = ($std -contains $_.Tag) }
    Write-Log "Preset Standard dipilih." "INFO"
})

$btnMinimalPreset = New-ActionButton $TabTweaks "Minimal Preset" 421 420 155 38 $null "shell32.dll" 134 16
$btnMinimalPreset.Add_Click({
    $min = @("RestorePoint","DisableTelemetry","DeleteTempFiles","ShowExt","StickyKeys")
    $AllTweakCheckboxes | ForEach-Object { $_.Checked = ($min -contains $_.Tag) }
    Write-Log "Preset Minimal dipilih." "INFO"
})

$btnClearTweaks = New-ActionButton $TabTweaks "Clear Tweaks" 584 420 140 38 $null "shell32.dll" 131 16
$btnClearTweaks.Add_Click({ $AllTweakCheckboxes | ForEach-Object { $_.Checked = $false } })

# ==============================================================================
# TAB: CONFIG (TANPA '(CTT)')
# ==============================================================================
$TabConfig = New-Object System.Windows.Forms.TabPage
$TabConfig.Text = "Config"
$TabConfig.ImageKey = "config"
$TabConfig.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabConfig)

$GrpFeatures = New-Object System.Windows.Forms.GroupBox
$GrpFeatures.Text = "Features (Windows Optional)"
$GrpFeatures.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpFeatures.Location = New-Object System.Drawing.Point(15, 12)
$GrpFeatures.Size = New-Object System.Drawing.Size(325, 450)
$TabConfig.Controls.Add($GrpFeatures)

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
$fy = 26
foreach ($f in $CTTFeatures) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $f.Name
    $cb.Tag = $f.Feat
    $cb.Font = New-Object System.Drawing.Font("Segoe UI", 8.3)
    $cb.Location = New-Object System.Drawing.Point(12, $fy)
    $cb.Size = New-Object System.Drawing.Size(300, 22)
    $GrpFeatures.Controls.Add($cb)
    $FeatCheckboxes += $cb
    $fy += 26
}

$btnInstallFeat = New-ActionButton $GrpFeatures "Install Selected Features" 15 275 290 38 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 21 16
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

$GrpFixes = New-Object System.Windows.Forms.GroupBox
$GrpFixes.Text = "Fixes and Windows Update"
$GrpFixes.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpFixes.Location = New-Object System.Drawing.Point(355, 12)
$GrpFixes.Size = New-Object System.Drawing.Size(330, 450)
$TabConfig.Controls.Add($GrpFixes)

$btnResetWU = New-ActionButton $GrpFixes "Reset Windows Update" 18 30 292 36 $null "shell32.dll" 238 16
$btnResetWU.Add_Click({
    Invoke-AsyncTask -ScriptBlock {
        Stop-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service wuauserv, bits, cryptsvc -ErrorAction SilentlyContinue
    } -DisableControls @($btnResetWU) | Out-Null
    Write-Log "Windows Update di-reset!" "SUCCESS"
})

$btnResetNet = New-ActionButton $GrpFixes "Reset Network (Winsock and DNS)" 18 74 292 36 $null "shell32.dll" 18 16
$btnResetNet.Add_Click({
    Invoke-AsyncTask -ScriptBlock {
        ipconfig /flushdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
    } -DisableControls @($btnResetNet) | Out-Null
    Write-Log "Network di-reset!" "SUCCESS"
})

$btnSFC = New-ActionButton $GrpFixes "System Corruption Scan (DISM and SFC)" 18 118 292 36 $null "imageres.dll" 102 16
$btnSFC.Add_Click({ Start-Process "cmd.exe" -ArgumentList "/c DISM /Online /Cleanup-Image /RestoreHealth" })

$btnWinReinstall = New-ActionButton $GrpFixes "Fix Windows Store / Re-register Appx" 18 162 292 36 $null "shell32.dll" 162 16
$btnWinReinstall.Add_Click({
    Write-Log "Mendaftarkan ulang aplikasi bawaan Windows (Background)..." "INFO"
    Invoke-AsyncTask -ScriptBlock {
        Get-AppxPackage -AllUsers | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue }
    } -DisableControls @($btnWinReinstall) | Out-Null
    Write-Log "Re-register Appx selesai!" "SUCCESS"
})

$btnWUDefault = New-ActionButton $GrpFixes "Win Update: Default Settings" 18 220 292 36 $null "shell32.dll" 46 16
$btnWUDefault.Add_Click({
    Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Windows Update dikembalikan ke Default." "SUCCESS"
})

$btnWUSecurity = New-ActionButton $GrpFixes "Win Update: Security Only (Recommended)" 18 264 292 36 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "imageres.dll" 73 16
$btnWUSecurity.Add_Click({
    $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
    Set-ItemProperty $p "DeferFeatureUpdates" 1 -Type DWORD; Set-ItemProperty $p "DeferFeatureUpdatesPeriodInDays" 365 -Type DWORD
    Set-ItemProperty $p "DeferQualityUpdates" 1 -Type DWORD; Set-ItemProperty $p "DeferQualityUpdatesPeriodInDays" 4 -Type DWORD
    Write-Log "Windows Update diatur ke Security Only (Feature ditunda 365 hari)." "SUCCESS"
})

$btnWUDisable = New-ActionButton $GrpFixes "Win Update: Disable All Updates" 18 308 292 36 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 16
$btnWUDisable.Add_Click({
    $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
    Set-ItemProperty $p "NoAutoUpdate" 1 -Type DWORD
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue; Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Log "Semua Windows Update DINONAKTIFKAN." "WARN"
})

$GrpPanels = New-Object System.Windows.Forms.GroupBox
$GrpPanels.Text = "Legacy Windows Panels"
$GrpPanels.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpPanels.Location = New-Object System.Drawing.Point(700, 12)
$GrpPanels.Size = New-Object System.Drawing.Size(320, 450)
$TabConfig.Controls.Add($GrpPanels)

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
$py = 26
foreach ($pnl in $panels) {
    $b = New-ActionButton $GrpPanels $pnl.Name 16 $py 286 33 $null $pnl.Dll $pnl.Idx 16
    $cmd = $pnl.Cmd
    $b.Add_Click({ Start-Process $cmd }.GetNewClosure())
    $py += 39
}

# ==============================================================================
# TAB: IT ADMIN LOKAL + ON-DEMAND DOWNLOAD ASSETS
# ==============================================================================
$TabLocal = New-Object System.Windows.Forms.TabPage
$TabLocal.Text = "IT Admin Lokal"
$TabLocal.ImageKey = "admin"
$TabLocal.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabLocal)

$btnSpec = New-ActionButton $TabLocal "Cek Spesifikasi Laptop" 20 18 310 38 $null "shell32.dll" 15 16
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

$btnRename = New-ActionButton $TabLocal "Rename Nama PC" 350 18 310 38 $null "shell32.dll" 134 16
$btnRename.Add_Click({
    $n = Show-InputBox "Rename PC" "Nama PC saat ini: $env:COMPUTERNAME`nMasukkan Nama PC Baru:"
    if ($n) { try { Rename-Computer -NewName $n -Force -ErrorAction Stop; Write-Log "Nama PC diubah ke '$n'." "SUCCESS" } catch { Write-Log $_.Exception.Message "ERROR" } }
})

$btnBlockUSB = New-ActionButton $TabLocal "Block USB Storage" 680 18 160 38 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 16
$btnBlockUSB.Add_Click({ Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" "Start" 4; Write-Log "USB DI-BLOCK." "WARN" })

$btnUnblockUSB = New-ActionButton $TabLocal "Unblock USB" 850 18 160 38 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "shell32.dll" 7 16
$btnUnblockUSB.Add_Click({ Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" "Start" 3; Write-Log "USB DI-UNBLOCK." "SUCCESS" })

$btnSetWP = New-ActionButton $TabLocal "Terapkan Wallpaper & Lock Screen" 20 68 310 38 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "imageres.dll" 67 16
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

$btnLockWP = New-ActionButton $TabLocal "Lock Wallpaper" 350 68 150 38 $null "shell32.dll" 47 16
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

$btnUnlockWP = New-ActionButton $TabLocal "Unlock Wallpaper" 510 68 150 38 $null "imageres.dll" 79 16
$btnUnlockWP.Add_Click({
    @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System") | ForEach-Object {
        if (Test-Path $_) { Remove-ItemProperty $_ "NoChangingWallPaper" -ErrorAction SilentlyContinue }
    }
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Write-Log "Wallpaper Desktop dan Lock Screen DI-UNLOCK." "SUCCESS"
})

$btnDefender = New-ActionButton $TabLocal "Aktifkan Defender dan Firewall" 680 68 330 38 $null "imageres.dll" 73 16
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

$btnAddIT = New-ActionButton $TabLocal "Buat/Update User IT_ADMIN" 20 118 310 38 $null "shell32.dll" 111 16
$btnAddIT.Add_Click({
    $p = Show-InputBox "User IT_ADMIN" "Masukkan Password IT_ADMIN:" "F1d4c@IT" $true; if (!$p) { return }
    $s = ConvertTo-SecureString $p -AsPlainText -Force
    try {
        if (Get-LocalUser "IT_ADMIN" -ErrorAction SilentlyContinue) { Set-LocalUser "IT_ADMIN" -Password $s -PasswordNeverExpires $true; Write-Log "User IT_ADMIN diperbarui." "SUCCESS" }
        else { New-LocalUser "IT_ADMIN" -Password $s -FullName "IT Administrator" -PasswordNeverExpires; Add-LocalGroupMember "Administrators" "IT_ADMIN"; Write-Log "Akun IT_ADMIN dibuat." "SUCCESS" }
    } catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnDemote = New-ActionButton $TabLocal "Turunkan Karyawan ke Standard" 350 118 310 38 $null "imageres.dll" 74 16
$btnDemote.Add_Click({
    Get-LocalGroupMember "Administrators" | ForEach-Object {
        $n = $_.Name.Split('\')[-1]
        if ($n -ne "IT_ADMIN" -and $n -ne "Administrator") {
            try { Remove-LocalGroupMember "Administrators" $n -ErrorAction Stop; Add-LocalGroupMember "Users" $n -ErrorAction SilentlyContinue; Write-Log "'$n' diturunkan ke Standard." "SUCCESS" }
            catch { Write-Log $_.Exception.Message "ERROR" }
        }
    }
})

$btnNewUser = New-ActionButton $TabLocal "Tambah User Karyawan Baru" 680 118 330 38 $null "shell32.dll" 269 16
$btnNewUser.Add_Click({
    $u = Show-InputBox "User Baru" "Username Karyawan Baru:"; if (!$u) { return }
    $p = Show-InputBox "Password" "Password untuk ${u}:" "" $true; if (!$p) { return }
    try { New-LocalUser $u -Password (ConvertTo-SecureString $p -AsPlainText -Force) -PasswordNeverExpires; Add-LocalGroupMember "Users" $u; Write-Log "User '$u' dibuat." "SUCCESS" }
    catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnWinLic = New-ActionButton $TabLocal "Cek Lisensi Windows" 20 168 310 38 $null "shell32.dll" 44 16
$btnWinLic.Add_Click({
    $out = Invoke-AsyncTask -ScriptBlock { (cscript //nologo C:\Windows\System32\slmgr.vbs /dli | Out-String).Trim() } -DisableControls @($btnWinLic)
    Write-Log $out "INFO"
})

$btnOffLic = New-ActionButton $TabLocal "Cek Lisensi Office" 350 168 310 38 $null "shell32.dll" 70 16
$btnOffLic.Add_Click({
    $out = Invoke-AsyncTask -ScriptBlock {
        $p = @("$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS","${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($p) { return (cscript //nologo "$p" /dstatus | Select-String "LICENSE NAME|LICENSE STATUS" | Out-String).Trim() }
        return $null
    } -DisableControls @($btnOffLic)
    if ($out) { Write-Log $out "INFO" } else { Write-Log "Office 16 tidak terdeteksi." "WARN" }
})

$btnBitlocker = New-ActionButton $TabLocal "Backup BitLocker Key (C:)" 680 168 330 38 $null "imageres.dll" 77 16
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
$GrpISO.Size = New-Object System.Drawing.Size(485, 232)
$TabLocal.Controls.Add($GrpISO)

$LblISODesc = New-Object System.Windows.Forms.Label
$LblISODesc.Text = "Otomatis menerapkan 6 kebijakan standar ISO (skip jika sudah aktif):`r`n1. Block USB Storage`r`n2. Wallpaper dan Lock Screen (Auto-download wp.png jika belum ada)`r`n3. Lock Wallpaper & Lock Screen`r`n4. Aktifkan Defender dan Firewall`r`n5. Buat/Update User IT_ADMIN`r`n6. Turunkan Karyawan ke Standard User"
$LblISODesc.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblISODesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$LblISODesc.Location = New-Object System.Drawing.Point(15, 24)
$LblISODesc.Size = New-Object System.Drawing.Size(455, 132)
$GrpISO.Controls.Add($LblISODesc)

$btnApplyISO = New-ActionButton $GrpISO "TERAPKAN ISO SEKARANG (AUTO-SKIP)" 15 166 455 48 ([System.Drawing.Color]::FromArgb(142, 68, 173)) "imageres.dll" 101 20
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
$GrpVPN.Location = New-Object System.Drawing.Point(520, 222)
$GrpVPN.Size = New-Object System.Drawing.Size(490, 232)
$TabLocal.Controls.Add($GrpVPN)

$LblVPNDesc = New-Object System.Windows.Forms.Label
$LblVPNDesc.Text = "Otomatis download (jika belum ada) dan install FortiClient VPN:`r`n- Mengunduh FortiClientVPN.exe dan vpn_master.conf saat tombol diklik`r`n- Password Backup : 12345678 (Otomatis didekripsi via FCConfig -m vpn)`r`n- Opsional: Mengganti Username VPN sesuai nama karyawan baru`r`n  sehingga karyawan cukup mengisi password saat login."
$LblVPNDesc.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblVPNDesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$LblVPNDesc.Location = New-Object System.Drawing.Point(15, 24)
$LblVPNDesc.Size = New-Object System.Drawing.Size(460, 128)
$GrpVPN.Controls.Add($LblVPNDesc)

$btnAutoVPN = New-ActionButton $GrpVPN "AUTO INSTALL DAN RESTORE VPN KANTOR" 15 166 460 48 ([System.Drawing.Color]::FromArgb(22, 160, 133)) "shell32.dll" 18 20
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
# TAB: DASHBOARD ISO (AUDIT STATUS LENGKAP PERANGKAT - ASYNC NON-BLOCKING)
# ==============================================================================
$TabISO = New-Object System.Windows.Forms.TabPage
$TabISO.Text = "Dashboard ISO"
$TabISO.ImageKey = "iso"
$TabISO.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabISO)

$GrpISOSpec = New-Object System.Windows.Forms.GroupBox
$GrpISOSpec.Text = "Spesifikasi Hardware dan Identitas Laptop"
$GrpISOSpec.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$GrpISOSpec.Location = New-Object System.Drawing.Point(15, 12)
$GrpISOSpec.Size = New-Object System.Drawing.Size(440, 395)
$TabISO.Controls.Add($GrpISOSpec)

$txtISOSpec = New-Object System.Windows.Forms.TextBox
$txtISOSpec.Multiline = $true
$txtISOSpec.ReadOnly = $true
$txtISOSpec.ScrollBars = "Vertical"
$txtISOSpec.Location = New-Object System.Drawing.Point(14, 28)
$txtISOSpec.Size = New-Object System.Drawing.Size(412, 350)
$txtISOSpec.BackColor = [System.Drawing.Color]::White
$txtISOSpec.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$GrpISOSpec.Controls.Add($txtISOSpec)

$GrpISOStatus = New-Object System.Windows.Forms.GroupBox
$GrpISOStatus.Text = "Status Keamanan ISO, Akun dan Lisensi"
$GrpISOStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$GrpISOStatus.Location = New-Object System.Drawing.Point(470, 12)
$GrpISOStatus.Size = New-Object System.Drawing.Size(545, 395)
$TabISO.Controls.Add($GrpISOStatus)

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

$sy = 30
foreach ($sf in $StatusFields) {
    $lblK = New-Object System.Windows.Forms.Label
    $lblK.Text = "$($sf.Label) :"
    $lblK.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblK.Location = New-Object System.Drawing.Point(16, $sy)
    $lblK.Size = New-Object System.Drawing.Size(205, 24)
    $GrpISOStatus.Controls.Add($lblK)

    $lblV = New-Object System.Windows.Forms.Label
    $lblV.Text = "Memuat..."
    $lblV.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblV.Location = New-Object System.Drawing.Point(225, $sy)
    $lblV.Size = New-Object System.Drawing.Size(305, 34)
    $GrpISOStatus.Controls.Add($lblV)

    $StatusLabels[$sf.Key] = $lblV
    $sy += 38
}

$RefreshISODashboard = {
    Write-Log "Memindai status spesifikasi, kepatuhan ISO, dan lisensi (Async)..." "INFO"

    $audit = Invoke-AsyncTask -ScriptBlock {
        $res = [ordered]@{}

        # 1. Spesifikasi Hardware
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

        # 2. USB Storage
        $res["USBStart"] = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -ErrorAction SilentlyContinue).Start

        # 3. Wallpaper & Lock Screen
        $res["WP1"] = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        $res["WP2"] = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
        $res["LS1"] = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoChangingLockScreen" -ErrorAction SilentlyContinue).NoChangingLockScreen
        $res["CSP"] = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"

        # 4. Defender & Firewall
        $mp = Get-MpPreference -ErrorAction SilentlyContinue
        $res["DefenderOff"] = if ($mp) { $mp.DisableRealtimeMonitoring } else { $true }
        $res["FWEnabledCount"] = (Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true }).Count

        # 5. Akun Lokal
        $itAcc = Get-LocalUser -Name "IT_ADMIN" -ErrorAction SilentlyContinue
        $res["ITExists"]  = [bool]$itAcc
        $res["ITEnabled"] = if ($itAcc) { [bool]$itAcc.Enabled } else { $false }
        $res["AdminMembers"] = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] })
        $res["StdUsers"]     = @(Get-LocalGroupMember -Group "Users" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] } | Where-Object { $_ -notmatch "Authenticated Users|INTERACTIVE" })

        # 6. License Windows
        try {
            $winLicObj = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($winLicObj) {
                $res["WinLicStatus"] = $winLicObj.LicenseStatus
                $res["WinLicName"]   = $winLicObj.Name
            }
        } catch {}

        # 7. License Office
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

        # 8. BitLocker
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

$btnRefreshISO = New-ActionButton $TabISO "Refresh Status Audit ISO" 15 418 245 40 ([System.Drawing.Color]::FromArgb(41, 128, 185)) "shell32.dll" 238 18
$btnRefreshISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnRefreshISO.Add_Click($RefreshISODashboard)

$btnJumpApplyISO = New-ActionButton $TabISO "Jalankan Terapkan ISO Sekarang" 275 418 275 40 ([System.Drawing.Color]::FromArgb(142, 68, 173)) "imageres.dll" 101 18
$btnJumpApplyISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnJumpApplyISO.Add_Click({ $btnApplyISO.PerformClick() })

# ==============================================================================
# TAB: STARTUP APPS & UNINSTALL APPS (ASYNC SCAN + IKON ASLI)
# ==============================================================================
$TabManage = New-Object System.Windows.Forms.TabPage
$TabManage.Text = "Startup & Uninstall Apps"
$TabManage.ImageKey = "manage"
$TabManage.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabManage)

$DefaultAppBitmap = ([System.Drawing.SystemIcons]::Application).ToBitmap()

$StartupImageList = New-Object System.Windows.Forms.ImageList
$StartupImageList.ImageSize = New-Object System.Drawing.Size(20, 20)
$StartupImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

$UninstallImageList = New-Object System.Windows.Forms.ImageList
$UninstallImageList.ImageSize = New-Object System.Drawing.Size(20, 20)
$UninstallImageList.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

# --- PANEL KIRI: STARTUP APPS MANAGER ---
$GrpStartup = New-Object System.Windows.Forms.GroupBox
$GrpStartup.Text = "Startup Apps Manager (Multi-Select)"
$GrpStartup.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$GrpStartup.Location = New-Object System.Drawing.Point(12, 10)
$GrpStartup.Size = New-Object System.Drawing.Size(495, 452)
$TabManage.Controls.Add($GrpStartup)

$TxtSearchStartup = New-Object System.Windows.Forms.TextBox
$TxtSearchStartup.Location = New-Object System.Drawing.Point(12, 26)
$TxtSearchStartup.Size = New-Object System.Drawing.Size(355, 24)
$TxtSearchStartup.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$GrpStartup.Controls.Add($TxtSearchStartup)

$btnRefreshStartup = New-ActionButton $GrpStartup "Refresh" 375 24 106 26 $null "shell32.dll" 238 14
$btnRefreshStartup.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)

$LvStartup = New-Object System.Windows.Forms.ListView
$LvStartup.Location = New-Object System.Drawing.Point(12, 58)
$LvStartup.Size = New-Object System.Drawing.Size(469, 328)
$LvStartup.View = [System.Windows.Forms.View]::Details
$LvStartup.CheckBoxes = $true
$LvStartup.FullRowSelect = $true
$LvStartup.GridLines = $true
$LvStartup.SmallImageList = $StartupImageList
$LvStartup.Font = New-Object System.Drawing.Font("Segoe UI", 8.8)
$LvStartup.Columns.Add("Aplikasi Startup", 265) | Out-Null
$LvStartup.Columns.Add("Status", 85) | Out-Null
$LvStartup.Columns.Add("Lokasi", 110) | Out-Null
$GrpStartup.Controls.Add($LvStartup)

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
                    $out += [PSCustomObject]@{
                        Name         = $pName
                        Command      = $cmdVal
                        Scope        = $src.Scope
                        ApprovedPath = $src.AppPath
                        Enabled      = (Get-StateLocal $src.AppPath $pName)
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
                    $out += [PSCustomObject]@{
                        Name         = $_.Name
                        Command      = $_.FullName
                        Scope        = $fsrc.Scope
                        ApprovedPath = $fsrc.AppPath
                        Enabled      = (Get-StateLocal $fsrc.AppPath $_.Name)
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
        if ($filter -and ($item.Name -notlike "*$filter*") -and ($item.Command -notlike "*$filter*")) { continue }
        $lvi = New-Object System.Windows.Forms.ListViewItem($item.Name)
        $lvi.ImageKey = $item.IconKey
        $lvi.Tag = $item
        $statusStr = if ($item.Enabled) { "AKTIF" } else { "NONAKTIF" }
        $lvi.SubItems.Add($statusStr) | Out-Null
        $lvi.SubItems.Add($item.Scope) | Out-Null
        if (-not $item.Enabled) { $lvi.ForeColor = [System.Drawing.Color]::DimGray }
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
            Write-Log "Startup '$($obj.Name)' [$($obj.Scope)] berhasil $statusTxt." "SUCCESS"
        } catch {
            Write-Log "Gagal mengubah startup '$($obj.Name)': $($_.Exception.Message)" "ERROR"
        }
    }
    & $LoadStartupApps
}

$btnEnableStartup = New-ActionButton $GrpStartup "Enable Selected" 12 396 155 40 ([System.Drawing.Color]::FromArgb(39, 174, 96)) "imageres.dll" 101 16
$btnEnableStartup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnEnableStartup.Add_Click({ Apply-StartupSelection -TargetEnable $true })

$btnDisableStartup = New-ActionButton $GrpStartup "Disable Selected" 174 396 158 40 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 109 16
$btnDisableStartup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnDisableStartup.Add_Click({ Apply-StartupSelection -TargetEnable $false })

$btnClearStartupSel = New-ActionButton $GrpStartup "Clear Check" 339 396 142 40 $null "shell32.dll" 131 16
$btnClearStartupSel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnClearStartupSel.Add_Click({
    foreach ($it in $LvStartup.Items) { $it.Checked = $false }
})

# --- PANEL KANAN: UNINSTALL INSTALLED APPS ---
$GrpUninstall = New-Object System.Windows.Forms.GroupBox
$GrpUninstall.Text = "Uninstall Installed Apps (Multi-Select)"
$GrpUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$GrpUninstall.Location = New-Object System.Drawing.Point(520, 10)
$GrpUninstall.Size = New-Object System.Drawing.Size(502, 452)
$TabManage.Controls.Add($GrpUninstall)

$TxtSearchUninstall = New-Object System.Windows.Forms.TextBox
$TxtSearchUninstall.Location = New-Object System.Drawing.Point(12, 26)
$TxtSearchUninstall.Size = New-Object System.Drawing.Size(362, 24)
$TxtSearchUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$GrpUninstall.Controls.Add($TxtSearchUninstall)

$btnRefreshUninstall = New-ActionButton $GrpUninstall "Refresh" 382 24 106 26 $null "shell32.dll" 238 14
$btnRefreshUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)

$LvUninstall = New-Object System.Windows.Forms.ListView
$LvUninstall.Location = New-Object System.Drawing.Point(12, 58)
$LvUninstall.Size = New-Object System.Drawing.Size(476, 328)
$LvUninstall.View = [System.Windows.Forms.View]::Details
$LvUninstall.CheckBoxes = $true
$LvUninstall.FullRowSelect = $true
$LvUninstall.GridLines = $true
$LvUninstall.SmallImageList = $UninstallImageList
$LvUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 8.8)
$LvUninstall.Columns.Add("Nama Aplikasi", 250) | Out-Null
$LvUninstall.Columns.Add("Versi", 80) | Out-Null
$LvUninstall.Columns.Add("Publisher", 135) | Out-Null
$GrpUninstall.Controls.Add($LvUninstall)

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

$btnApplyUninstall = New-ActionButton $GrpUninstall "Uninstall Selected (Apply)" 12 396 290 40 ([System.Drawing.Color]::FromArgb(192, 57, 43)) "shell32.dll" 31 16
$btnApplyUninstall.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
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

$btnClearUninstallSel = New-ActionButton $GrpUninstall "Clear Selection" 312 396 176 40 $null "shell32.dll" 131 16
$btnClearUninstallSel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnClearUninstallSel.Add_Click({
    foreach ($it in $LvUninstall.Items) { $it.Checked = $false }
})

$MainForm.Add_Shown({
    [System.Windows.Forms.Application]::DoEvents()
    Refresh-AppInstallStates -CheckWingetUpdates $true
    Build-AppsUI
    & $RefreshISODashboard
    & $LoadStartupApps
    & $LoadInstalledApps
    Write-Log "IT Administration and ISO Compliance Suite v7.6 siap! Folder aset: $ScriptDir" "SUCCESS"
})

[void]$MainForm.ShowDialog()
