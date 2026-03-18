# CC Hooks — Windows Uninstall
#
# Run: pwsh -NoProfile -File uninstall.ps1
# Triggers a UAC prompt for HKLM registry removal.
#
# Removes: watcher processes, protocol handlers (HKCU), AUMID keys
# (HKCU + HKLM), and notification hooks from ~/.claude/settings.json.

Get-Process -Name "notifications" -ErrorAction SilentlyContinue | Stop-Process -Force

foreach ($proto in @("claude-focus", "claude-editor")) {
    $key = "HKCU:\Software\Classes\$proto"
    if (Test-Path $key) { Remove-Item $key -Recurse -Force }
}

$hkcuKey = "HKCU:\Software\Classes\AppUserModelId\ClaudeCode.Hooks"
if (Test-Path $hkcuKey) { Remove-Item $hkcuKey -Force }

$hklmKey = "HKLM:\Software\Classes\AppUserModelId\ClaudeCode.Hooks"
$regCmd = "if (Test-Path '$hklmKey') { Remove-Item '$hklmKey' -Force }"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Invoke-Expression $regCmd
} else {
    try { Start-Process pwsh -Verb RunAs -ArgumentList "-NoProfile -Command $regCmd" -Wait }
    catch { Write-Host "Skipped HKLM removal (admin declined). Remove manually: HKLM\Software\Classes\AppUserModelId\ClaudeCode.Hooks" }
}

# Hook config + temp file cleanup
$exe = Join-Path $PSScriptRoot "notifications\target\release\notifications.exe"
if (Test-Path $exe) {
    & $exe uninstall
} else {
    Write-Host "Uninstalled"
}
