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

$WpSource    = Join-Path -Path $ScriptDir -ChildPath "wp.png"
$FcInstaller = Join-Path -Path $ScriptDir -ChildPath "FortiClientVPN.exe"
$VpnMaster   = Join-Path -Path $ScriptDir -ChildPath "vpn_master.conf"

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
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $localPath -UserAgent "Mozilla/5.0" -UseBasicParsing -ErrorAction Stop

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
    param($Parent, $Text, $X, $Y, $W = 220, $H = 34, $Color = $null)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($W, $H)
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::LightGray
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
# DATABASE APLIKASI EMBEDDED (MURNI WINGET)
# ==============================================================================
$AppCatalog = [ordered]@{
    "Browsers" = @(
        @{ Name = "Google Chrome";        Id = "Google.Chrome" },
        @{ Name = "Mozilla Firefox";      Id = "Mozilla.Firefox" },
        @{ Name = "Brave Browser";        Id = "Brave.Brave" },
        @{ Name = "Microsoft Edge";       Id = "Microsoft.Edge" },
        @{ Name = "Vivaldi";              Id = "Vivaldi.Vivaldi" },
        @{ Name = "Opera";                Id = "Opera.Opera" },
        @{ Name = "LibreWolf";            Id = "LibreWolf.LibreWolf" }
    )
    "Communications" = @(
        @{ Name = "WhatsApp";             Id = "9NKSQGP7F2NH" },
        @{ Name = "Zoom Workplace";       Id = "Zoom.Zoom" },
        @{ Name = "Microsoft Teams";      Id = "Microsoft.Teams" },
        @{ Name = "Discord";              Id = "Discord.Discord" },
        @{ Name = "Slack";                Id = "SlackTechnologies.Slack" },
        @{ Name = "Telegram Desktop";     Id = "Telegram.TelegramDesktop" },
        @{ Name = "Thunderbird";          Id = "Mozilla.Thunderbird" }
    )
    "Document and Office" = @(
        @{ Name = "Adobe Acrobat Reader"; Id = "Adobe.Acrobat.Reader.64-bit" },
        @{ Name = "Foxit PDF Reader";     Id = "Foxit.FoxitReader" },
        @{ Name = "SumatraPDF";           Id = "SumatraPDF.SumatraPDF" },
        @{ Name = "LibreOffice";          Id = "TheDocumentFoundation.LibreOffice" },
        @{ Name = "OnlyOffice Desktop";   Id = "ONLYOFFICE.DesktopEditors" },
        @{ Name = "WPS Office";           Id = "Kingsoft.WPSOffice" },
        @{ Name = "Notepad++";            Id = "Notepad++.Notepad++" },
        @{ Name = "Obsidian";             Id = "Obsidian.Obsidian" }
    )
    "Utilities and Remote" = @(
        @{ Name = "7-Zip";                Id = "7zip.7zip" },
        @{ Name = "WinRAR";               Id = "RARLab.WinRAR" },
        @{ Name = "AnyDesk";              Id = "AnyDeskSoftwareGmbH.AnyDesk" },
        @{ Name = "RustDesk";             Id = "RustDesk.RustDesk" },
        @{ Name = "TeamViewer";           Id = "TeamViewer.TeamViewer" },
        @{ Name = "Google Drive";         Id = "Google.GoogleDrive" },
        @{ Name = "Microsoft PowerToys";  Id = "Microsoft.PowerToys" },
        @{ Name = "Everything Search";    Id = "voidtools.Everything" },
        @{ Name = "Revo Uninstaller";     Id = "RevoUninstaller.RevoUninstaller" },
        @{ Name = "WizTree (Disk Space)"; Id = "AntibodySoftware.WizTree" },
        @{ Name = "Rufus";                Id = "Rufus.Rufus" },
        @{ Name = "CPU-Z";                Id = "CPUID.CPU-Z" },
        @{ Name = "CrystalDiskInfo";      Id = "CrystalDewWorld.CrystalDiskInfo" }
    )
    "Multimedia and Graphics" = @(
        @{ Name = "VLC Media Player";     Id = "VideoLAN.VLC" },
        @{ Name = "MPC-HC";               Id = "clsid2.mpc-hc" },
        @{ Name = "ShareX";               Id = "ShareX.ShareX" },
        @{ Name = "Greenshot";            Id = "Greenshot.Greenshot" },
        @{ Name = "GIMP";                 Id = "GIMP.GIMP" },
        @{ Name = "Paint.NET";            Id = "dotPDN.PaintDotNet" },
        @{ Name = "OBS Studio";           Id = "OBSProject.OBSStudio" },
        @{ Name = "HandBrake";            Id = "HandBrake.HandBrake" }
    )
    "Runtimes and Frameworks" = @(
        @{ Name = "VC++ Redist AIO";      Id = "abbodi1406.vcredist" },
        @{ Name = ".NET Desktop 8";       Id = "Microsoft.DotNet.DesktopRuntime.8" },
        @{ Name = ".NET Desktop 6";       Id = "Microsoft.DotNet.DesktopRuntime.6" },
        @{ Name = "DirectX Runtime";      Id = "Microsoft.DirectX" },
        @{ Name = "Java 21 JRE (Temurin)";Id = "EclipseAdoptium.Temurin.21.JRE" }
    )
    "Pro Tools and Network" = @(
        @{ Name = "Git";                  Id = "Git.Git" },
        @{ Name = "VS Code";              Id = "Microsoft.VisualStudioCode" },
        @{ Name = "Python 3.12";          Id = "Python.Python.3.12" },
        @{ Name = "PuTTY";                Id = "PuTTY.PuTTY" },
        @{ Name = "WinSCP";               Id = "WinSCP.WinSCP" },
        @{ Name = "Advanced IP Scanner";  Id = "Famatech.AdvancedIPScanner" },
        @{ Name = "Wireshark";            Id = "WiresharkFoundation.Wireshark" },
        @{ Name = "Tailscale VPN";        Id = "Tailscale.Tailscale" }
    )
}

# --- FORM UTAMA ---
$MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = "IT Administration and ISO Compliance Suite v6.9 (GitHub Ready)"
$MainForm.Size = New-Object System.Drawing.Size(1080, 760)
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

$LblTitle = New-Object System.Windows.Forms.Label
$LblTitle.Text = "IT ADMINISTRATION, WINUTIL AND ISO COMPLIANCE SUITE"
$LblTitle.ForeColor = [System.Drawing.Color]::White
$LblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)
$LblTitle.Location = New-Object System.Drawing.Point(16, 13)
$LblTitle.AutoSize = $true
$HeaderPanel.Controls.Add($LblTitle)

$TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Location = New-Object System.Drawing.Point(12, 58)
$TabControl.Size = New-Object System.Drawing.Size(1040, 495)
$MainForm.Controls.Add($TabControl)

$LblLog = New-Object System.Windows.Forms.Label
$LblLog.Text = "Log Eksekusi dan Output Real-Time:"
$LblLog.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$LblLog.Location = New-Object System.Drawing.Point(14, 560)
$LblLog.AutoSize = $true
$MainForm.Controls.Add($LblLog)

$BtnClearLog = New-Object System.Windows.Forms.Button
$BtnClearLog.Text = "Bersihkan Log"
$BtnClearLog.Location = New-Object System.Drawing.Point(952, 556)
$BtnClearLog.Size = New-Object System.Drawing.Size(100, 24)
$BtnClearLog.Add_Click({ $txtLog.Clear() })
$MainForm.Controls.Add($BtnClearLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Location = New-Object System.Drawing.Point(12, 584)
$txtLog.Size = New-Object System.Drawing.Size(1040, 125)
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 31)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(80, 250, 123)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$MainForm.Controls.Add($txtLog)

# ==============================================================================
# TAB 1: INSTALL / UPGRADE APPLICATIONS (MURNI WINGET)
# ==============================================================================
$TabApps = New-Object System.Windows.Forms.TabPage
$TabApps.Text = "1. Install / Upgrade Apps"
$TabApps.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabApps)

$LblSearch = New-Object System.Windows.Forms.Label
$LblSearch.Text = "Cari Aplikasi:"
$LblSearch.Location = New-Object System.Drawing.Point(14, 14)
$LblSearch.AutoSize = $true
$TabApps.Controls.Add($LblSearch)

$TxtSearchApp = New-Object System.Windows.Forms.TextBox
$TxtSearchApp.Location = New-Object System.Drawing.Point(95, 11)
$TxtSearchApp.Size = New-Object System.Drawing.Size(260, 24)
$TabApps.Controls.Add($TxtSearchApp)

$LblAppCount = New-Object System.Windows.Forms.Label
$LblAppCount.Text = "Katalog Winget Siap"
$LblAppCount.ForeColor = [System.Drawing.Color]::DimGray
$LblAppCount.Location = New-Object System.Drawing.Point(370, 14)
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

function Build-AppsUI {
    param([string]$Filter = "")
    $AppFlowPanel.SuspendLayout()
    $AppFlowPanel.Controls.Clear()
    $AllAppCheckboxes.Clear()

    $totalCount = 0
    foreach ($catName in $AppCatalog.Keys) {
        $items = $AppCatalog[$catName] | Where-Object {
            (-not $Filter) -or ($_.Name -like "*$Filter*" -or $catName -like "*$Filter*")
        }
        if ($items.Count -eq 0) { continue }

        $boxH = [math]::Max(60, ($items.Count * 23) + 30)
        $grp = New-Object System.Windows.Forms.GroupBox
        $grp.Text = "$catName ($($items.Count))"
        $grp.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
        $grp.Size = New-Object System.Drawing.Size(235, $boxH)
        $grp.Margin = New-Object System.Windows.Forms.Padding(5)

        $iy = 22
        foreach ($it in $items) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $it.Name
            $cb.Tag = $it.Id
            $cb.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
            $cb.Location = New-Object System.Drawing.Point(10, $iy)
            $cb.Size = New-Object System.Drawing.Size(218, 21)
            $grp.Controls.Add($cb)
            $AllAppCheckboxes.Add($cb)
            $iy += 23
            $totalCount++
        }
        $AppFlowPanel.Controls.Add($grp)
    }

    $LblAppCount.Text = "Total tersedia: $totalCount aplikasi (Winget Package Manager)"
    $AppFlowPanel.ResumeLayout()
}

$TxtSearchApp.Add_TextChanged({ Build-AppsUI -Filter $TxtSearchApp.Text.Trim() })

$btnInstallSel = New-ActionButton $TabApps "Install / Upgrade Selected" 10 420 220 38 ([System.Drawing.Color]::FromArgb(39, 174, 96))
$btnInstallSel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnInstallSel.Add_Click({
    $selected = $AllAppCheckboxes | Where-Object { $_.Checked }
    if ($selected.Count -eq 0) { Write-Log "Centang minimal 1 aplikasi terlebih dahulu!" "WARN"; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Log "Winget tidak ditemukan di PC ini!" "ERROR"; return }

    Write-Log "Memulai Install / Upgrade $($selected.Count) aplikasi terpilih..." "INFO"
    foreach ($cb in $selected) {
        $name = $cb.Text
        $id = $cb.Tag
        Write-Log "Memproses $name [$id]..." "INFO"
        $p = Start-Process "winget" -ArgumentList "install --id `"$id`" --silent --accept-package-agreements --accept-source-agreements" -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq -1978335189) {
            Write-Log "$name berhasil di-install / sudah versi terbaru." "SUCCESS"
        } else {
            Write-Log "$name selesai dengan exit code: $($p.ExitCode)" "WARN"
        }
        $cb.Checked = $false
    }
    Write-Log "Semua antrean aplikasi selesai!" "SUCCESS"
})

$btnUpgradeAll = New-ActionButton $TabApps "Upgrade All Applications" 240 420 190 38 ([System.Drawing.Color]::FromArgb(41, 128, 185))
$btnUpgradeAll.Add_Click({
    Start-Process "cmd.exe" -ArgumentList "/c winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements"
})

$btnPresetOffice = New-ActionButton $TabApps "Preset Laptop Kantor" 440 420 165 38
$btnPresetOffice.Add_Click({
    $defs = @("Google Chrome", "WhatsApp", "WinRAR", "7-Zip", "Adobe Acrobat Reader", "AnyDesk", "Google Drive")
    $AllAppCheckboxes | ForEach-Object { $_.Checked = ($defs -contains $_.Text) }
    Write-Log "Preset Laptop Kantor dicentang." "INFO"
})

$btnClearApps = New-ActionButton $TabApps "Clear Selection" 615 420 130 38
$btnClearApps.Add_Click({ $AllAppCheckboxes | ForEach-Object { $_.Checked = $false } })

# ==============================================================================
# TAB 2: TWEAKS (CTT)
# ==============================================================================
$TabTweaks = New-Object System.Windows.Forms.TabPage
$TabTweaks.Text = "2. Tweaks (CTT)"
$TabTweaks.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabTweaks)

$TweakFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$TweakFlow.Location = New-Object System.Drawing.Point(10, 10)
$TweakFlow.Size = New-Object System.Drawing.Size(1012, 400)
$TweakFlow.AutoScroll = $true
$TabTweaks.Controls.Add($TweakFlow)

$AllTweakCheckboxes = New-Object System.Collections.Generic.List[System.Windows.Forms.CheckBox]

$CTTTweaksMap = [ordered]@{
    "Essential Tweaks (Rekomendasi Utama CTT)" = @(
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

$btnRunTweaks = New-ActionButton $TabTweaks "Run Selected Tweaks" 15 420 200 38 ([System.Drawing.Color]::FromArgb(39, 174, 96))
$btnRunTweaks.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnRunTweaks.Add_Click({
    $sel = $AllTweakCheckboxes | Where-Object { $_.Checked }
    if ($sel.Count -eq 0) { Write-Log "Pilih minimal 1 tweak terlebih dahulu!" "WARN"; return }

    foreach ($cb in $sel) {
        try {
            switch ($cb.Tag) {
                "RestorePoint" { Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue; Checkpoint-Computer -Description "CTT_ITAdmin" -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue }
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
                "DeleteTempFiles" { @($env:TEMP,"C:\Windows\Temp") | ForEach-Object { if (Test-Path $_) { Get-ChildItem $_ -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } } }
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
    Write-Log "Semua tweak CTT selesai dijalankan!" "SUCCESS"
})

$btnStandardPreset = New-ActionButton $TabTweaks "Standard (CTT Preset)" 225 420 175 38 ([System.Drawing.Color]::FromArgb(41, 128, 185))
$btnStandardPreset.Add_Click({
    $std = @("RestorePoint","DebloatEdge","DisableTelemetry","DisableActivityHistory","DisableLocation","DisableConsumerFeatures","DisableRecall","SetServicesManual","DeleteTempFiles","BingSearch","RemoveWidgets","ShowExt","StickyKeys")
    $AllTweakCheckboxes | ForEach-Object { $_.Checked = ($std -contains $_.Tag) }
    Write-Log "Preset Standard CTT dipilih." "INFO"
})

$btnMinimalPreset = New-ActionButton $TabTweaks "Minimal Preset" 410 420 140 38
$btnMinimalPreset.Add_Click({
    $min = @("RestorePoint","DisableTelemetry","DeleteTempFiles","ShowExt","StickyKeys")
    $AllTweakCheckboxes | ForEach-Object { $_.Checked = ($min -contains $_.Tag) }
    Write-Log "Preset Minimal dipilih." "INFO"
})

$btnClearTweaks = New-ActionButton $TabTweaks "Clear Tweaks" 560 420 130 38
$btnClearTweaks.Add_Click({ $AllTweakCheckboxes | ForEach-Object { $_.Checked = $false } })

# ==============================================================================
# TAB 3: CONFIG (CTT)
# ==============================================================================
$TabConfig = New-Object System.Windows.Forms.TabPage
$TabConfig.Text = "3. Config (CTT)"
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

$btnInstallFeat = New-ActionButton $GrpFeatures "Install Selected Features" 15 275 290 38 ([System.Drawing.Color]::FromArgb(39, 174, 96))
$btnInstallFeat.Add_Click({
    $sel = $FeatCheckboxes | Where-Object { $_.Checked }
    if ($sel.Count -eq 0) { Write-Log "Pilih Windows Feature dulu!" "WARN"; return }
    foreach ($cb in $sel) {
        Write-Log "Mengaktifkan $($cb.Text)..." "INFO"
        try { Enable-WindowsOptionalFeature -Online -FeatureName $cb.Tag -All -NoRestart -ErrorAction Stop | Out-Null; Write-Log "$($cb.Text) aktif!" "SUCCESS" }
        catch { Write-Log "Gagal $($cb.Text): $($_.Exception.Message)" "ERROR" }
    }
})

$GrpFixes = New-Object System.Windows.Forms.GroupBox
$GrpFixes.Text = "Fixes and Windows Update (CTT)"
$GrpFixes.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$GrpFixes.Location = New-Object System.Drawing.Point(355, 12)
$GrpFixes.Size = New-Object System.Drawing.Size(330, 450)
$TabConfig.Controls.Add($GrpFixes)

$btnResetWU = New-ActionButton $GrpFixes "Reset Windows Update" 18 30 292 36
$btnResetWU.Add_Click({
    Stop-Service wuauserv, bits, cryptsvc -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv, bits, cryptsvc -ErrorAction SilentlyContinue
    Write-Log "Windows Update di-reset!" "SUCCESS"
})

$btnResetNet = New-ActionButton $GrpFixes "Reset Network (Winsock and DNS)" 18 74 292 36
$btnResetNet.Add_Click({ ipconfig /flushdns|Out-Null; netsh winsock reset|Out-Null; netsh int ip reset|Out-Null; Write-Log "Network di-reset!" "SUCCESS" })

$btnSFC = New-ActionButton $GrpFixes "System Corruption Scan (DISM and SFC)" 18 118 292 36
$btnSFC.Add_Click({ Start-Process "cmd.exe" -ArgumentList "/c DISM /Online /Cleanup-Image /RestoreHealth" })

$btnWinReinstall = New-ActionButton $GrpFixes "Fix Windows Store / Re-register Appx" 18 162 292 36
$btnWinReinstall.Add_Click({
    Write-Log "Mendaftarkan ulang aplikasi bawaan Windows..." "INFO"
    Get-AppxPackage -AllUsers | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue }
    Write-Log "Re-register Appx selesai!" "SUCCESS"
})

$btnWUDefault = New-ActionButton $GrpFixes "Win Update: Default Settings" 18 220 292 36
$btnWUDefault.Add_Click({
    Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Windows Update dikembalikan ke Default." "SUCCESS"
})

$btnWUSecurity = New-ActionButton $GrpFixes "Win Update: Security Only (Recommended)" 18 264 292 36 ([System.Drawing.Color]::FromArgb(41, 128, 185))
$btnWUSecurity.Add_Click({
    $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
    Set-ItemProperty $p "DeferFeatureUpdates" 1 -Type DWORD; Set-ItemProperty $p "DeferFeatureUpdatesPeriodInDays" 365 -Type DWORD
    Set-ItemProperty $p "DeferQualityUpdates" 1 -Type DWORD; Set-ItemProperty $p "DeferQualityUpdatesPeriodInDays" 4 -Type DWORD
    Write-Log "Windows Update diatur ke Security Only (Feature ditunda 365 hari)." "SUCCESS"
})

$btnWUDisable = New-ActionButton $GrpFixes "Win Update: Disable All Updates" 18 308 292 36 ([System.Drawing.Color]::FromArgb(192, 57, 43))
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
    @{ Name="Control Panel"; Cmd="control.exe" },
    @{ Name="Network Connections (ncpa.cpl)"; Cmd="ncpa.cpl" },
    @{ Name="Power Panel (powercfg.cpl)"; Cmd="powercfg.cpl" },
    @{ Name="Region and Language (intl.cpl)"; Cmd="intl.cpl" },
    @{ Name="Sound Settings (mmsys.cpl)"; Cmd="mmsys.cpl" },
    @{ Name="System Properties (sysdm.cpl)"; Cmd="sysdm.cpl" },
    @{ Name="Programs and Features (appwiz.cpl)"; Cmd="appwiz.cpl" },
    @{ Name="User Accounts (netplwiz)"; Cmd="netplwiz.exe" },
    @{ Name="Device Manager (devmgmt.msc)"; Cmd="devmgmt.msc" },
    @{ Name="Disk Management (diskmgmt.msc)"; Cmd="diskmgmt.msc" }
)
$py = 26
foreach ($pnl in $panels) {
    $b = New-ActionButton $GrpPanels $pnl.Name 16 $py 286 33
    $cmd = $pnl.Cmd
    $b.Add_Click({ Start-Process $cmd }.GetNewClosure())
    $py += 39
}

# ==============================================================================
# TAB 4: IT ADMIN LOKAL + ON-DEMAND DOWNLOAD ASSETS
# ==============================================================================
$TabLocal = New-Object System.Windows.Forms.TabPage
$TabLocal.Text = "4. IT Admin Lokal"
$TabLocal.BackColor = [System.Drawing.Color]::WhiteSmoke
$TabControl.Controls.Add($TabLocal)

$btnSpec = New-ActionButton $TabLocal "Cek Spesifikasi Laptop" 20 18 310 38
$btnSpec.Add_Click({
    $sys = Get-CimInstance Win32_ComputerSystem; $bios = Get-CimInstance Win32_Bios; $proc = Get-CimInstance Win32_Processor
    Write-Log "PC: $($sys.CSName) | Model: $($sys.Manufacturer) $($sys.Model) | SN: $($bios.SerialNumber)" "SUCCESS"
    Write-Log "CPU: $($proc.Name.Trim()) | RAM: $([math]::Round($sys.TotalPhysicalMemory/1GB,2)) GB" "INFO"
    Get-PhysicalDisk | ForEach-Object { Write-Log "Disk: $($_.FriendlyName) ($($_.MediaType)) - $([math]::Round($_.Size/1GB,2)) GB [$($_.HealthStatus)]" "INFO" }
})

$btnRename = New-ActionButton $TabLocal "Rename Nama PC" 350 18 310 38
$btnRename.Add_Click({
    $n = Show-InputBox "Rename PC" "Nama PC saat ini: $env:COMPUTERNAME`nMasukkan Nama PC Baru:"
    if ($n) { try { Rename-Computer -NewName $n -Force -ErrorAction Stop; Write-Log "Nama PC diubah ke '$n'." "SUCCESS" } catch { Write-Log $_.Exception.Message "ERROR" } }
})

$btnBlockUSB = New-ActionButton $TabLocal "Block USB Storage" 680 18 160 38 ([System.Drawing.Color]::FromArgb(192, 57, 43))
$btnBlockUSB.Add_Click({ Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" "Start" 4; Write-Log "USB DI-BLOCK." "WARN" })

$btnUnblockUSB = New-ActionButton $TabLocal "Unblock USB" 850 18 160 38 ([System.Drawing.Color]::FromArgb(39, 174, 96))
$btnUnblockUSB.Add_Click({ Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" "Start" 3; Write-Log "USB DI-UNBLOCK." "SUCCESS" })

$btnSetWP = New-ActionButton $TabLocal "Terapkan Wallpaper dan Lock Screen (wp.png)" 20 68 310 38 ([System.Drawing.Color]::FromArgb(41, 128, 185))
$btnSetWP.Add_Click({
    $wpFile = Get-ToolAsset -FileName "wp.png"
    if (-not $wpFile) { return }
    try {
        $tf = "C:\Users\Public\Pictures\wp.png"; Copy-Item $wpFile $tf -Force
        Set-ItemProperty "HKCU:\Control Panel\Desktop" "Wallpaper" $tf; Set-ItemProperty "HKCU:\Control Panel\Desktop" "WallpaperStyle" "2"
        $lr = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"; if (!(Test-Path $lr)) { New-Item $lr -Force | Out-Null }
        Set-ItemProperty $lr "LockScreenImagePath" $tf -Type String; Set-ItemProperty $lr "LockScreenImageUrl" $tf -Type String; Set-ItemProperty $lr "LockScreenImageStatus" 1 -Type DWORD
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class WP { [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni); }' -ErrorAction SilentlyContinue
        [WP]::SystemParametersInfo(20, 0, $tf, 3) | Out-Null; Write-Log "Wallpaper dan Lock Screen diterapkan!" "SUCCESS"
    } catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnLockWP = New-ActionButton $TabLocal "Lock Wallpaper" 350 68 150 38
$btnLockWP.Add_Click({
    @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System") | ForEach-Object { if(!(Test-Path $_)){New-Item $_ -Force|Out-Null}; Set-ItemProperty $_ "NoChangingWallPaper" 1 -Type DWORD -ErrorAction SilentlyContinue }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Write-Log "Wallpaper DI-LOCK." "WARN"
})

$btnUnlockWP = New-ActionButton $TabLocal "Unlock Wallpaper" 510 68 150 38
$btnUnlockWP.Add_Click({
    @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System") | ForEach-Object { if(Test-Path $_){Set-ItemProperty $_ "NoChangingWallPaper" 0 -Type DWORD -ErrorAction SilentlyContinue} }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Write-Log "Wallpaper DI-UNLOCK." "SUCCESS"
})

$btnDefender = New-ActionButton $TabLocal "Aktifkan Defender dan Firewall" 680 68 330 38
$btnDefender.Add_Click({
    try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop; Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True; Write-Log "Defender dan Firewall Aktif!" "SUCCESS" }
    catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnAddIT = New-ActionButton $TabLocal "Buat/Update User IT_ADMIN" 20 118 310 38
$btnAddIT.Add_Click({
    $p = Show-InputBox "User IT_ADMIN" "Masukkan Password IT_ADMIN:" "F1d4c@IT" $true; if (!$p) { return }
    $s = ConvertTo-SecureString $p -AsPlainText -Force
    try {
        if (Get-LocalUser "IT_ADMIN" -ErrorAction SilentlyContinue) { Set-LocalUser "IT_ADMIN" -Password $s -PasswordNeverExpires $true; Write-Log "User IT_ADMIN diperbarui." "SUCCESS" }
        else { New-LocalUser "IT_ADMIN" -Password $s -FullName "IT Administrator" -PasswordNeverExpires; Add-LocalGroupMember "Administrators" "IT_ADMIN"; Write-Log "Akun IT_ADMIN dibuat." "SUCCESS" }
    } catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnDemote = New-ActionButton $TabLocal "Turunkan Karyawan ke Standard" 350 118 310 38
$btnDemote.Add_Click({
    Get-LocalGroupMember "Administrators" | ForEach-Object {
        $n = $_.Name.Split('\')[-1]
        if ($n -ne "IT_ADMIN" -and $n -ne "Administrator") {
            try { Remove-LocalGroupMember "Administrators" $n -ErrorAction Stop; Add-LocalGroupMember "Users" $n -ErrorAction SilentlyContinue; Write-Log "'$n' diturunkan ke Standard." "SUCCESS" }
            catch { Write-Log $_.Exception.Message "ERROR" }
        }
    }
})

$btnNewUser = New-ActionButton $TabLocal "Tambah User Karyawan Baru" 680 118 330 38
$btnNewUser.Add_Click({
    $u = Show-InputBox "User Baru" "Username Karyawan Baru:"; if (!$u) { return }
    $p = Show-InputBox "Password" "Password untuk ${u}:" "" $true; if (!$p) { return }
    try { New-LocalUser $u -Password (ConvertTo-SecureString $p -AsPlainText -Force) -PasswordNeverExpires; Add-LocalGroupMember "Users" $u; Write-Log "User '$u' dibuat." "SUCCESS" }
    catch { Write-Log $_.Exception.Message "ERROR" }
})

$btnWinLic = New-ActionButton $TabLocal "Cek Lisensi Windows" 20 168 310 38
$btnWinLic.Add_Click({ Write-Log (cscript //nologo C:\Windows\System32\slmgr.vbs /dli | Out-String).Trim() "INFO" })

$btnOffLic = New-ActionButton $TabLocal "Cek Lisensi Office" 350 168 310 38
$btnOffLic.Add_Click({
    $p = @("$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS","${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($p) { Write-Log (cscript //nologo "$p" /dstatus | Select-String "LICENSE NAME|LICENSE STATUS" | Out-String).Trim() "INFO" }
    else { Write-Log "Office 16 tidak terdeteksi." "WARN" }
})

$btnBitlocker = New-ActionButton $TabLocal "Backup BitLocker Key (C:)" 680 168 330 38
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
$LblISODesc.Text = "Otomatis menerapkan 6 kebijakan standar ISO (skip jika sudah aktif):`r`n1. Block USB Storage`r`n2. Wallpaper dan Lock Screen (Auto-download wp.png jika belum ada)`r`n3. Lock Wallpaper`r`n4. Aktifkan Defender dan Firewall`r`n5. Buat/Update User IT_ADMIN`r`n6. Turunkan Karyawan ke Standard User"
$LblISODesc.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$LblISODesc.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$LblISODesc.Location = New-Object System.Drawing.Point(15, 24)
$LblISODesc.Size = New-Object System.Drawing.Size(455, 132)
$GrpISO.Controls.Add($LblISODesc)

$btnApplyISO = New-ActionButton $GrpISO "TERAPKAN ISO SEKARANG (AUTO-SKIP)" 15 166 455 48 ([System.Drawing.Color]::FromArgb(142, 68, 173))
$btnApplyISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnApplyISO.Add_Click({
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
    $curLock = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Name "LockScreenImagePath" -ErrorAction SilentlyContinue).LockScreenImagePath
    if (($curWP -eq $targetWP) -and ($curLock -eq $targetWP) -and (Test-Path $targetWP)) {
        Write-Log "[2/6] Wallpaper dan Lock Screen sudah terpasang -> Melewati..." "SKIP"
    } else {
        $wpFile = Get-ToolAsset -FileName "wp.png"
        if (-not $wpFile) { Write-Log "[2/6] File 'wp.png' gagal didapatkan -> Melewati..." "WARN" }
        else {
            try {
                Copy-Item -Path $wpFile -Destination $targetWP -Force -ErrorAction Stop
                Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -Value $targetWP
                Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "2"
                $lr = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
                if (-not (Test-Path $lr)) { New-Item -Path $lr -Force | Out-Null }
                Set-ItemProperty -Path $lr -Name "LockScreenImagePath" -Value $targetWP -Type String
                Set-ItemProperty -Path $lr -Name "LockScreenImageUrl" -Value $targetWP -Type String
                Set-ItemProperty -Path $lr -Name "LockScreenImageStatus" -Value 1 -Type DWORD
                Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class WPISO { [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni); }' -ErrorAction SilentlyContinue
                [WPISO]::SystemParametersInfo(20, 0, $targetWP, 3) | Out-Null
                Write-Log "[2/6] Wallpaper dan Lock Screen (wp.png) berhasil diterapkan!" "SUCCESS"
            } catch { Write-Log "[2/6] Gagal menerapkan wallpaper: $($_.Exception.Message)" "ERROR" }
        }
    }

    $wpPol1 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
    $wpPol2 = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
    if (($wpPol1 -eq 1) -and ($wpPol2 -eq 1)) {
        Write-Log "[3/6] Lock Wallpaper sudah aktif -> Melewati..." "SKIP"
    } else {
        try {
            @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop","HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System") | ForEach-Object {
                if (-not (Test-Path $_)) { New-Item $_ -Force | Out-Null }
                Set-ItemProperty $_ -Name "NoChangingWallPaper" -Value 1 -Type DWORD -ErrorAction SilentlyContinue
            }
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Write-Log "[3/6] Wallpaper berhasil DI-LOCK!" "SUCCESS"
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

$btnAutoVPN = New-ActionButton $GrpVPN "AUTO INSTALL DAN RESTORE VPN KANTOR" 15 166 460 48 ([System.Drawing.Color]::FromArgb(22, 160, 133))
$btnAutoVPN.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnAutoVPN.Add_Click({
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

        Write-Log "[1/3] Menginstal FortiClient VPN secara silent..." "INFO"
        $p = Start-Process -FilePath $installerFile -ArgumentList "/quiet /norestart" -Wait -PassThru
        Start-Sleep -Seconds 5
        $fcExe = $fcPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $fcExe) {
            Write-Log "[1/3] Installer selesai (ExitCode: $($p.ExitCode)), namun FortiClient.exe belum muncul." "ERROR"
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
    try {
        Stop-Process -Name "FortiClient" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        $pImp = Start-Process -FilePath $fcConfig -ArgumentList "-m vpn -f `"$masterFile`" -o import -i 1 -p 12345678" -NoNewWindow -Wait -PassThru

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
        Start-Sleep -Seconds 2

        if ($pImp.ExitCode -eq 0) {
            Write-Log "[3/3] Profil 'VPN Kantor' berhasil di-restore! Silakan buka FortiClient dari Start Menu." "SUCCESS"
        } else {
            Write-Log "[3/3] FCConfig selesai dengan kode $($pImp.ExitCode). Cek FortiClient dari Start Menu." "WARN"
        }
    } catch {
        Write-Log "Gagal mengimpor vpn_master.conf: $($_.Exception.Message)" "ERROR"
    }
})

# ==============================================================================
# TAB 5: DASHBOARD ISO (AUDIT STATUS LENGKAP PERANGKAT)
# ==============================================================================
$TabISO = New-Object System.Windows.Forms.TabPage
$TabISO.Text = "5. Dashboard ISO"
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
    @{ Key="WPStatus";     Label="Status Lock Wallpaper" },
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
    Write-Log "Memindai status spesifikasi, kepatuhan ISO, dan lisensi..." "INFO"

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
        $txtISOSpec.Text = ($specLines -join "`r`n")
    } catch { $txtISOSpec.Text = "Gagal membaca spesifikasi: $($_.Exception.Message)" }

    $StatusLabels["PCName"].Text = $env:COMPUTERNAME
    $StatusLabels["PCName"].ForeColor = [System.Drawing.Color]::FromArgb(24, 34, 56)

    $usbStart = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -ErrorAction SilentlyContinue).Start
    if ($usbStart -eq 4) {
        $StatusLabels["USBStatus"].Text = "TERBLOKIR / BLOCKED (Sesuai ISO)"
        $StatusLabels["USBStatus"].ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $StatusLabels["USBStatus"].Text = "TERBUKA / UNBLOCKED (Belum ISO)"
        $StatusLabels["USBStatus"].ForeColor = [System.Drawing.Color]::Crimson
    }

    $wp1 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
    $wp2 = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -ErrorAction SilentlyContinue).NoChangingWallPaper
    if ($wp1 -eq 1 -or $wp2 -eq 1) {
        $StatusLabels["WPStatus"].Text = "TERKUNCI / LOCKED (Sesuai ISO)"
        $StatusLabels["WPStatus"].ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $StatusLabels["WPStatus"].Text = "TIDAK TERKUNCI / UNLOCKED"
        $StatusLabels["WPStatus"].ForeColor = [System.Drawing.Color]::Crimson
    }

    $mp = Get-MpPreference -ErrorAction SilentlyContinue
    $fwEnabled = (Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true }).Count
    if ($mp -and ($mp.DisableRealtimeMonitoring -eq $false) -and ($fwEnabled -ge 3)) {
        $StatusLabels["DefStatus"].Text = "AKTIF (Defender Real-time dan 3 Firewall ON)"
        $StatusLabels["DefStatus"].ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $StatusLabels["DefStatus"].Text = "NONAKTIF / SEBAGIAN MATI"
        $StatusLabels["DefStatus"].ForeColor = [System.Drawing.Color]::Crimson
    }

    $itAcc = Get-LocalUser -Name "IT_ADMIN" -ErrorAction SilentlyContinue
    $adminMembers = (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] })
    if ($itAcc -and $itAcc.Enabled -and ($adminMembers -contains "IT_ADMIN")) {
        $StatusLabels["ITAdminStat"].Text = "ADA dan AKTIF (Grup Administrators)"
        $StatusLabels["ITAdminStat"].ForeColor = [System.Drawing.Color]::ForestGreen
    } elseif ($itAcc) {
        $StatusLabels["ITAdminStat"].Text = "ADA (Bukan Admin / Nonaktif)"
        $StatusLabels["ITAdminStat"].ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $StatusLabels["ITAdminStat"].Text = "BELUM DIBUAT"
        $StatusLabels["ITAdminStat"].ForeColor = [System.Drawing.Color]::Crimson
    }

    $empAdmins = $adminMembers | Where-Object { $_ -ne "IT_ADMIN" -and $_ -ne "Administrator" }
    $stdUsers  = (Get-LocalGroupMember -Group "Users" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] } | Where-Object { $_ -notmatch "Authenticated Users|INTERACTIVE" })
    if (-not $empAdmins -or $empAdmins.Count -eq 0) {
        $uList = if ($stdUsers) { ($stdUsers -join ", ") } else { "Standar" }
        $StatusLabels["EmpStat"].Text = "AMAN - Standard User ($uList)"
        $StatusLabels["EmpStat"].ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $StatusLabels["EmpStat"].Text = "MASIH ADMIN: $($empAdmins -join ', ')"
        $StatusLabels["EmpStat"].ForeColor = [System.Drawing.Color]::Crimson
    }

    try {
        $winLicObj = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($winLicObj) {
            $licState = switch ($winLicObj.LicenseStatus) {
                1 { "Licensed (Aktif Permanen)" }
                2 { "OOB Grace Period" }
                5 { "Notification / Belum Aktivasi" }
                default { "Status Kode: $($winLicObj.LicenseStatus)" }
            }
            $StatusLabels["WinLic"].Text = "$licState - $($winLicObj.Name)"
            $StatusLabels["WinLic"].ForeColor = if ($winLicObj.LicenseStatus -eq 1) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DarkOrange }
        } else {
            $StatusLabels["WinLic"].Text = "Tidak Terdeteksi / Belum Aktivasi"
            $StatusLabels["WinLic"].ForeColor = [System.Drawing.Color]::Crimson
        }
    } catch { $StatusLabels["WinLic"].Text = "Gagal membaca lisensi Windows" }

    $ospp = @("$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS","${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($ospp) {
        $offOut = cscript //nologo "$ospp" /dstatus | Select-String "LICENSE NAME|LICENSE STATUS"
        if ($offOut) {
            $cleanOff = ($offOut -join " | ") -replace "LICENSE NAME:\s*", "" -replace "LICENSE STATUS:\s*", ""
            $StatusLabels["OffLic"].Text = $cleanOff.Trim()
            $StatusLabels["OffLic"].ForeColor = if ($cleanOff -match "LICENSED") { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DarkOrange }
        } else {
            $StatusLabels["OffLic"].Text = "Office Terpasang (Status tidak terbaca)"
            $StatusLabels["OffLic"].ForeColor = [System.Drawing.Color]::DarkOrange
        }
    } else {
        $StatusLabels["OffLic"].Text = "Office 16/2019/2021/365 Tidak Terdeteksi"
        $StatusLabels["OffLic"].ForeColor = [System.Drawing.Color]::DimGray
    }

    try {
        $blVol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
        if ($blVol.ProtectionStatus -eq "On") {
            $StatusLabels["BitLocker"].Text = "AKTIF / ON ($($blVol.EncryptionMethod) - $($blVol.EncryptionPercentage)%)"
            $StatusLabels["BitLocker"].ForeColor = [System.Drawing.Color]::ForestGreen
        } else {
            $StatusLabels["BitLocker"].Text = "NONAKTIF / OFF ($($blVol.VolumeStatus))"
            $StatusLabels["BitLocker"].ForeColor = [System.Drawing.Color]::DarkOrange
        }
    } catch {
        $StatusLabels["BitLocker"].Text = "Tidak Tersedia / Butuh Admin"
        $StatusLabels["BitLocker"].ForeColor = [System.Drawing.Color]::DimGray
    }

    Write-Log "Dashboard ISO selesai diperbarui." "SUCCESS"
}

$btnRefreshISO = New-ActionButton $TabISO "Refresh Status Audit ISO" 15 418 240 40 ([System.Drawing.Color]::FromArgb(41, 128, 185))
$btnRefreshISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnRefreshISO.Add_Click($RefreshISODashboard)

$btnJumpApplyISO = New-ActionButton $TabISO "Jalankan Terapkan ISO Sekarang" 270 418 260 40 ([System.Drawing.Color]::FromArgb(142, 68, 173))
$btnJumpApplyISO.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnJumpApplyISO.Add_Click({ $btnApplyISO.PerformClick() })

Build-AppsUI
$MainForm.Add_Shown({
    & $RefreshISODashboard
    Write-Log "IT Administration and ISO Compliance Suite v6.9 siap! Folder aset: $ScriptDir" "SUCCESS"
})

[void]$MainForm.ShowDialog()
