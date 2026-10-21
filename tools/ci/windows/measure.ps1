param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Out, [switch]$Frameless)
# Opens the app and measures it from outside, with real input (input.ps1); the page
# (ci-page.ts) writes what it saw into the window's title. Every line also goes to
# $Out\report.txt; a mismatch is a failure (exit 1).
# - The title bar follows the page: a second start with `leptonci://theme/<name>` hands
#   the link to the running page (single instance, `app.opened`), which sets its
#   theme-color. DWM's dark flag everywhere; on build 22000+ (Windows 11, Server 2025)
#   the colour DWM draws, read from the screen.
# - The native menu: a right click, then Down Down Enter (9) and Esc (none).
# - The page's own bar: a double click maximizes and restores, a press moves the window,
#   a press on the content does not.
# - -Frameless (`window.decorations: false`): no system title bar, the client area starts
#   at the window's top, and the left edge still resizes.
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Out | Out-Null
$report = Join-Path $Out "report.txt"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here "input.ps1")
$name = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
$failures = New-Object System.Collections.Generic.List[string]
function Say([string]$line) { Write-Host $line; Add-Content -Path $report -Value $line -Encoding utf8 }
function Fail([string]$label, [string]$line) { Say "FAIL $label`: $line"; $failures.Add($label) }
function Facts([string]$label) {
  Say "### $label"
  $lines = & (Join-Path $here "window-facts.ps1") -Process $name -Shot (Join-Path $Out "$label.png")
  foreach ($line in $lines) { Say $line }
  return $lines
}
function Expect([string[]]$lines, [string]$prefix, [string]$wanted, [string]$label) {
  $line = $lines | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
  if ($line -and $line.Contains($wanted)) { Say "ok   $label`: $wanted" } else { Fail $label "wanted '$wanted', got '$line'" }
}
function Window { Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 }
function Handle { return (Window).MainWindowHandle }
function Title { return (Window).MainWindowTitle }
function Until([scriptblock]$condition, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while (-not (& $condition)) {
    if ((Get-Date) -gt $deadline) { return $false }
    Start-Sleep -Milliseconds 200
  }
  return $true
}
# Starts the app again with `link`; it must hand it over and end, leaving one window.
function Hand([string]$link) {
  $second = Start-Process -FilePath $Exe -ArgumentList $link -PassThru
  if ($second.WaitForExit(15000)) { Say "second start ($link): exit $($second.ExitCode)" }
  else { Fail "single instance" "second start ($link) still running after 15 s"; $second.Kill() }
  $count = @(Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }).Count
  if ($count -ne 1) { Fail "single instance" "$count windows after the second start" }
}
function Theme([string]$theme) {
  Hand "leptonci://theme/$theme"
  if (-not (Until { (Title) -eq "ci $theme" } 15)) { Fail "theme $theme" "the page never named it in its title" }
  Start-Sleep -Milliseconds 700
  return Facts "theme-$theme"
}
# The page's bar, 16 px down and 300 px in from the client area's corner.
function BarPoint { $o = ClientOrigin (Handle); return @(($o.X + 300), ($o.Y + 16)) }
function ContentPoint { $o = ClientOrigin (Handle); return @(($o.X + 500), ($o.Y + 300)) }

function Menu {
  $h = Handle; Front $h
  $p = ContentPoint
  RightClick $p[0] $p[1]
  if (Until { MenuShown } 5) { Say "ok   a right click shows the system's menu" } else { Fail "menu" "no menu window after a right click"; return }
  Key $VK_DOWN; Key $VK_DOWN; Key $VK_RETURN
  if (Until { (Title) -eq "ci menu 9" } 5) { Say "ok   Down Down Enter chose 9 (past the separator)" } else { Fail "menu choice" "title '$(Title)'" }
  RightClick $p[0] $p[1]
  if (-not (Until { MenuShown } 5)) { Fail "menu" "no menu window the second time"; return }
  Key $VK_ESCAPE
  if (Until { (Title) -eq "ci menu none" } 5) { Say "ok   Esc chose nothing" } else { Fail "menu dismissed" "title '$(Title)'" }
  if (Until { -not (MenuShown) } 3) { Say "ok   the menu closed" } else { Fail "menu" "still on screen after Esc" }
}

function Bar {
  $h = Handle; Front $h
  $p = BarPoint
  DoubleClick $p[0] $p[1]
  if (Until { [W.I]::IsZoomed($h) } 5) { Say "ok   a double click on the page's bar maximized" } else { Fail "bar maximize" "not maximized" }
  Start-Sleep -Milliseconds 500
  $p = BarPoint
  DoubleClick $p[0] $p[1]
  if (Until { -not [W.I]::IsZoomed($h) } 5) { Say "ok   a second double click restored" } else { Fail "bar restore" "still maximized" }
  Start-Sleep -Milliseconds 500
  $before = WindowRect $h; $p = BarPoint
  Drag $p[0] $p[1] 100 100
  $after = WindowRect $h
  $moved = "$($after.Left - $before.Left),$($after.Top - $before.Top)"
  if ($moved -eq "100,100") { Say "ok   a press on the page's bar moved the window 100,100" } else { Fail "bar drag" "moved $moved" }
  $before = WindowRect $h; $p = ContentPoint
  Drag $p[0] $p[1] 100 100
  $after = WindowRect $h
  $moved = "$($after.Left - $before.Left),$($after.Top - $before.Top)"
  if ($moved -eq "0,0") { Say "ok   a press on the content did not move it" } else { Fail "content drag" "moved $moved" }
}

function LeftEdge {
  $h = Handle; Front $h
  $r = WindowRect $h; $width = $r.Right - $r.Left
  # The resize border lies just outside the visible frame, inside the window rectangle.
  Drag ($r.Left + 4) ([int](($r.Top + $r.Bottom) / 2)) 80 0
  $r = WindowRect $h
  $now = $r.Right - $r.Left
  if ($now -eq $width - 80) { Say "ok   the left edge resized the window: $width -> $now" } else { Fail "left edge" "width $width -> $now" }
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Say "## $($os.Caption) $($os.Version) (build $build)$(if ($Frameless) { ', window.decorations: false' })"
$app = Start-Process -FilePath $Exe -PassThru
if (-not (Until { Window } 60)) { Say "FAIL no window after 60 s"; exit 1 }
Start-Sleep -Seconds 3
$first = Facts "opened"

if ($Frameless) {
  Expect $first "client " "client top - window top = 0" "no system title bar: the page starts at the window's top"
} else {
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
  Menu
}
Bar
if ($Frameless) { LeftEdge }
[void](Facts "after-input")

[void]$app.CloseMainWindow()
if ($app.WaitForExit(15000)) { Say "closed: exit $($app.ExitCode)" } else { Fail "close" "still running 15 s after WM_CLOSE"; $app.Kill() }
if ($failures.Count) { Say "## failed: $(($failures | Select-Object -Unique) -join ', ')"; exit 1 }
Say "## all checks passed"
