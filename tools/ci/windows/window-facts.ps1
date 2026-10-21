param([Parameter(Mandatory)][string]$Process, [string]$Shot = "")
# What the system says about the app's window: placement against the work area, the
# client area, the class and exe icons, whether DWM draws the title bar dark, and the
# title bar's own colour on screen. DWMWA_CAPTION_COLOR is not read back: it is
# documented for DwmSetWindowAttribute only, and reading it fails with E_INVALIDARG on
# Windows 10 and on Server 2025 alike (measured). With -Shot, a screenshot of the window.
Add-Type -Name F -Namespace W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr GetClassLongPtrW(System.IntPtr h, int index);
[DllImport("user32.dll")] public static extern System.IntPtr MonitorFromWindow(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetMonitorInfoW(System.IntPtr m, ref MONITORINFO i);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(System.IntPtr h, uint a, out int v, int size);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(System.IntPtr h, uint a, out RECT v, int size);
[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern uint ExtractIconExW(string file, int index, System.IntPtr[] large, System.IntPtr[] small, uint count);
public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
'@
$p = Get-Process $Process -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { throw "no window for process $Process" }
$h = $p.MainWindowHandle
$r = New-Object W.F+RECT; [void][W.F]::GetWindowRect($h, [ref]$r)
$vis = New-Object W.F+RECT; [void][W.F]::DwmGetWindowAttribute($h, 9, [ref]$vis, 16)
$m = New-Object W.F+MONITORINFO; $m.cbSize = 40
[void][W.F]::GetMonitorInfoW([W.F]::MonitorFromWindow($h, 1), [ref]$m)
$c = New-Object W.F+RECT; [void][W.F]::GetClientRect($h, [ref]$c)
$origin = New-Object W.F+POINT; [void][W.F]::ClientToScreen($h, [ref]$origin)
$work = $m.rcWork
"title: $($p.MainWindowTitle); foreground: $([W.F]::GetForegroundWindow() -eq $h)"
"monitor $($m.rcMonitor.Right - $m.rcMonitor.Left)x$($m.rcMonitor.Bottom - $m.rcMonitor.Top), work $($work.Left),$($work.Top) $($work.Right - $work.Left)x$($work.Bottom - $work.Top), dpi $([W.F]::GetDpiForWindow($h))"
"window $($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top); visible frame $($vis.Left),$($vis.Top) $($vis.Right - $vis.Left)x$($vis.Bottom - $vis.Top)"
"gaps to the work area (visible frame): left $($vis.Left - $work.Left) right $($work.Right - $vis.Right) top $($vis.Top - $work.Top) bottom $($work.Bottom - $vis.Bottom)"
"client $($c.Right)x$($c.Bottom); client top - window top = $($origin.Y - $r.Top)"
"class icon $([W.F]::GetClassLongPtrW($h, -14) -ne 0), small icon $([W.F]::GetClassLongPtrW($h, -34) -ne 0), exe icons $([W.F]::ExtractIconExW($p.Path, -1, $null, $null, 0))"
$dark = 0; $hr = [W.F]::DwmGetWindowAttribute($h, 20, [ref]$dark, 4)
"immersive dark mode: $dark (hr 0x$('{0:X8}' -f $hr))"
if ($Shot) {
  Add-Type -AssemblyName System.Drawing
  $w = $vis.Right - $vis.Left; $hgt = $vis.Bottom - $vis.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $hgt
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($vis.Left, $vis.Top, 0, 0, $bmp.Size)
  # The title bar's colour where no text or button is: 60% across, 8 px down.
  $px = $bmp.GetPixel([int]($w * 0.6), 8)
  "title bar pixel: rgb($($px.R), $($px.G), $($px.B))"
  $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
