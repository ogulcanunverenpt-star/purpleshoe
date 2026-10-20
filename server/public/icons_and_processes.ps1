# Çalışan süreçleri çek, ikonları base64'e çevir ve JSON dosyası oluştur
Add-Type -AssemblyName System.Drawing

# Essentials dizinini oluştur (varsa oluşturmaz)
$EssentialsDir = ".\essentials"
if (-not (Test-Path $EssentialsDir)) {
    New-Item -ItemType Directory -Path $EssentialsDir | Out-Null
}

# JSON dosya yolu
$JsonFile = Join-Path $EssentialsDir "icon_and_processes.json"

# Çalışan süreçleri al (benzersiz isimler için grup, path'li olanları seç)
$Processes = Get-Process | Where-Object { $_.Path } | Group-Object Name | ForEach-Object { $_.Group[0] }

# JSON için array oluştur
$JsonArray = @()

foreach ($proc in $Processes) {
    $ProcessName = $proc.Name + ".exe"  # Process adı: chrome.exe
    $ProgramName = $proc.Name.Substring(0,1).ToUpper() + $proc.Name.Substring(1)  # Program adı: Chrome (basit capitalize)
    $ExePath = $proc.Path

    # Ikon çek
    try {
        $Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        $MemoryStream = New-Object System.IO.MemoryStream
        $Icon.Save($MemoryStream)
        $Bytes = $MemoryStream.ToArray()
        $Base64Icon = [Convert]::ToBase64String($Bytes)
        $MemoryStream.Dispose()
    } catch {
        $Base64Icon = ""  # Hata olursa boş
        Write-Warning "Ikon çekilemedi: $ProcessName - $_"
    }

    # JSON objesi ekle
    $JsonArray += @{
        program = $ProgramName
        icon = $Base64Icon
        process = $ProcessName
    }
}

# JSON'a çevir ve dosyaya yaz
$JsonArray | ConvertTo-Json -Depth 10 | Out-File -FilePath $JsonFile -Encoding UTF8

Write-Host "JSON dosyası oluşturuldu: $JsonFile"