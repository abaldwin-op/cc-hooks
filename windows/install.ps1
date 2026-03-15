# Claude Code Hooks — Windows Install Script
#
# One-time setup:
# 1. Builds the C# notifications exe
# 2. Registers claude-focus:// and claude-editor:// protocol handlers
#    (for toast button clicks → trigger file / editor launch)
# 3. Creates a Start Menu shortcut with AUMID
#    (Windows requires this for unpackaged apps to show toast notifications)
# 4. Adds hooks to ~/.claude/settings.json (merges, won't overwrite other settings)

$winDir = $PSScriptRoot
$notifDir = Join-Path $winDir "notifications"
$exe = Join-Path $notifDir "bin\notifications.exe"

# Build the C# project
Write-Host "Building..."
dotnet publish (Join-Path $notifDir "src") -c Release -r win-x64 --self-contained false -o (Join-Path $notifDir "bin") 2>&1 | Select-Object -Last 1

# Register protocol handlers
# - claude-focus://  → notifications.exe trigger %1 (creates trigger file for watcher)
# - claude-editor:// → notifications.exe editor %1 (opens configured editor)
foreach ($proto in @(
    @{ name = "claude-focus"; cmd = "trigger" },
    @{ name = "claude-editor"; cmd = "editor" }
)) {
    $base = "HKCU:\Software\Classes\$($proto.name)"
    New-Item -Path $base -Force | Out-Null
    Set-ItemProperty -Path $base -Name "(Default)" -Value "URL:$($proto.name) Protocol"
    New-ItemProperty -Path $base -Name "URL Protocol" -Value "" -Force | Out-Null
    New-Item -Path "$base\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path "$base\shell\open\command" -Name "(Default)" -Value "`"$exe`" $($proto.cmd) `"%1`""
    Write-Host "Registered $($proto.name)://"
}

# Create Start Menu shortcut with AUMID (Application User Model ID).
# The shortcut name = attribution text at the top of toast notifications.
# The shortcut icon = small icon next to the attribution text.
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"

# Remove any old shortcuts pointing to our exe
Get-ChildItem "$startMenu\*.lnk" | ForEach-Object {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($_.FullName)
        if ($sc.TargetPath -match "notifications") { Remove-Item $_.FullName -Force }
    } catch {}
}

# Create fresh shortcut
$lnk = Join-Path $startMenu "Claude Code.lnk"
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = $exe
$titleIco = Join-Path $notifDir "icons\title.ico"
if (Test-Path $titleIco) { $sc.IconLocation = $titleIco }
$sc.Save()

# Set the AUMID property on the shortcut (must match the AUMID in Program.cs)
Add-Type -Path (Join-Path $notifDir "ShortcutAumid.cs")
[ShortcutAumid]::Set($lnk, "ClaudeCode.Hooks")
Write-Host "Created shortcut: $lnk"

# Add hooks to settings.json (only touches our hook events, preserves everything else)
$claude = Join-Path $env:USERPROFILE ".claude"
$settingsPath = "$claude\settings.json"
$settings = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json } else { [PSCustomObject]@{} }
$exePath = $exe -replace '\\', '/'
$hooks = @{
    UserPromptSubmit = @(@{ matcher = ""; hooks = @(@{ type = "command"; command = "$exePath on-submit"; async = $true }) })
    Notification = @(@{ matcher = ""; hooks = @(@{ type = "command"; command = "$exePath notify notification" }) })
    Stop = @(@{ matcher = ""; hooks = @(@{ type = "command"; command = "$exePath notify stop" }) })
    SessionEnd = @(@{ matcher = ""; hooks = @(@{ type = "command"; command = "$exePath on-end" }) })
}
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{})
}
foreach ($event in $hooks.Keys) {
    $settings.hooks | Add-Member -NotePropertyName $event -NotePropertyValue $hooks[$event] -Force
}
$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
Write-Host "Updated $settingsPath"
