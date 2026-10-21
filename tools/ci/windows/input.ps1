# Real input for measure.ps1 (dot-sourced): the mouse and the keyboard as a user's, so the
# page and the system see what a user's press, drag, double click and keys would make.
#
# Every mouse event goes through SendInput, a move included: `mouse_event` is superseded
# (Microsoft's reference says to use SendInput), and SetCursorPos only places the cursor,
# putting no movement into the input stream.
Add-Type -Name I -Namespace W -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; }
[DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, System.UIntPtr e);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int s);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern System.IntPtr FindWindowW(string cls, string name);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
[StructLayout(LayoutKind.Sequential)] public struct TITLEBARINFOEX {
  public int cbSize; public RECT rcTitleBar;
  [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public int[] rgstate;
  [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public RECT[] rgrect;
}
[DllImport("user32.dll", EntryPoint = "SendMessageW")] public static extern System.IntPtr SendTitleBarInfo(System.IntPtr h, uint msg, System.IntPtr w, ref TITLEBARINFOEX info);
'@

$MOUSE_MOVE = 0x1; $MOUSE_LEFT_DOWN = 0x2; $MOUSE_LEFT_UP = 0x4; $MOUSE_RIGHT_DOWN = 0x8; $MOUSE_RIGHT_UP = 0x10
$MOUSE_ABSOLUTE = 0x8000
$VK_DOWN = 0x28; $VK_RETURN = 0x0D; $VK_ESCAPE = 0x1B

# One mouse event. With MOUSEEVENTF_ABSOLUTE, dx/dy are 0..65535 across the primary
# monitor (MOUSEINPUT's reference).
# (Not `$input`: PowerShell's automatic variable of that name is the function's pipeline
# input, and the structure stored in it never reached SendInput — the cursor landed
# elsewhere, measured.)
function Send([uint32]$flags, [int]$dx = 0, [int]$dy = 0) {
  $mouse = New-Object W.I+MOUSEINPUT
  $mouse.dx = $dx; $mouse.dy = $dy; $mouse.dwFlags = $flags
  $event = New-Object W.I+INPUT
  $event.type = 0
  $event.mi = $mouse
  $sent = [W.I]::SendInput(1, [W.I+INPUT[]]@($event), [System.Runtime.InteropServices.Marshal]::SizeOf([type][W.I+INPUT]))
  if ($sent -ne 1) { throw "SendInput sent $sent events (error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
}
function Point([int]$x, [int]$y) {
  $width = [W.I]::GetSystemMetrics(0); $height = [W.I]::GetSystemMetrics(1)
  Send ($MOUSE_MOVE -bor $MOUSE_ABSOLUTE) ([int][Math]::Round($x * 65535 / ($width - 1))) ([int][Math]::Round($y * 65535 / ($height - 1)))
}
function Mouse([uint32]$flags) { Send $flags }

function WindowRect([System.IntPtr]$h) { $r = New-Object W.I+RECT; [void][W.I]::GetWindowRect($h, [ref]$r); return $r }
function ClientOrigin([System.IntPtr]$h) { $o = New-Object W.I+POINT; [void][W.I]::ClientToScreen($h, [ref]$o); return $o }
function Front([System.IntPtr]$h) { [void][W.I]::SetForegroundWindow($h); Start-Sleep -Milliseconds 300 }
function Click([int]$x, [int]$y) {
  Point $x $y; Start-Sleep -Milliseconds 100
  Mouse $MOUSE_LEFT_DOWN; Start-Sleep -Milliseconds 50; Mouse $MOUSE_LEFT_UP
}
function DoubleClick([int]$x, [int]$y) {
  Point $x $y; Start-Sleep -Milliseconds 100
  Mouse $MOUSE_LEFT_DOWN; Mouse $MOUSE_LEFT_UP; Start-Sleep -Milliseconds 80
  Mouse $MOUSE_LEFT_DOWN; Mouse $MOUSE_LEFT_UP
}
function RightClick([int]$x, [int]$y) {
  Point $x $y; Start-Sleep -Milliseconds 100
  Mouse $MOUSE_RIGHT_DOWN; Start-Sleep -Milliseconds 50; Mouse $MOUSE_RIGHT_UP
}
# Presses at (x, y), moves by (dx, dy) in ten steps, releases.
function Drag([int]$x, [int]$y, [int]$dx, [int]$dy) {
  Point $x $y; Start-Sleep -Milliseconds 150
  Mouse $MOUSE_LEFT_DOWN; Start-Sleep -Milliseconds 250
  for ($i = 1; $i -le 10; $i++) {
    Point ($x + [int]($dx * $i / 10)) ($y + [int]($dy * $i / 10))
    Start-Sleep -Milliseconds 40
  }
  Mouse $MOUSE_LEFT_UP; Start-Sleep -Milliseconds 400
}
function Key([byte]$vk) { [W.I]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); [W.I]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 120 }
# Puts the window's corner at the screen's (SWP_NOSIZE | SWP_NOZORDER): after the drag
# test its right end was off a small screen, and a click there missed the close button.
function Home([System.IntPtr]$h) { [void][W.I]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x5); Start-Sleep -Milliseconds 400 }
function ClientSize([System.IntPtr]$h) { $r = New-Object W.I+RECT; [void][W.I]::GetClientRect($h, [ref]$r); return $r }
# What the window says is at the screen point: WM_NCHITTEST (HTCLIENT 1, HTCAPTION 2,
# HTMINBUTTON 8, HTMAXBUTTON 9, HTCLOSE 20).
function HitTest([System.IntPtr]$h, [int]$x, [int]$y) {
  $point = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
  return [int][W.I]::SendMessageW($h, 0x84, [IntPtr]::Zero, $point)
}
# The system's minimize, maximize and close buttons where the system draws them:
# WM_GETTITLEBARINFOEX fills TITLEBARINFOEX, rgrect[2] minimize, [3] maximize, [5] close,
# in screen coordinates. Not WM_NCHITTEST: under DWM the buttons are DWM's, 46 px wide here,
# while DefWindowProc's hit test answers with the classic, narrower layout — measured, its
# "minimize" middle fell on the drawn maximize button, in Notepad as in Lepton's window.
# Returns @{ minimize = @(x, y); maximize = ...; close = ... }, the middle of each.
function CaptionButtons([System.IntPtr]$h) {
  $info = New-Object W.I+TITLEBARINFOEX
  $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][W.I+TITLEBARINFOEX])
  $info.rgstate = New-Object int[] 6
  $info.rgrect = New-Object W.I+RECT[] 6
  [void][W.I]::SendTitleBarInfo($h, 0x033F, [IntPtr]::Zero, [ref]$info)
  $found = @{}
  foreach ($button in @(@("minimize", 2), @("maximize", 3), @("close", 5))) {
    $r = $info.rgrect[$button[1]]
    $invisible = ($info.rgstate[$button[1]] -band 0x8000) -ne 0
    if (-not $invisible -and $r.Right -gt $r.Left) {
      $found[$button[0]] = @([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
    }
  }
  return $found
}
# Whether a menu window (class #32768) is on screen.
function MenuShown { $m = [W.I]::FindWindowW("#32768", $null); return ($m -ne [IntPtr]::Zero) -and [W.I]::IsWindowVisible($m) }
