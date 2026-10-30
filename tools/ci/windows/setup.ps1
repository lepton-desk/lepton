param([Parameter(Mandatory)][string]$Setup, [Parameter(Mandatory)][string]$App, [Parameter(Mandatory)][string]$Out)
# setup.exe from outside: its window (a screenshot, then closed), `/S` install and what it
# wrote — the folder, Settings → Apps' entry, the Start menu shortcut and its
# AppUserModelID, the link scheme, the notification name — the installed program opened
# and measured, the same version installed again over it, `uninstall.exe /S`, and what is
# left. Every check runs; the script fails at the end if any did.
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Out | Out-Null
$report = Join-Path $Out "setup.txt"
$failures = [System.Collections.Generic.List[string]]::new()
function Say([string]$line) { Write-Host $line; Add-Content -Path $report -Value $line -Encoding utf8 }
function Check([bool]$ok, [string]$label, [string]$detail) {
  if ($ok) { Say "ok   $label`: $detail" } else { Say "FAIL $label`: $detail"; $failures.Add($label) }
}

$config = Get-Content (Join-Path $App "lepton.config.json") -Raw | ConvertFrom-Json
$product = $config.productName
$identifier = $config.identifier
$version = $config.version
$dir = Join-Path $env:LOCALAPPDATA "Programs\$product"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$identifier"
$link = Join-Path ([Environment]::GetFolderPath("Programs")) "$product.lnk"
$schemeKey = "HKCU:\Software\Classes\leptonci\shell\open\command"
$aumidKey = "HKCU:\Software\Classes\AppUserModelId\$identifier"
Say "setup.exe: $Setup $((Get-Item $Setup).Length) bytes $((Get-FileHash $Setup).Hash)"

# The window as a user first sees it, then closed as its close button would.
$shown = Start-Process $Setup -PassThru
$handle = [System.IntPtr]::Zero
foreach ($i in 1..50) {
  Start-Sleep -Milliseconds 200
  $shown.Refresh()
  if ($shown.MainWindowHandle -ne [System.IntPtr]::Zero) { $handle = $shown.MainWindowHandle; break }
}
Check ($handle -ne [System.IntPtr]::Zero) "window" "the install window opened"
if ($handle -ne [System.IntPtr]::Zero) {
  Start-Sleep -Milliseconds 500
  & (Join-Path $PSScriptRoot "window-facts.ps1") -Id $shown.Id -Handle $handle -Shot (Join-Path $Out "setup-window.png") | ForEach-Object { Say "  $_" }
  [void]$shown.CloseMainWindow()
  Check ($shown.WaitForExit(5000)) "window closes" "exit $($shown.ExitCode)"
}
Check (-not (Test-Path $dir)) "nothing before Install" "the window wrote no folder"

$install = Start-Process $Setup -ArgumentList "/S" -Wait -PassThru
Check ($install.ExitCode -eq 0) "install /S" "exit $($install.ExitCode)"
$program = Get-ChildItem (Join-Path $dir "bin") -Filter *.exe -ErrorAction SilentlyContinue | Select-Object -First 1
Check ($null -ne $program) "program" "$($program.FullName)"
Check (Test-Path (Join-Path $dir "uninstall.exe")) "uninstall.exe" "beside bin\ and share\"
Check (Test-Path (Join-Path $dir ".lepton-setup")) ".lepton-setup" "what the folder holds"
Check (-not (Test-Path "$dir.setup-new") -and -not (Test-Path "$dir.setup-old")) "no staging left" "$dir.setup-new, .setup-old"

$entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
Check ($null -ne $entry) "Settings → Apps" $uninstallKey
if ($entry) {
  Check ($entry.DisplayName -eq $product) "DisplayName" $entry.DisplayName
  Check ($entry.DisplayVersion -eq $version) "DisplayVersion" $entry.DisplayVersion
  Check ($entry.InstallLocation -eq $dir) "InstallLocation" $entry.InstallLocation
  Check ($entry.UninstallString -eq "`"$dir\uninstall.exe`"") "UninstallString" $entry.UninstallString
  Say "     EstimatedSize $($entry.EstimatedSize) KB, Publisher $($entry.Publisher), DisplayIcon $($entry.DisplayIcon)"
}

Check (Test-Path $link) "shortcut" $link
if (Test-Path $link) {
  $shell = New-Object -ComObject Shell.Application
  $item = $shell.NameSpace((Split-Path $link)).ParseName((Split-Path $link -Leaf))
  $aumid = $item.ExtendedProperty("System.AppUserModel.ID")
  Check ($aumid -eq $identifier) "shortcut AppUserModelID" "$aumid"
  $target = (New-Object -ComObject WScript.Shell).CreateShortcut($link).TargetPath
  Check ($target -eq $program.FullName) "shortcut target" $target
}
$command = (Get-ItemProperty $schemeKey -ErrorAction SilentlyContinue).'(default)'
Check ($command -eq "`"$($program.FullName)`" `"%1`"") "leptonci: scheme" "$command"
$name = (Get-ItemProperty $aumidKey -ErrorAction SilentlyContinue).DisplayName
Check ($name -eq $product) "notification name" "$name"

if ($program) {
  & (Join-Path $PSScriptRoot "measure.ps1") -Exe $program.FullName -Out (Join-Path $Out "installed")
  Check ($LASTEXITCODE -eq 0) "installed program" "measure.ps1 exit $LASTEXITCODE"
}

# The same version again: set aside and replaced whole, as an update is.
$again = Start-Process $Setup -ArgumentList "/S" -Wait -PassThru
Check ($again.ExitCode -eq 0) "install again /S" "exit $($again.ExitCode)"
Check (Test-Path (Join-Path $dir "uninstall.exe")) "after reinstall" "uninstall.exe is there"

# The uninstall window, then closed; then `/S`.
$asking = Start-Process (Join-Path $dir "uninstall.exe") -PassThru
foreach ($i in 1..50) {
  Start-Sleep -Milliseconds 200
  $asking.Refresh()
  if ($asking.MainWindowHandle -ne [System.IntPtr]::Zero) { break }
}
if ($asking.MainWindowHandle -ne [System.IntPtr]::Zero) {
  Start-Sleep -Milliseconds 500
  & (Join-Path $PSScriptRoot "window-facts.ps1") -Id $asking.Id -Handle $asking.MainWindowHandle -Shot (Join-Path $Out "uninstall-window.png") | ForEach-Object { Say "  $_" }
  [void]$asking.CloseMainWindow()
  [void]$asking.WaitForExit(5000)
}
Check ($asking.HasExited -and (Test-Path $dir)) "uninstall window" "opened and closed, nothing removed"

$remove = Start-Process (Join-Path $dir "uninstall.exe") -ArgumentList "/S" -Wait -PassThru
Check ($remove.ExitCode -eq 0) "uninstall /S" "exit $($remove.ExitCode)"
$left = if (Test-Path $dir) { (Get-ChildItem $dir -Recurse -Force | ForEach-Object { $_.FullName }) -join ", " } else { "" }
Check (-not (Test-Path $dir)) "folder removed" "$left"
Check (-not (Test-Path $uninstallKey)) "entry removed" $uninstallKey
Check (-not (Test-Path $link)) "shortcut removed" $link
Check (-not (Test-Path "HKCU:\Software\Classes\leptonci")) "scheme removed" "leptonci"
Check (-not (Test-Path $aumidKey)) "notification name removed" $aumidKey
$moved = Get-ChildItem $env:TEMP -Filter "lepton-uninstall-*.exe" -ErrorAction SilentlyContinue
Say "     uninstall.exe moved to the temporary folder: $(($moved | ForEach-Object { $_.Name }) -join ', ')"
$data = @((Join-Path $env:LOCALAPPDATA $identifier), (Join-Path $env:APPDATA $identifier)) | Where-Object { Test-Path $_ }
Say "     the app's data kept: $($data -join ', ')"

if ($failures.Count) { Say "failed: $($failures -join ', ')"; exit 1 }
Say "all passed"
