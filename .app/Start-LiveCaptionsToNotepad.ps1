param(
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "transcripts"),
    [int]$PollMilliseconds = 200,
    [switch]$NoStartLiveCaptions,
    [switch]$NoPasteToNotepad,
    [switch]$ContinuousNotepadSync
)

$ErrorActionPreference = "Stop"

$currentProcessId = $PID
$currentScriptPath = $MyInvocation.MyCommand.Path
$startScriptPattern = [regex]::Escape($currentScriptPath)
$stopRequestPath = Join-Path $PSScriptRoot "stop-request.flag"

$existingProcesses = @(Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $currentProcessId -and
        $_.CommandLine -match "(?i)-File\s+`"?$startScriptPattern`"?"
    })

if ($existingProcesses.Count -gt 0) {
    Set-Content -LiteralPath $stopRequestPath -Value (Get-Date).ToString("o") -Encoding ASCII

    for ($attempt = 1; $attempt -le 15; $attempt++) {
        Start-Sleep -Milliseconds 200

        $existingProcesses = @(Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $currentProcessId -and
                $_.CommandLine -match "(?i)-File\s+`"?$startScriptPattern`"?"
            })

        if ($existingProcesses.Count -eq 0) {
            break
        }
    }

    foreach ($process in $existingProcesses) {
        try {
            Stop-Process -Id $process.ProcessId -Force
        } catch {
        }
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$transcriptPath = Join-Path $OutputDirectory "caption-$timestamp.txt"
New-Item -ItemType File -Path $transcriptPath -Force | Out-Null

$latestTranscriptPathFile = Join-Path $PSScriptRoot "latest-transcript-path.txt"
Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $latestTranscriptPathFile -Value $transcriptPath -Encoding UTF8

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeWindowTools
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    public const byte VK_LWIN = 0x5B;
    public const byte VK_CONTROL = 0x11;
    public const byte VK_L = 0x4C;
    public const int VK_LBUTTON = 0x01;
    public const uint KEYEVENTF_KEYUP = 0x0002;
}
"@

function Test-LeftMousePressedSinceLastCheck {
    return ((([int][NativeWindowTools]::GetAsyncKeyState([NativeWindowTools]::VK_LBUTTON)) -band 0x0001) -ne 0)
}

function Send-LiveCaptionsShortcut {
    [NativeWindowTools]::keybd_event([NativeWindowTools]::VK_LWIN, 0, 0, [UIntPtr]::Zero)
    [NativeWindowTools]::keybd_event([NativeWindowTools]::VK_CONTROL, 0, 0, [UIntPtr]::Zero)
    [NativeWindowTools]::keybd_event([NativeWindowTools]::VK_L, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [NativeWindowTools]::keybd_event([NativeWindowTools]::VK_L, 0, [NativeWindowTools]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    [NativeWindowTools]::keybd_event([NativeWindowTools]::VK_CONTROL, 0, [NativeWindowTools]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    [NativeWindowTools]::keybd_event([NativeWindowTools]::VK_LWIN, 0, [NativeWindowTools]::KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Get-NotepadWindow {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$FilePath
    )

    $fileName = ""
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $fileName = [System.IO.Path]::GetFileName($FilePath)
    }

    try {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero -and [NativeWindowTools]::IsWindow($Process.MainWindowHandle)) {
            return [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
        }
    } catch {
    }

    try {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($window in $windows) {
            try {
                $name = $window.Current.Name
                $className = $window.Current.ClassName
                $nativeWindowHandle = $window.Current.NativeWindowHandle
                $processName = ""

                try {
                    $processName = (Get-Process -Id $window.Current.ProcessId -ErrorAction Stop).ProcessName
                } catch {
                }

                $isSameProcess = ($null -ne $Process -and $window.Current.ProcessId -eq $Process.Id)
                $looksLikeNotepad = (
                    $processName -match "(?i)^notepad$" -or
                    $className -match "(?i)notepad|applicationframewindow" -or
                    $name -match "(?i)notepad" -or
                    $name -match "\u30e1\u30e2\u5e33"
                )
                $looksLikeTargetFile = (
                    -not [string]::IsNullOrWhiteSpace($fileName) -and
                    $name.IndexOf($fileName, [StringComparison]::OrdinalIgnoreCase) -ge 0
                )

                if ($nativeWindowHandle -ne 0 -and ($isSameProcess -or $looksLikeTargetFile -or ($looksLikeNotepad -and $looksLikeTargetFile))) {
                    return $window
                }
            } catch {
            }
        }
    } catch {
    }

    return $null
}

function Get-NotepadWindowHandle {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$FilePath
    )

    $window = Get-NotepadWindow -Process $Process -FilePath $FilePath
    if ($null -eq $window) {
        return [IntPtr]::Zero
    }

    try {
        if ($window.Current.NativeWindowHandle -ne 0) {
            return [IntPtr]$window.Current.NativeWindowHandle
        }
    } catch {
    }

    return [IntPtr]::Zero
}

function Get-ForegroundProcessId {
    $foregroundWindow = [NativeWindowTools]::GetForegroundWindow()
    if ($foregroundWindow -eq [IntPtr]::Zero) {
        return $null
    }

    [uint32]$processId = 0
    [NativeWindowTools]::GetWindowThreadProcessId($foregroundWindow, [ref]$processId) | Out-Null

    if ($processId -eq 0) {
        return $null
    }

    return [int]$processId
}

function Test-NotepadIsForeground {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$FilePath
    )

    if ($null -eq $Process) {
        return $false
    }

    $foregroundWindow = [NativeWindowTools]::GetForegroundWindow()
    $targetWindow = Get-NotepadWindowHandle -Process $Process -FilePath $FilePath
    if ($foregroundWindow -ne [IntPtr]::Zero -and $targetWindow -ne [IntPtr]::Zero -and $foregroundWindow -eq $targetWindow) {
        return $true
    }

    $foregroundProcessId = Get-ForegroundProcessId
    if ($null -eq $foregroundProcessId) {
        return $false
    }

    try {
        $Process.Refresh()
        return $foregroundProcessId -eq $Process.Id
    } catch {
    }

    return $false
}

function Focus-NotepadEditor {
    param([System.Windows.Automation.AutomationElement]$Window)

    if ($null -eq $Window) {
        return $false
    }

    $controlTypes = @(
        [System.Windows.Automation.ControlType]::Document,
        [System.Windows.Automation.ControlType]::Edit
    )

    foreach ($controlType in $controlTypes) {
        try {
            $condition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                $controlType
            )
            $editor = $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($null -ne $editor) {
                $editor.SetFocus()
                return $true
            }
        } catch {
        }
    }

    try {
        $Window.SetFocus()
        return $true
    } catch {
    }

    return $false
}

function Test-UiNoise {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }

    $clean = ($Text -replace "\s+", " ").Trim()
    $noisePatterns = @(
        "^(Live captions|Live Captions|\u30e9\u30a4\u30d6\s*\u30ad\u30e3\u30d7\u30b7\u30e7\u30f3)$",
        "^(Settings|Caption settings|Close|Minimize|Maximize|Restore|More options)$",
        "^(\u8a2d\u5b9a|\u9589\u3058\u308b|\u6700\u5c0f\u5316|\u6700\u5927\u5316|\u5143\u306b\u623b\u3059|\u305d\u306e\u4ed6\u306e\u30aa\u30d7\u30b7\u30e7\u30f3)$",
        "^(Ready to caption|No audio detected|Listening|Microphone)$",
        "^(\u30ad\u30e3\u30d7\u30b7\u30e7\u30f3\u306e\u6e96\u5099\u304c\u3067\u304d\u307e\u3057\u305f|\u97f3\u58f0\u304c\u691c\u51fa\u3055\u308c\u307e\u305b\u3093|\u805e\u304d\u53d6\u308a\u4e2d|\u30de\u30a4\u30af)$",
        "^\S+\s*\([^)]+\)\s*\u306e\s*\u30e9\u30a4\u30d6\s*\u30ad\u30e3\u30d7\u30b7\u30e7\u30f3\u3092\u8868\u793a\u3059\u308b\u6e96\u5099\u304c\u3067\u304d\u307e\u3057\u305f$"
    )

    foreach ($pattern in $noisePatterns) {
        if ($clean -match $pattern) {
            return $true
        }
    }

    $notepadUiPatterns = @(
        "\.txt\b",
        "Windows\s*\(CRLF\)",
        "\bUTF-8\b",
        "^\s*(Text|\u30c6\u30ad\u30b9\u30c8|Zoom|\u30ba\u30fc\u30e0)\s*$",
        "^(\u884c|Line)\s*\d+",
        "^(\u5217|Column)\s*\d+",
        "^(\u30bf\u30d6\u3092\u9589\u3058\u308b|Close tab)"
    )

    foreach ($pattern in $notepadUiPatterns) {
        if ($clean -match $pattern) {
            return $true
        }
    }

    return $false
}

function Normalize-CaptionText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -replace "`r`n|`r|`n", "`n").Split("`n")) {
        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $lines.Add($trimmed)
        }
    }

    return ($lines -join "`r`n")
}

function Split-CaptionLines {
    param([string]$Text)

    $lines = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $lines
    }

    foreach ($line in ($Text -replace "`r`n|`r|`n", "`n").Split("`n")) {
        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not (Test-UiNoise $trimmed)) {
            $lines.Add($trimmed)
        }
    }

    return $lines
}

function Get-ElementTextItems {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [System.Windows.Automation.ControlType]$ControlType
    )

    $items = New-Object System.Collections.Generic.List[string]
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        $ControlType
    )

    try {
        $elements = $Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        foreach ($child in $elements) {
            try {
                $text = Normalize-CaptionText $child.Current.Name
                if (-not (Test-UiNoise $text)) {
                    if ($items.Count -eq 0 -or $items[$items.Count - 1] -ne $text) {
                        $items.Add($text)
                    }
                }
            } catch {
            }
        }
    } catch {
    }

    return $items
}

function Test-PrefixRevision {
    param(
        [string]$Shorter,
        [string]$Longer
    )

    if ([string]::IsNullOrWhiteSpace($Shorter) -or [string]::IsNullOrWhiteSpace($Longer)) {
        return $false
    }

    $shortComparison = Get-ComparisonText $Shorter
    $longComparison = Get-ComparisonText $Longer

    if ($shortComparison.Length -eq 0 -or $longComparison.Length -eq 0) {
        return $false
    }

    if ($shortComparison.Length -ge $longComparison.Length) {
        return $false
    }

    if ($longComparison.StartsWith($shortComparison)) {
        return $true
    }

    if ($shortComparison.Length -lt 8) {
        return $false
    }

    $prefixLength = [Math]::Min($shortComparison.Length, $longComparison.Length)
    $longPrefix = $longComparison.Substring(0, $prefixLength)
    return (Test-SimilarText -Left $shortComparison -Right $longPrefix -MaxDistanceRatio 0.18)
}

function Compress-CaptionItems {
    param([System.Collections.Generic.List[string]]$Items)

    $compressed = New-Object System.Collections.Generic.List[string]

    foreach ($item in $Items) {
        $text = Normalize-CaptionText $item
        if (Test-UiNoise $text) {
            continue
        }

        $lines = @()
        foreach ($line in ($text -replace "`r`n|`r|`n", "`n").Split("`n")) {
            $trimmed = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not (Test-UiNoise $trimmed)) {
                $lines += $trimmed
            }
        }

        foreach ($line in $lines) {
            $skipLine = $false

            for ($i = $compressed.Count - 1; $i -ge 0; $i--) {
                $existing = $compressed[$i]

                if ($existing -eq $line) {
                    $skipLine = $true
                    break
                }

                if (Test-PrefixRevision -Shorter $existing -Longer $line) {
                    $compressed.RemoveAt($i)
                    continue
                }

                if (Test-PrefixRevision -Shorter $line -Longer $existing) {
                    $skipLine = $true
                    break
                }
            }

            if (-not $skipLine) {
                $compressed.Add($line)
            }
        }
    }

    return $compressed
}

function Get-LiveCaptionsWindow {
    try {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($window in $windows) {
            try {
                $name = $window.Current.Name
                $className = $window.Current.ClassName
                $processName = ""

                try {
                    $processName = (Get-Process -Id $window.Current.ProcessId -ErrorAction Stop).ProcessName
                } catch {
                }

                $blockedProcess = $processName -match "(?i)^(notepad|cmd|powershell|pwsh|windowsterminal|openconsole)$"
                if ($blockedProcess) {
                    continue
                }

                $looksLikeOutputFile = $name -match "(?i)(livecaptions|caption)-\d{8}-\d{6}\.txt"
                if ($looksLikeOutputFile) {
                    continue
                }

                $processIsLiveCaptions = $processName -match "(?i)^livecaptions$"
                $titleIsLiveCaptions = (
                    $name -match "^(?i:live\s*captions)$" -or
                    $name -match "^\s*\u30e9\u30a4\u30d6\s*\u30ad\u30e3\u30d7\u30b7\u30e7\u30f3\s*$"
                )
                $classLooksUseful = $className -match "(?i)(livecaptions|xaml|corewindow|applicationframewindow)"

                if ($processIsLiveCaptions -or ($titleIsLiveCaptions -and $classLooksUseful)) {
                    return $window
                }
            } catch {
            }
        }
    } catch {
    }

    return $null
}

function Get-LiveCaptionSnapshot {
    param([System.Windows.Automation.AutomationElement]$Window)

    $textItems = Get-ElementTextItems -Element $Window -ControlType ([System.Windows.Automation.ControlType]::Text)

    if ($textItems.Count -eq 0) {
        $textItems = Get-ElementTextItems -Element $Window -ControlType ([System.Windows.Automation.ControlType]::Document)
    }

    if ($textItems.Count -eq 0) {
        return ""
    }

    $captionItems = Compress-CaptionItems -Items $textItems

    if ($captionItems.Count -eq 0) {
        return ""
    }

    return ($captionItems -join "`r`n")
}

function Get-LevenshteinDistance {
    param(
        [string]$Left,
        [string]$Right
    )

    if ($null -eq $Left) {
        $Left = ""
    }
    if ($null -eq $Right) {
        $Right = ""
    }

    $leftLength = $Left.Length
    $rightLength = $Right.Length

    if ($leftLength -eq 0) {
        return $rightLength
    }
    if ($rightLength -eq 0) {
        return $leftLength
    }

    $previous = New-Object int[] ($rightLength + 1)
    $current = New-Object int[] ($rightLength + 1)

    for ($j = 0; $j -le $rightLength; $j++) {
        $previous[$j] = $j
    }

    for ($i = 1; $i -le $leftLength; $i++) {
        $current[0] = $i

        for ($j = 1; $j -le $rightLength; $j++) {
            $cost = 1
            if ($Left[$i - 1] -eq $Right[$j - 1]) {
                $cost = 0
            }

            $deleteCost = $previous[$j] + 1
            $insertCost = $current[$j - 1] + 1
            $replaceCost = $previous[$j - 1] + $cost
            $current[$j] = [Math]::Min([Math]::Min($deleteCost, $insertCost), $replaceCost)
        }

        $swap = $previous
        $previous = $current
        $current = $swap
    }

    return $previous[$rightLength]
}

function Get-ComparisonText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    return (($Text -replace "\s+", "") -replace "[\u3001\u3002\uff0c\uff0e,\.]", "")
}

function Test-CompleteCaptionLine {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return ($Text.Trim() -match "[\u3002\uff0e\.\!\?\uff01\uff1f]$")
}

function Test-RescuableCaptionLine {
    param([string]$Text)

    $comparison = Get-ComparisonText $Text
    if ($comparison.Length -ge 8) {
        return $true
    }

    return (Test-CompleteCaptionLine $Text)
}

function Get-TranscriptText {
    param(
        [string]$Captured,
        [string]$Pending,
        [switch]$IncludePending
    )

    $text = ""
    if ($null -ne $Captured) {
        $text = $Captured
    }

    if ($IncludePending -and -not [string]::IsNullOrWhiteSpace($Pending)) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $Pending
        }

        return $text + "`r`n" + $Pending
    }

    return $text
}

function Test-SimilarText {
    param(
        [string]$Left,
        [string]$Right,
        [double]$MaxDistanceRatio = 0.35
    )

    $leftComparison = Get-ComparisonText $Left
    $rightComparison = Get-ComparisonText $Right

    if ([string]::IsNullOrEmpty($leftComparison) -or [string]::IsNullOrEmpty($rightComparison)) {
        return $false
    }

    $maxLength = [Math]::Max($leftComparison.Length, $rightComparison.Length)
    if ($maxLength -eq 0) {
        return $true
    }

    $distance = Get-LevenshteinDistance -Left $leftComparison -Right $rightComparison
    return (($distance / $maxLength) -le $MaxDistanceRatio)
}

function Set-ClipboardTextWithRetry {
    param([string]$Text)

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return $true
        } catch {
            Start-Sleep -Milliseconds 80
        }
    }

    return $false
}

function Sync-TextToNotepad {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$FilePath,
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return "pasted"
    }

    if (-not (Test-NotepadIsForeground -Process $Process -FilePath $FilePath)) {
        return "paused"
    }

    $window = Get-NotepadWindow -Process $Process -FilePath $FilePath
    $oldClipboard = $null
    $hadClipboardText = $false

    try {
        $hadClipboardText = [System.Windows.Forms.Clipboard]::ContainsText()
        if ($hadClipboardText) {
            $oldClipboard = [System.Windows.Forms.Clipboard]::GetText()
        }
    } catch {
    }

    if (-not (Set-ClipboardTextWithRetry -Text $Text)) {
        return "failed"
    }

    Focus-NotepadEditor -Window $window | Out-Null
    Start-Sleep -Milliseconds 50
    [System.Windows.Forms.SendKeys]::SendWait("^a")
    Start-Sleep -Milliseconds 40
    [System.Windows.Forms.SendKeys]::SendWait("^v")
    Start-Sleep -Milliseconds 50
    [System.Windows.Forms.SendKeys]::SendWait("^s")

    if ($hadClipboardText) {
        Start-Sleep -Milliseconds 50
        Set-ClipboardTextWithRetry -Text $oldClipboard | Out-Null
    }

    return "pasted"
}

$notepad = $null
if (-not $NoPasteToNotepad) {
    $notepad = Start-Process -FilePath "notepad.exe" -ArgumentList "`"$transcriptPath`"" -PassThru
    Start-Sleep -Milliseconds 1000
}

if (-not $NoStartLiveCaptions -and $null -eq (Get-LiveCaptionsWindow)) {
    Send-LiveCaptionsShortcut
}

Write-Host ""
Write-Host "Live Captions to Notepad is running."
Write-Host "Output file: $transcriptPath"
Write-Host "Press Ctrl + C in this window to stop."
Write-Host ""

$windowMissingNoticeShown = $false
$textMissingNoticeShown = $false
$pasteFailureNoticeShown = $false
$lastLiveCaptionsStartAttempt = [DateTime]::MinValue
$capturedText = ""
$capturedLines = New-Object System.Collections.Generic.List[string]
$pendingCaptionText = ""
$pendingCaptionFirstSeenAt = $null
$PendingRescueMilliseconds = 1000
$CapturedLineDedupWindow = 40
$lastSyncedNotepadText = ""
$lastNotepadWasForeground = $false

function Save-CapturedText {
    param([string]$Text)

    [System.IO.File]::WriteAllText($transcriptPath, $Text, [System.Text.Encoding]::UTF8)
}

function Add-CapturedCaptionLine {
    param([string]$Line)

    $newLine = Normalize-CaptionText $Line
    if ([string]::IsNullOrWhiteSpace($newLine)) {
        return $false
    }

    $count = $script:capturedLines.Count

    if ($count -gt 0) {
        $lastIndex = $count - 1
        $lastLine = $script:capturedLines[$lastIndex]

        if ($lastLine -eq $newLine) {
            return $false
        }

        if (Test-PrefixRevision -Shorter $newLine -Longer $lastLine) {
            return $false
        }

        $looksLikeRevision = Test-PrefixRevision -Shorter $lastLine -Longer $newLine

        if (-not $looksLikeRevision) {
            $lastComparison = Get-ComparisonText $lastLine
            $newComparison = Get-ComparisonText $newLine

            if ($lastComparison.Length -ge 8 -and
                $newComparison.Length -ge [int]($lastComparison.Length * 0.7)) {
                $looksLikeRevision = Test-SimilarText -Left $lastLine -Right $newLine -MaxDistanceRatio 0.28
            }
        }

        if ($looksLikeRevision) {
            $script:capturedLines[$lastIndex] = $newLine
            $script:capturedText = ($script:capturedLines -join "`r`n")
            return $true
        }

        $dedupStart = [Math]::Max(0, $count - $script:CapturedLineDedupWindow)
        for ($i = $lastIndex; $i -ge $dedupStart; $i--) {
            if ($script:capturedLines[$i] -eq $newLine) {
                return $false
            }
        }
    }

    $script:capturedLines.Add($newLine)
    $script:capturedText = ($script:capturedLines -join "`r`n")
    return $true
}

function Test-PendingCaptionSupersededByLine {
    param(
        [string]$Pending,
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Pending) -or [string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    if ($Pending -eq $Line) {
        return $true
    }

    if (Test-PrefixRevision -Shorter $Pending -Longer $Line) {
        return $true
    }

    $pendingComparison = Get-ComparisonText $Pending
    $lineComparison = Get-ComparisonText $Line

    if ($pendingComparison.Length -lt 8 -or $lineComparison.Length -lt [int]($pendingComparison.Length * 0.6)) {
        return $false
    }

    return (Test-SimilarText -Left $Pending -Right $Line -MaxDistanceRatio 0.34)
}

function Clear-PendingCaptionText {
    $script:pendingCaptionText = ""
    $script:pendingCaptionFirstSeenAt = $null
}

function Set-PendingCaptionTextRaw {
    param(
        [string]$Text,
        [switch]$KeepFirstSeen
    )

    $newPending = Normalize-CaptionText $Text
    if ([string]::IsNullOrWhiteSpace($newPending)) {
        Clear-PendingCaptionText
        return
    }

    if (-not $KeepFirstSeen -or $null -eq $script:pendingCaptionFirstSeenAt -or [string]::IsNullOrWhiteSpace($script:pendingCaptionText)) {
        $script:pendingCaptionFirstSeenAt = Get-Date
    }

    $script:pendingCaptionText = $newPending
}

function Test-PendingCaptionReadyToRescue {
    if ([string]::IsNullOrWhiteSpace($script:pendingCaptionText)) {
        return $false
    }

    if (Test-CompleteCaptionLine $script:pendingCaptionText) {
        return $true
    }

    if (-not (Test-RescuableCaptionLine $script:pendingCaptionText)) {
        return $false
    }

    if ($null -eq $script:pendingCaptionFirstSeenAt) {
        return $false
    }

    return (((Get-Date) - $script:pendingCaptionFirstSeenAt).TotalMilliseconds -ge $script:PendingRescueMilliseconds)
}

function Flush-PendingCaptionText {
    if ([string]::IsNullOrWhiteSpace($script:pendingCaptionText)) {
        return $false
    }

    if (-not (Test-PendingCaptionReadyToRescue)) {
        Clear-PendingCaptionText
        return $false
    }

    $changed = Add-CapturedCaptionLine -Line $script:pendingCaptionText
    Clear-PendingCaptionText
    return $changed
}

function Set-PendingCaptionTextSafely {
    param([string]$Text)

    $newPending = Normalize-CaptionText $Text
    if ([string]::IsNullOrWhiteSpace($newPending)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($script:pendingCaptionText)) {
        Set-PendingCaptionTextRaw -Text $newPending
        return $false
    }

    if (Test-PendingCaptionSupersededByLine -Pending $script:pendingCaptionText -Line $newPending) {
        Set-PendingCaptionTextRaw -Text $newPending -KeepFirstSeen
        return $false
    }

    if (Test-PendingCaptionSupersededByLine -Pending $newPending -Line $script:pendingCaptionText) {
        return $false
    }

    $changed = Flush-PendingCaptionText
    Set-PendingCaptionTextRaw -Text $newPending
    return $changed
}

function Resolve-PendingCaptionBeforeCapturedLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($script:pendingCaptionText)) {
        return $false
    }

    if (Test-PendingCaptionSupersededByLine -Pending $script:pendingCaptionText -Line $Line) {
        Clear-PendingCaptionText
        return $false
    }

    return (Flush-PendingCaptionText)
}

while ($true) {
    if (Test-Path -LiteralPath $stopRequestPath) {
        $finalText = Get-TranscriptText -Captured $capturedText -Pending $pendingCaptionText -IncludePending
        Save-CapturedText -Text $finalText

        Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
        break
    }

    $liveCaptionsWindow = Get-LiveCaptionsWindow

    if ($null -eq $liveCaptionsWindow) {
        if (-not $windowMissingNoticeShown) {
            Write-Host "Waiting for the Windows Live Captions window..."
            Write-Host "If it did not open, press Win + Ctrl + L."
            $windowMissingNoticeShown = $true
        }

        if (-not $NoStartLiveCaptions -and ((Get-Date) - $lastLiveCaptionsStartAttempt).TotalSeconds -ge 5) {
            Send-LiveCaptionsShortcut
            $lastLiveCaptionsStartAttempt = Get-Date
        }

        Start-Sleep -Milliseconds $PollMilliseconds
        continue
    }

    $windowMissingNoticeShown = $false
    $snapshot = Get-LiveCaptionSnapshot -Window $liveCaptionsWindow

    if ([string]::IsNullOrWhiteSpace($snapshot)) {
        if (-not $textMissingNoticeShown) {
            Write-Host "Live Captions was found, but no readable caption text is available yet."
            $textMissingNoticeShown = $true
        }

        Start-Sleep -Milliseconds $PollMilliseconds
        continue
    }

    $textMissingNoticeShown = $false
    $snapshotLines = Split-CaptionLines $snapshot
    $textChanged = $false

    for ($lineIndex = 0; $lineIndex -lt $snapshotLines.Count; $lineIndex++) {
        $line = $snapshotLines[$lineIndex]
        $isLastSnapshotLine = ($lineIndex -eq ($snapshotLines.Count - 1))

        if ($isLastSnapshotLine -and -not (Test-CompleteCaptionLine $line)) {
            if (Set-PendingCaptionTextSafely -Text $line) {
                $textChanged = $true
            }
            continue
        }

        if (Resolve-PendingCaptionBeforeCapturedLine -Line $line) {
            $textChanged = $true
        }

        if (Add-CapturedCaptionLine -Line $line) {
            $textChanged = $true
        }
    }

    $outputText = Get-TranscriptText -Captured $capturedText -Pending $pendingCaptionText
    $notepadText = Get-TranscriptText -Captured $capturedText -Pending $pendingCaptionText -IncludePending

    if ($NoPasteToNotepad -and $textChanged) {
        Save-CapturedText -Text $outputText
    }

    $notepadIsForeground = $false
    $notepadClickRequested = $false
    if (-not $NoPasteToNotepad) {
        $notepadIsForeground = Test-NotepadIsForeground -Process $notepad -FilePath $transcriptPath
        $notepadClickRequested = $notepadIsForeground -and (Test-LeftMousePressedSinceLastCheck)
    }

    $shouldSyncNotepad = (
        -not $NoPasteToNotepad -and
        $notepadText -ne $lastSyncedNotepadText -and
        $notepadIsForeground -and
        ($ContinuousNotepadSync -or -not $lastNotepadWasForeground -or $notepadClickRequested)
    )

    if ($shouldSyncNotepad) {
        $pasteStatus = Sync-TextToNotepad `
            -Process $notepad `
            -FilePath $transcriptPath `
            -Text $notepadText

        if ($pasteStatus -eq "pasted") {
            $lastSyncedNotepadText = $notepadText
            $pasteFailureNoticeShown = $false
        } elseif ($pasteStatus -eq "failed") {
            if (-not $pasteFailureNoticeShown) {
                Write-Host "Could not sync Notepad. Text is being kept in memory and will be saved on stop."
                $pasteFailureNoticeShown = $true
            }
        }
    }

    $lastNotepadWasForeground = $notepadIsForeground

    Start-Sleep -Milliseconds $PollMilliseconds
}
