# list_apps.ps1
$apps = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
          HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } | Select-Object -Unique DisplayName
$names = $apps | ForEach-Object { $_.DisplayName }
# return JSON array on stdout
Write-Output ($names | ConvertTo-Json -Compress)
