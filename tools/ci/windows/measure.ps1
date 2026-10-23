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
# - The three title bar buttons, clicked: minimize, maximize, restore, then close (exit 0)
#   — the system's (where WM_GETTITLEBARINFOEX says they are drawn) or, -Frameless, the
#   page's (`windowControls`).
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
  $h = Handle
  if ($h -eq [System.IntPtr]::Zero) { Fail $label "the app's window is gone"; return @() }
  $lines = & (Join-Path $here "window-facts.ps1") -Id $app.Id -Handle $h -Shot (Join-Path $Out "$label.png")
  foreach ($line in $lines) { Say $line }
  return $lines
}
function Expect([string[]]$lines, [string]$prefix, [string]$wanted, [string]$label) {
  $line = $lines | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
  if ($line -and $line.Contains($wanted)) { Say "ok   $label`: $wanted" } else { Fail $label "wanted '$wanted', got '$line'" }
}
# The window of the process this script started, found by its class (input.ps1).
function Handle { return AppWindow $app.Id }
function Window { $h = Handle; if ($h -eq [System.IntPtr]::Zero) { return $null }; return $h }
function Title { return TitleOf (Handle) }
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
  $count = @(Get-Process $name -ErrorAction SilentlyContinue | Where-Object { (AppWindow $_.Id) -ne [System.IntPtr]::Zero }).Count
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

# Clicks minimize, maximize, maximize again (restore) through `$at`, which answers each
# button's screen point; a minimized window is brought back as the taskbar would.
function Trio([string]$whose, [scriptblock]$at) {
  $h = Handle; Home $h; Front $h
  $p = & $at "minimize"
  if (-not $p) { Fail "$whose minimize" "no minimize button found"; return }
  Click $p[0] $p[1]
  if (Until { [W.I]::IsIconic($h) } 5) { Say "ok   $whose minimize button minimized" } else { Fail "$whose minimize" "not minimized" }
  [void][W.I]::ShowWindow($h, 9); Start-Sleep -Milliseconds 700; Front $h
  $p = & $at "maximize"
  Click $p[0] $p[1]
  if (Until { [W.I]::IsZoomed($h) } 5) { Say "ok   $whose maximize button maximized" } else { Fail "$whose maximize" "not maximized" }
  Start-Sleep -Milliseconds 700
  $p = & $at "maximize"
  Click $p[0] $p[1]
  if (Until { -not [W.I]::IsZoomed($h) } 5) { Say "ok   $whose maximize button, pressed again, restored" } else { Fail "$whose restore" "still maximized" }
  Start-Sleep -Milliseconds 500
}
# The system's buttons: where the system draws them (WM_GETTITLEBARINFOEX, input.ps1).
$system = {
  param([string]$which)
  $found = CaptionButtons (Handle)
  if (-not $found.ContainsKey($which)) { return $null }
  return $found[$which]
}
# The page's buttons (ci-page.ts): 46 CSS px each at the right end of its 32 px bar.
$page = {
  param([string]$which)
  $h = Handle
  $scale = [W.I]::GetDpiForWindow($h) / 96
  $o = ClientOrigin $h; $c = ClientSize $h
  $from = @{ minimize = 115; maximize = 69; close = 23 }
  return @(($o.X + $c.Right - [int]($from[$which] * $scale)), ($o.Y + [int](16 * $scale)))
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
# A copy already running (an earlier step's, the same identifier) would take this start
# as its second instance, and that window would be measured instead (measured: a run
# checked an installed, decorated copy in the frameless step).
$running = @(Get-Process $name -ErrorAction SilentlyContinue)
if ($running.Count) {
  Say "note: $($running.Count) $name process(es) already running; stopped first"
  $running | Stop-Process -Force
  [void](Until { -not (Get-Process $name -ErrorAction SilentlyContinue) } 10)
}
$app = Start-Process -FilePath $Exe -PassThru
# Whatever stops this script, the app does not outlive it.
trap { if ($app -and -not $app.HasExited) { $app.Kill() }; break }
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
if ($Frameless) {
  LeftEdge
  Trio "the page's" $page
} else {
  Home (Handle)
  $found = CaptionButtons (Handle)
  Say "system caption buttons (WM_GETTITLEBARINFOEX, middles): minimize $($found.minimize -join ','), maximize $($found.maximize -join ','), close $($found.close -join ',')"
  Trio "the system's" $system
}
[void](Facts "after-input")

# The last button: close, the system's or the page's, with a real click.
$closer = if ($Frameless) { $page } else { $system }
$whose = if ($Frameless) { "the page's" } else { "the system's" }
$p = & $closer "close"
if ($p) {
  Front (Handle)
  Click $p[0] $p[1]
  if ($app.WaitForExit(15000)) {
    if ($app.ExitCode -eq 0) { Say "ok   $whose close button closed the app: exit 0" } else { Fail "$whose close" "exit $($app.ExitCode)" }
  } else { Fail "$whose close" "still running 15 s after the click" }
} else { Fail "$whose close" "no close button found" }
if (-not $app.HasExited) {
  [void]$app.CloseMainWindow()
  if (-not $app.WaitForExit(15000)) { $app.Kill() }
}
if ($failures.Count) { Say "## failed: $(($failures | Select-Object -Unique) -join ', ')"; exit 1 }
Say "## all checks passed"
