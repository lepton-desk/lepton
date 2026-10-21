param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Out)
# Opens the app, then starts it again with `leptonci://theme/<name>`: the single instance
# hands the link to the running page (`app.opened`, ci-theme.ts), which sets its
# theme-color and its title. Once the window's title says so, the title bar is measured:
# DWM's dark flag everywhere, and on Windows 11 / Server 2025 (build 22000+) the colour
# DWM draws, read from the screen. Every line also goes to $Out\report.txt; a mismatch
# is a failure (exit 1).
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Out | Out-Null
$report = Join-Path $Out "report.txt"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$name = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
$failures = New-Object System.Collections.Generic.List[string]
function Say([string]$line) { $line; Add-Content -Path $report -Value $line -Encoding utf8 }
function Facts([string]$label) {
  Say "### $label"
  $lines = & (Join-Path $here "window-facts.ps1") -Process $name -Shot (Join-Path $Out "$label.png")
  foreach ($line in $lines) { Say $line }
  return $lines
}
function Expect([string[]]$lines, [string]$prefix, [string]$wanted, [string]$label) {
  $line = $lines | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
  if ($line -and $line.Contains($wanted)) { Say "ok   $label`: $wanted" }
  else { Say "FAIL $label`: wanted '$wanted', got '$line'"; $failures.Add($label) }
}
function Window { Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } }
# Starts the app again with `link`; it must hand it over and end, leaving one window.
function Hand([string]$link) {
  $second = Start-Process -FilePath $Exe -ArgumentList $link -PassThru
  if ($second.WaitForExit(15000)) { Say "second start ($link): exit $($second.ExitCode)" }
  else { Say "FAIL second start ($link) still running after 15 s"; $failures.Add("single instance"); $second.Kill() }
  $count = @(Window).Count
  if ($count -ne 1) { Say "FAIL $count windows after the second start"; $failures.Add("single instance") }
}
function Theme([string]$theme) {
  Hand "leptonci://theme/$theme"
  $deadline = (Get-Date).AddSeconds(15)
  while ((Window | Select-Object -First 1).MainWindowTitle -ne "ci $theme") {
    if ((Get-Date) -gt $deadline) { Say "FAIL the page never named theme $theme in its title"; $failures.Add("theme $theme"); break }
    Start-Sleep -Milliseconds 250
  }
  Start-Sleep -Milliseconds 700
  return Facts "theme-$theme"
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Say "## $($os.Caption) $($os.Version) (build $build)"
$app = Start-Process -FilePath $Exe -PassThru
$deadline = (Get-Date).AddSeconds(60)
while (-not (Window)) {
  if ((Get-Date) -gt $deadline) { Say "FAIL no window after 60 s"; exit 1 }
  Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 3
$first = Facts "opened"
# The template's CSS says color-scheme: dark and names no theme-color.
Expect $first "immersive dark mode:" "dark mode: 1" "dark page, dark title bar"
$colours = $build -ge 22000

$gold = Theme "gold"
Expect $gold "immersive dark mode:" "dark mode: 0" "#ffd700: light title bar"
if ($colours) { Expect $gold "title bar pixel:" "rgb(255, 215, 0)" "#ffd700: the title bar is #ffd700" }

$dark = Theme "dark"
Expect $dark "immersive dark mode:" "dark mode: 1" "rgb(27 29 28): dark title bar"
if ($colours) { Expect $dark "title bar pixel:" "rgb(27, 29, 28)" "rgb(27 29 28): the title bar is that colour" }
if (-not $colours) { Say "build $build < 22000: Windows 10 has no caption colour; only dark/light is checked" }

[void]$app.CloseMainWindow()
if ($app.WaitForExit(15000)) { Say "closed: exit $($app.ExitCode)" } else { Say "FAIL still running 15 s after WM_CLOSE"; $failures.Add("close"); $app.Kill() }
if ($failures.Count) { Say "## failed: $(($failures | Select-Object -Unique) -join ', ')"; exit 1 }
Say "## all checks passed"
