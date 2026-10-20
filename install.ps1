[CmdletBinding()]
param(
    [string]$GodotPath,
    [switch]$Editor
)

$ErrorActionPreference = 'Stop'
$projectPath = Join-Path $PSScriptRoot 'voip-3d'
$projectFile = Join-Path $projectPath 'project.godot'

if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
    throw "Godot project file not found: $projectFile"
}

if ([string]::IsNullOrWhiteSpace($GodotPath)) {
    $godotCommand = Get-Command godot -ErrorAction SilentlyContinue
    if ($godotCommand) {
        $GodotPath = $godotCommand.Source
    } else {
        $GodotPath = Join-Path $HOME 'Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe'
    }
}

if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "Godot executable not found. Pass -GodotPath with the Godot 4 executable path."
}

function Invoke-GodotCheck {
    param(
        [string]$Step,
        [string[]]$Arguments
    )

    $output = & $GodotPath @Arguments 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0 -or ($output -match '(ERROR:|SCRIPT ERROR:)')) {
        throw "$Step failed (exit code $exitCode)."
    }
}

Write-Host 'Importing project resources and checking the project...'
Invoke-GodotCheck -Step 'Godot import' -Arguments @('--headless', '--editor', '--path', $projectPath, '--import', '--quit')

Write-Host 'Checking that the configured main scene starts...'
Invoke-GodotCheck -Step 'Godot startup check' -Arguments @('--headless', '--path', $projectPath, '--quit-after', '60')
Write-Host 'Checking that the renamed Openworld scene starts...'
Invoke-GodotCheck -Step 'Openworld scene check' -Arguments @('--headless', '--path', $projectPath, '--scene', 'res://openworld/main.tscn', '--quit-after', '60')

if ($Editor) {
    $startedProcess = Start-Process -FilePath $GodotPath -ArgumentList "--editor --path `"$projectPath`"" -WorkingDirectory $projectPath -PassThru
} else {
    $startedProcess = Start-Process -FilePath $GodotPath -ArgumentList "--path `"$projectPath`"" -WorkingDirectory $projectPath -PassThru
}
Write-Host "Started Godot process $($startedProcess.Id)."
