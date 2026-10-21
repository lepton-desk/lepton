# Real input for measure.ps1 (dot-sourced): the mouse and the keyboard as a user's, so the
# page and the system see what a user's press, drag, double click and keys would make.
Add-Type -Name I -Namespace W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, System.UIntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, System.UIntPtr e);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsZoomed(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int s);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern System.IntPtr FindWindowW(string cls, string name);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
'@

$MOUSE_LEFT_DOWN = 0x2; $MOUSE_LEFT_UP = 0x4; $MOUSE_RIGHT_DOWN = 0x8; $MOUSE_RIGHT_UP = 0x10
$VK_DOWN = 0x28; $VK_RETURN = 0x0D; $VK_ESCAPE = 0x1B

function WindowRect([System.IntPtr]$h) { $r = New-Object W.I+RECT; [void][W.I]::GetWindowRect($h, [ref]$r); return $r }
function ClientOrigin([System.IntPtr]$h) { $o = New-Object W.I+POINT; [void][W.I]::ClientToScreen($h, [ref]$o); return $o }
function Front([System.IntPtr]$h) { [void][W.I]::SetForegroundWindow($h); Start-Sleep -Milliseconds 300 }
function Mouse([uint32]$flags) { [W.I]::mouse_event($flags, 0, 0, 0, [UIntPtr]::Zero) }
function Click([int]$x, [int]$y) {
  [void][W.I]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 100
  Mouse $MOUSE_LEFT_DOWN; Mouse $MOUSE_LEFT_UP
}
function DoubleClick([int]$x, [int]$y) { Click $x $y; Start-Sleep -Milliseconds 80; Click $x $y }
function RightClick([int]$x, [int]$y) {
  [void][W.I]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 100
  Mouse $MOUSE_RIGHT_DOWN; Mouse $MOUSE_RIGHT_UP
}
# Presses at (x, y), moves by (dx, dy) in ten steps, releases.
function Drag([int]$x, [int]$y, [int]$dx, [int]$dy) {
  [void][W.I]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 150
  Mouse $MOUSE_LEFT_DOWN; Start-Sleep -Milliseconds 250
  for ($i = 1; $i -le 10; $i++) {
    [void][W.I]::SetCursorPos($x + [int]($dx * $i / 10), $y + [int]($dy * $i / 10))
    Start-Sleep -Milliseconds 40
  }
  Mouse $MOUSE_LEFT_UP; Start-Sleep -Milliseconds 400
}
function Key([byte]$vk) { [W.I]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); [W.I]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 120 }
# Whether a menu window (class #32768) is on screen.
function MenuShown { $m = [W.I]::FindWindowW("#32768", $null); return ($m -ne [IntPtr]::Zero) -and [W.I]::IsWindowVisible($m) }
