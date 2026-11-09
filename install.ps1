[CmdletBinding()]
param(
    [string]$GodotPath,
    [switch]$Editor
)

$ErrorActionPreference = 'Stop'
$projectPath = Join-Path $PSScriptRoot 'voip-3d'
$projectFile = Join-Path $projectPath 'project.godot'
$serverPath = Join-Path $PSScriptRoot 'server'

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
$GodotPath = (Resolve-Path -LiteralPath $GodotPath).Path

$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) {
    throw 'npm not found. Install Node.js and ensure npm is on PATH.'
}
if (-not (Test-Path -LiteralPath (Join-Path $serverPath 'node_modules\express\package.json') -PathType Leaf)) {
    Write-Host 'Installing server dependencies...'
    Push-Location $serverPath
    try {
        & $npm.Source install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit code $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

function Invoke-GodotCheck {
    param(
        [string]$Step,
        [string[]]$Arguments
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $checkPath = $GodotPath
        $consolePath = [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($GodotPath),
            [System.IO.Path]::GetFileNameWithoutExtension($GodotPath) + '_console.exe'
        )
        if (Test-Path -LiteralPath $consolePath -PathType Leaf) { $checkPath = $consolePath }
        $quotedArguments = @($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' })
        $process = Start-Process -FilePath $checkPath -ArgumentList $quotedArguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $output = @(Get-Content -LiteralPath $stdoutFile) + @(Get-Content -LiteralPath $stderrFile)
        $output | ForEach-Object { Write-Host $_ }
        if ($process.ExitCode -ne 0 -or ($output -match '(ERROR:|SCRIPT ERROR:)')) {
            throw "$Step failed (exit code $($process.ExitCode))."
        }
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Importing project resources and checking the project...'
Invoke-GodotCheck -Step 'Godot import' -Arguments @('--headless', '--editor', '--path', $projectPath, '--import', '--quit')

Write-Host 'Checking that the configured main scene starts...'
Invoke-GodotCheck -Step 'Godot startup check' -Arguments @('--headless', '--path', $projectPath, '--quit-after', '60')
Write-Host 'Checking that the renamed Openworld scene starts...'
Invoke-GodotCheck -Step 'Openworld scene check' -Arguments @('--headless', '--path', $projectPath, '--scene', 'res://openworld/main.tscn', '--quit-after', '60')

@{ godotPath = $GodotPath } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $serverPath 'godot-path.local.json') -Encoding UTF8
Write-Host 'Godot path saved for the game server. Start it with: cd server; npm start'

if ($Editor) {
    $startedProcess = Start-Process -FilePath $GodotPath -ArgumentList "--editor --path `"$projectPath`"" -WorkingDirectory $projectPath -PassThru
} else {
    $startedProcess = Start-Process -FilePath $GodotPath -ArgumentList "--path `"$projectPath`"" -WorkingDirectory $projectPath -PassThru
}
Write-Host "Started Godot process $($startedProcess.Id)."
