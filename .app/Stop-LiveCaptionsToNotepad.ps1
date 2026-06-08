$ErrorActionPreference = "SilentlyContinue"

$currentProcessId = $PID
$scriptName = "Start-LiveCaptionsToNotepad.ps1"
$startScriptPath = Join-Path $PSScriptRoot $scriptName
$startScriptPattern = [regex]::Escape($startScriptPath)
$workspace = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $workspace "transcripts"
$stopRequestPath = Join-Path $PSScriptRoot "stop-request.flag"
$latestTranscriptPathFile = Join-Path $PSScriptRoot "latest-transcript-path.txt"

$runningProcesses = Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $currentProcessId -and
        $_.CommandLine -match "(?i)-File\s+`"?$startScriptPattern`"?"
    }

if ($null -ne $runningProcesses) {
    Set-Content -LiteralPath $stopRequestPath -Value (Get-Date).ToString("o") -Encoding ASCII

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        Start-Sleep -Milliseconds 200

        $stillRunning = Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $currentProcessId -and
                $_.CommandLine -match "(?i)-File\s+`"?$startScriptPattern`"?"
            }

        if ($null -eq $stillRunning) {
            break
        }
    }

    $stillRunning = Get-CimInstance Win32_Process |
        Where-Object {
            $_.ProcessId -ne $currentProcessId -and
            $_.CommandLine -match "(?i)-File\s+`"?$startScriptPattern`"?"
        }

    foreach ($process in $stillRunning) {
        Stop-Process -Id $process.ProcessId -Force
    }
}

$latestTranscriptPath = $null
if (Test-Path -LiteralPath $latestTranscriptPathFile) {
    $latestTranscriptPath = (Get-Content -LiteralPath $latestTranscriptPathFile -Raw).Trim()
}

if ([string]::IsNullOrWhiteSpace($latestTranscriptPath) -or -not (Test-Path -LiteralPath $latestTranscriptPath)) {
    $latestTranscript = Get-ChildItem -LiteralPath $outputDirectory -Filter "caption-*.txt" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $latestTranscript) {
        $latestTranscriptPath = $latestTranscript.FullName
    }
}

if (-not [string]::IsNullOrWhiteSpace($latestTranscriptPath) -and (Test-Path -LiteralPath $latestTranscriptPath)) {
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$latestTranscriptPath`""
}
