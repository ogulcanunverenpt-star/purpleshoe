Add-Type -AssemblyName System.Drawing

function Get-IconBase64 {
    param([string]$path)

    if (-not $path -or -not (Test-Path $path)) { return $null }

    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
        if ($icon) {
            $bmp = $icon.ToBitmap()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bytes = $ms.ToArray()
            $ms.Dispose()
            $bmp.Dispose()
            $icon.Dispose()
            return [Convert]::ToBase64String($bytes)
        }
    } catch {
        return $null
    }
    return $null
}

# Çalışan processler
$runningProcesses = Get-Process | ForEach-Object {
    $path = $_.Path
    [PSCustomObject]@{
        Name        = $_.Name
        Id          = $_.Id
        Path        = $path
        Company     = $_.Company
        Description = $_.Description
        IconBase64  = if ($path) { Get-IconBase64 $path } else { $null }
    }
}

# Yüklü uygulamalar (sadece .exe path’i olanlar)
$installedApps = Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -ne $null } |
    ForEach-Object {
        $exePath = $null
        if ($_.DisplayIcon) {
            # Bazı değerlerde ,0 veya diğer argümanlar oluyor → temizle
            $exePath = $_.DisplayIcon -replace ",.*$",""
            if (-not (Test-Path $exePath)) { $exePath = $null }
        }

        [PSCustomObject]@{
            DisplayName = $_.DisplayName
            Publisher   = $_.Publisher
            InstallDate = $_.InstallDate
            Executable  = $exePath
            IconBase64  = if ($exePath) { Get-IconBase64 $exePath } else { $null }
        }
    } | Where-Object { $_.Executable -ne $null }

$pslist = @{
    running   = $runningProcesses
    installed = $installedApps
} | ConvertTo-Json -Depth 3

# essentials klasörüne JSON olarak yaz
$essentialsPath = ".\essentials\pslist.json"
if (-not (Test-Path ".\essentials")) {
    New-Item -ItemType Directory -Path ".\essentials" | Out-Null
}
$pslist | Out-File -FilePath $essentialsPath -Encoding utf8

# Marker’larla stdout’a bas
Write-Output "pscanburda:$pslist`npscanbitti:"
