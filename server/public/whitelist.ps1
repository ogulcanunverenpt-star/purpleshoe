# whitelist.ps1 - Whitelist process listesi JSON oluşturur
# Örnek data, gerçekte dosyadan oku (process.txt gibi)
$whitelist = @(
    "agenpower.exe",
    "AggregatorHost.exe",
    "ApplicationFrameHost.exe",
    "audiodg.exe",
    "chrome.exe",
    "cmd.exe",
    "conhost.exe",
    "csrss.exe",
    "ctfmon.exe",
    "dllhost.exe",
    "dwm.exe",
    "fontdrvhost.exe",
    "lsass.exe",
    "mousocoreworker.exe",
    "msedge.exe",
    "msedgewebview2.exe",
    "notepad.exe",
    "OneDrive.exe",
    "powershell.exe",
    "RuntimeBroker.exe",
    "SearchApp.exe",
    "SearchFilterHost.exe",
    "SearchIndexer.exe",
    "SearchProtocolHost.exe",
    "SecurityHealthSystray.exe",
    "ShellExperienceHost.exe",
    "sihost.exe",
    "simple_agen_server.exe",
    "SkypeApp.exe",
    "SkypeBackgroundHost.exe",
    "spoolsv.exe",
    "svchost.exe",
    "SystemSettings.exe",
    "taskhostw.exe",
    "Taskmgr.exe",
    "TextInputHost.exe",
    "UserOOBEBroker.exe",
    "winlogon.exe"
  ) | ConvertTo-Json

# essentials klasörüne yaz
$essentialsPath = ".\essentials\whitelist.json"
if (-not (Test-Path ".\essentials")) { New-Item -ItemType Directory -Path ".\essentials" }
$whitelist | Out-File -FilePath $essentialsPath -Encoding utf8
Write-Host "whitelist.json oluşturuldu: $essentialsPath"