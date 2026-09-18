# Capture the whole virtual screen to %TEMP%\wa-desktop.png.
#
# Why this exists: the accessibility-based window tools enumerate what they can see, and they did
# not see the control view window - so a window that was plainly on screen was reported as "not
# created", twice, and the conclusion drawn from that was wrong. The screen is the ground truth, and
# it costs one script to ask it.
#
# Written as a file rather than a one-liner on purpose: a long `powershell -Command` string loses
# its quoting and its backslashes, which turns a working capture into a parse error that looks like
# a broken filesystem.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/screenshot.ps1
param([string]$Out = (Join-Path $env:TEMP "wa-desktop.png"))
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
Write-Host "wrote $Out ($($bounds.Width)x$($bounds.Height))"
