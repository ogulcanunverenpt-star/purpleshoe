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

function Get-ExeVersion {
    param([string]$path)
    if (-not $path -or -not (Test-Path $path)) { return $null }
    try {
        $info = (Get-Item $path).VersionInfo
        return $info.ProductVersion
    } catch {
        return $null
    }
}

function Get-Vulnerabilities {
    param(
        [string]$product,
        [string]$version
    )

    if (-not $product) { return @() }

    try {
        $keyword = "$product $version"
        $uri = "https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=$([System.Web.HttpUtility]::UrlEncode($keyword))"

        $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction SilentlyContinue
        if ($null -ne $response.vulnerabilities) {
            return $response.vulnerabilities | ForEach-Object {
                $cve = $_.cve
                $refs = @()
                if ($cve.references -and $cve.references.url) {
                    $refs = $cve.references.url
                }

                [PSCustomObject]@{
                    id        = $cve.id
                    published = $cve.published
                    severity  = $cve.metrics.cvssMetricV31.cvssData.baseSeverity
                    references = $refs
                    pocLinks   = $refs | Where-Object {
                        $_ -match "exploit-db" -or
                        $_ -match "github.com" -or
                        $_ -match "packetstormsecurity" -or
                        $_ -match "0day" -or
                        $_ -match "poc"
                    }
                }
            }
        }
    } catch {
        return @()
    }
    return @()
}


# Çalışan processler
$runningProcesses = Get-Process | ForEach-Object {
    $path = $_.Path
    $version = if ($path) { Get-ExeVersion $path } else { $null }
    $vulns = if ($version) { Get-Vulnerabilities $_.Name $version } else { @() }

    [PSCustomObject]@{
        Name                  = $_.Name
        Id                    = $_.Id
        Path                  = $path
        Company               = $_.Company
        Description           = $_.Description
        Version               = $version
        "known-vulnerabilities" = $vulns
        IconBase64            = if ($path) { Get-IconBase64 $path } else { $null }
    }
}

# Yüklü uygulamalar (sadece .exe path’i olanlar)
$installedApps = Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*, 
                                 HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -ne $null } |
    ForEach-Object {
        $exePath = $null
        if ($_.DisplayIcon) {
            $exePath = $_.DisplayIcon -replace ",.*$",""
            if (-not (Test-Path $exePath)) { $exePath = $null }
        }

        if ($exePath -and $exePath -like "*.exe") {
            $ver = Get-ExeVersion $exePath
            $vulns = if ($ver) { Get-Vulnerabilities $_.DisplayName $ver } else { @() }

            [PSCustomObject]@{
                DisplayName           = $_.DisplayName
                Publisher             = $_.Publisher
                InstallDate           = $_.InstallDate
                exe                   = $exePath
                Version               = $ver
                "known-vulnerabilities" = $vulns
                IconBase64            = if ($exePath) { Get-IconBase64 $exePath } else { $null }
            }
        }
    } | Where-Object { $_.exe -ne $null }

# Windows sürümü bilgisi
$windowsInfo = Get-ComputerInfo | Select-Object OsName, OsVersion, OsBuildNumber
$winVulns = Get-Vulnerabilities $windowsInfo.OsName $windowsInfo.OsVersion

# JSON çıktısı
$pslist = @{
    running   = $runningProcesses
    installed = $installedApps
    windows   = @{
        Name   = $windowsInfo.OsName
        Version = $windowsInfo.OsVersion
        Build   = $windowsInfo.OsBuildNumber
        "known-vulnerabilities" = $winVulns
    }
} | ConvertTo-Json -Depth 4

# essentials klasörüne JSON olarak yaz
$essentialsPath = ".\essentials\pslist.json"
if (-not (Test-Path ".\essentials")) {
    New-Item -ItemType Directory -Path ".\essentials" | Out-Null
}
$pslist | Out-File -FilePath $essentialsPath -Encoding utf8

# Marker’larla stdout’a bas
Write-Output "pscanburda:$pslist`npscanbitti:"
