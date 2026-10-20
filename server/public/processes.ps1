# Çalışan tüm süreçleri çek, isimlere .exe ekle ve dosyaya yaz
$OutputFile = "C:\Users\$env:USERNAME\Download\process.txt"
Get-Process | Select-Object @{Name='Name';Expression={$_.Name + '.exe'}}, ID, CPU, Path, StartTime | Sort-Object Name | Format-Table -AutoSize | Out-File -FilePath $OutputFile -Encoding UTF8
Write-Host "Süreçler $OutputFile dosyasına kaydedildi."