# blocked.ps1 - Blocked IP/domain listesi JSON oluşturur
# Örnek data, gerçekte dosyadan oku (blocked.txt gibi)
$blockedList = @(
    @{"93.184.216.34","198.51.100.1","203.0.113.195"},
      # Sadece IP
) | ConvertTo-Json -Depth 3

# essentials klasörüne yaz
$essentialsPath = ".\essentials\blocked.json"
if (-not (Test-Path ".\essentials")) { New-Item -ItemType Directory -Path ".\essentials" }
$blockedList | Out-File -FilePath $essentialsPath -Encoding utf8
Write-Host "blocked.json oluşturuldu: $essentialsPath"