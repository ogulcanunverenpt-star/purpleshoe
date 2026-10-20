param (
    [string]$filePath  # Dosyanın tam yolu (örneğin, 'sign_firewall.exe')
)


# Başlangıç klasörünün yolu
$startupFolder = [System.Environment]::GetFolderPath('Startup')

# VBS script dosyasının adını belirle
$vbsFileName = "run-silently.vbs"

# VBS script'ini kaydetme
$vbsScriptPath = Join-Path $startupFolder $vbsFileName

# VBS dosyasını yazma
$vbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "$filePath", 0, False
"@

# VBS dosyasını kaydet
$vbsContent | Set-Content -Path $vbsScriptPath

Write-Host "Startup'a VBS script başarıyla eklendi: $vbsScriptPath"
