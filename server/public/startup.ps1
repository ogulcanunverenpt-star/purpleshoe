param (
    [string]$filePath  # Dosya yolunu parametre olarak al
)



# Başlangıç klasörünün yolu
$startupFolder = [System.Environment]::GetFolderPath('Startup')

# Dosya adını al
$fileName = [System.IO.Path]::GetFileName($filePath)

# Kısayol dosyasının hedef yolu
$shortcutPath = Join-Path $startupFolder "$fileName.lnk"

# Kısayol oluşturma
$WScriptShell = New-Object -ComObject WScript.Shell
$shortcut = $WScriptShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $filePath
$shortcut.Save()

Write-Host "Startup'a kısayol başarıyla eklendi: $shortcutPath"
