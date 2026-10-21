param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Out, [int]$Port = 9333)
# Opens the app, measures its window as the page changes its theme, checks the single
# instance and closes it. Every line also goes to $Out\report.txt; a mismatch with what
# the core asked DWM for is a failure (exit 1).
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
function Page([string]$expression) {
  $lines = & node (Join-Path $here "cdp.mjs") $Port $expression
  foreach ($line in $lines) { Say "page: $line" }
}

$os = Get-CimInstance Win32_OperatingSystem
Say "## $($os.Caption) $($os.Version) (build $($os.BuildNumber))"
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
$app = Start-Process -FilePath $Exe -PassThru
$deadline = (Get-Date).AddSeconds(60)
while (-not (Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })) {
  if ((Get-Date) -gt $deadline) { Say "FAIL no window after 60 s"; exit 1 }
  Start-Sleep -Milliseconds 500
}
Page "document.title"
Start-Sleep -Seconds 2
$first = Facts "opened"
# The template's CSS says color-scheme: dark and names no theme-color.
Expect $first "immersive dark mode:" "dark mode: 1" "dark page, dark title bar"

$meta = "(m => { m.content = 'COLOUR'; return getComputedStyle(document.documentElement).colorScheme + ' ' + m.content })(document.querySelector('meta[name=theme-color]') ?? document.head.appendChild(Object.assign(document.createElement('meta'), { name: 'theme-color' })))"
Page $meta.Replace("COLOUR", "#ffd700")
Start-Sleep -Seconds 1
$gold = Facts "theme-gold"
Expect $gold "immersive dark mode:" "dark mode: 0" "light colour, light title bar"
Expect $gold "caption colour:" "0x0000D7FF (hr 0x00000000)" "caption colour #ffd700"
Expect $gold "text colour:" "0x00000000 (hr 0x00000000)" "black text on #ffd700"

Page $meta.Replace("COLOUR", "rgb(27 29 28)")
Start-Sleep -Seconds 1
$dark = Facts "theme-dark"
Expect $dark "immersive dark mode:" "dark mode: 1" "dark colour, dark title bar"
Expect $dark "caption colour:" "0x001C1D1B (hr 0x00000000)" "caption colour rgb(27 29 28)"
Expect $dark "text colour:" "0x00FFFFFF (hr 0x00000000)" "white text on rgb(27 29 28)"

# A second start hands its arguments to the first and ends.
$second = Start-Process -FilePath $Exe -ArgumentList "leptonci://second" -PassThru
if ($second.WaitForExit(15000)) { Say "second start: exit $($second.ExitCode)" } else { Say "FAIL second start still running after 15 s"; $failures.Add("single instance"); $second.Kill() }
$count = @(Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }).Count
if ($count -eq 1) { Say "ok   one window after the second start" } else { Say "FAIL $count windows after the second start"; $failures.Add("single instance") }
Page "new Promise(r => setTimeout(() => r(document.body.innerText.slice(0, 200)), 500))"

[void]$app.CloseMainWindow()
if ($app.WaitForExit(15000)) { Say "closed: exit $($app.ExitCode)" } else { Say "FAIL still running 15 s after WM_CLOSE"; $failures.Add("close"); $app.Kill() }
if ($failures.Count) { Say "## failed: $($failures -join ', ')"; exit 1 }
Say "## all checks passed"
