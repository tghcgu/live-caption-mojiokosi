$ErrorActionPreference = "SilentlyContinue"

$currentProcessId = $PID
$scriptName = "Start-LiveCaptionsToNotepad.ps1"
$startScriptPath = Join-Path $PSScriptRoot $scriptName
$startScriptPattern = [regex]::Escape($startScriptPath)
$workspace = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $workspace "transcripts"

Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $currentProcessId -and
        $_.CommandLine -match "(?i)-File\s+`"?$startScriptPattern`"?"
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
    }

Start-Sleep -Milliseconds 300

$latestTranscript = Get-ChildItem -LiteralPath $outputDirectory -Filter "caption-*.txt" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -ne $latestTranscript) {
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$($latestTranscript.FullName)`""
}
