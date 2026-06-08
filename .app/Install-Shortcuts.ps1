$ErrorActionPreference = "Stop"

$workspace = Split-Path -Parent $PSScriptRoot
$startScript = Join-Path $PSScriptRoot "Start-LiveCaptionsToNotepad.ps1"
$stopScript = Join-Path $PSScriptRoot "Stop-LiveCaptionsToNotepad.ps1"
$targetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$notepadIcon = Join-Path $env:SystemRoot "System32\notepad.exe"
$stopIcon = Join-Path $env:SystemRoot "System32\shell32.dll"

$baseName = -join ([char[]]@(
    0x30e9, 0x30a4, 0x30d6,
    0x30ad, 0x30e3, 0x30d7, 0x30b7, 0x30e7, 0x30f3,
    0x6587, 0x5b57, 0x8d77, 0x3053, 0x3057
))
$fileOnlyMode = -join ([char[]]@(0x88cf, 0x4fdd, 0x5b58))
$stopMode = -join ([char[]]@(0x505c, 0x6b62))

$notepadName = "$baseName.lnk"
$fileOnlyName = "$baseName $fileOnlyMode.lnk"
$stopName = "$baseName$stopMode.lnk"

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

$taskbarDir = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
if (Test-Path -LiteralPath $taskbarDir) {
    $shortcutDirs += $taskbarDir
}

$shell = New-Object -ComObject WScript.Shell

function New-AppShortcut {
    param(
        [string]$Directory,
        [string]$Name,
        [string]$Arguments,
        [string]$IconLocation,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory | Out-Null
    }

    $shortcut = $script:shell.CreateShortcut((Join-Path $Directory $Name))
    $shortcut.TargetPath = $script:targetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $script:workspace
    $shortcut.IconLocation = $IconLocation
    $shortcut.WindowStyle = 7
    $shortcut.Description = $Description
    $shortcut.Save()
}

$fileOnlyArgs = "-WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -NoPasteToNotepad"
$notepadArgs = "-WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File `"$startScript`""
$stopArgs = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$stopScript`""

foreach ($dir in $shortcutDirs) {
    New-AppShortcut -Directory $dir -Name $notepadName -Arguments $notepadArgs -IconLocation "$notepadIcon,0" -Description "Microsoft Live Captions to Notepad"
    New-AppShortcut -Directory $dir -Name $fileOnlyName -Arguments $fileOnlyArgs -IconLocation "$notepadIcon,0" -Description "Microsoft Live Captions to text file"
    New-AppShortcut -Directory $dir -Name $stopName -Arguments $stopArgs -IconLocation "$stopIcon,109" -Description "Stop Live Captions transcription and open latest file"
}

Write-Host "Shortcuts were created."
