$ErrorActionPreference = "Stop"

$workspace = Split-Path -Parent $PSScriptRoot
$startScript = Join-Path $PSScriptRoot "Start-LiveCaptionsToNotepad.ps1"
$stopScript = Join-Path $PSScriptRoot "Stop-LiveCaptionsToNotepad.ps1"
$targetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$notepadIcon = Join-Path $env:SystemRoot "System32\notepad.exe"
$stopIcon = Join-Path $env:SystemRoot "System32\shell32.dll"
$startName = "ライブキャプション文字起こし.lnk"
$stopName = "ライブキャプション文字起こし停止.lnk"

$transcripts = Join-Path $workspace "transcripts"
if (-not (Test-Path -LiteralPath $transcripts)) {
    New-Item -ItemType Directory -Path $transcripts | Out-Null
}

try {
    (Get-Item -LiteralPath $PSScriptRoot).Attributes =
        (Get-Item -LiteralPath $PSScriptRoot).Attributes -bor [System.IO.FileAttributes]::Hidden
} catch {
}

$shortcutDirs = @(
    $workspace,
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("Programs")
)

$shell = New-Object -ComObject WScript.Shell

foreach ($dir in $shortcutDirs) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    $startShortcut = $shell.CreateShortcut((Join-Path $dir $startName))
    $startShortcut.TargetPath = $targetPath
    $startShortcut.Arguments = "-WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -NoPasteToNotepad"
    $startShortcut.WorkingDirectory = $workspace
    $startShortcut.IconLocation = "$notepadIcon,0"
    $startShortcut.WindowStyle = 7
    $startShortcut.Description = "Microsoft Live Captions to text file"
    $startShortcut.Save()

    $stopShortcut = $shell.CreateShortcut((Join-Path $dir $stopName))
    $stopShortcut.TargetPath = $targetPath
    $stopShortcut.Arguments = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$stopScript`""
    $stopShortcut.WorkingDirectory = $workspace
    $stopShortcut.IconLocation = "$stopIcon,109"
    $stopShortcut.WindowStyle = 7
    $stopShortcut.Description = "Stop Live Captions transcription and open latest file"
    $stopShortcut.Save()
}

Write-Host "Shortcuts were created."
