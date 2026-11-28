param(
    [string]$Python = "python",
    [string]$InnoCompiler = "",
    [string]$DistDirectory = "dist",
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"

function Assert-LastExit($step) {
    if ($LASTEXITCODE -ne 0) { throw "$step failed with exit code $LASTEXITCODE" }
}

$env:PYTHONPATH = Join-Path $PSScriptRoot 'src'
& $Python -c 'import platform, struct, sys; assert sys.platform == "win32" and platform.machine() == "AMD64" and struct.calcsize("P") == 8, "A native Windows x64 Python is required"'
Assert-LastExit "x64 check"
if (-not $SkipDependencyInstall) {
    & $Python -m pip install --disable-pip-version-check -r requirements-dev.txt
    Assert-LastExit "pip install"
}

$version = & $Python -c 'from gaocaozuo.version import MARKETING_VERSION; print(MARKETING_VERSION)'
Assert-LastExit "version"
$buildNumber = & $Python -c 'from gaocaozuo.version import WINDOWS_BUILD; print(WINDOWS_BUILD)'
Assert-LastExit "build number"
$stem = "GaoCaoZuo-Windows-$version-build$buildNumber-x64-Setup"
$buildDir = Join-Path $PSScriptRoot "build"
$distDir = [IO.Path]::GetFullPath($DistDirectory, $PSScriptRoot)
$ocrHelper = Join-Path $buildDir 'ocr\GaoCaoZuo-WinOcr.exe'
& "$PSScriptRoot\ocr\build.ps1" -OutputPath $ocrHelper
Assert-LastExit "Windows OCR helper"
& $Python -m pytest -q
Assert-LastExit "pytest"

$icon = Join-Path $buildDir 'GaoCaoZuo.ico'
$iconPng = Join-Path $buildDir 'operation-icon.png'
$runtimeIcon = Join-Path $buildDir 'operation-icon.ico'
& $Python -m gaocaozuo.brand_icons (Join-Path $PSScriptRoot '..\Assets\AppIcon.png') $runtimeIcon --png $iconPng
Assert-LastExit "icon"
Copy-Item -LiteralPath $runtimeIcon -Destination $icon -Force
$versionFile = Join-Path $buildDir 'version-info.txt'
@"
VSVersionInfo(ffi=FixedFileInfo(filevers=($($version.Replace('.', ',')),$buildNumber,0), prodvers=($($version.Replace('.', ',')),$buildNumber,0), mask=63, flags=0, OS=262148, fileType=1, subtype=0, date=(0,0)), kids=[
StringFileInfo([StringTable('080404b0', [StringStruct('CompanyName','GaoSeries'), StringStruct('FileDescription','搞操作'), StringStruct('ProductName','搞操作'), StringStruct('FileVersion','$version.$buildNumber.0'), StringStruct('ProductVersion','$version'), StringStruct('InternalName','GaoCaoZuo')])]), VarFileInfo([VarStruct('Translation',[2052,1200])])])
"@ | Set-Content -LiteralPath $versionFile -Encoding UTF8

$assetDir = Join-Path $PSScriptRoot 'src\gaocaozuo\assets'
$localization = Join-Path $buildDir 'localization.json'
& $Python -m gaocaozuo.localization $localization
Assert-LastExit "Mac-derived localization"
$common = @('--noconfirm', '--clean', '--onefile', '--paths', 'src', '--distpath', $distDir,
            '--add-data', "$assetDir;gaocaozuo_assets", '--add-data', "$ocrHelper;gaocaozuo_assets",
            '--add-data', "$iconPng;gaocaozuo_assets", '--add-data', "$runtimeIcon;gaocaozuo_assets",
            '--add-data', "$localization;gaocaozuo_assets", '--collect-all', 'pillow_heif',
            '--collect-binaries', 'ctranslate2', '--collect-data', 'py3langid', '--icon', $icon, '--version-file', $versionFile)
& $Python -m PyInstaller @common --name GaoCaoZuo-cli --console --workpath build/cli --specpath build/cli launch_cli.py
Assert-LastExit "PyInstaller CLI"
& $Python -m PyInstaller @common --name GaoCaoZuo --windowed --workpath build/gui --specpath build/gui launch.py
Assert-LastExit "PyInstaller window"

if (-not $InnoCompiler) {
    $onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($onPath) { $InnoCompiler = $onPath.Source }
}
if (-not $InnoCompiler) {
    $candidates = @((Join-Path $buildDir 'inno\ISCC.exe'), "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                    "$env:ProgramFiles\Inno Setup 7\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")
    $InnoCompiler = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $InnoCompiler) { throw 'Inno Setup 6.3+ ISCC.exe is required to build the setup package.' }
& $Python collect_notices.py (Join-Path $buildDir 'notices') (Split-Path -Parent $InnoCompiler)
Assert-LastExit "dependency notices"
& $InnoCompiler /Qp "/DAppVersion=$version" "/DBuildNumber=$buildNumber" "/DBinaryDir=$distDir" "/F$stem" "/O$distDir" installer.iss
Assert-LastExit "Inno Setup"
$package = Join-Path $distDir "$stem.exe"
$checksum = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$package.sha256" -Value ("$checksum  $stem.exe") -Encoding ascii
Write-Output ("$checksum  $stem.exe")
$desktopIconName = "GaoCaoZuo-Windows-$version-build$buildNumber.ico"
$desktopIcon = Join-Path $distDir $desktopIconName
Copy-Item -LiteralPath $runtimeIcon -Destination $desktopIcon -Force
$iconChecksum = (Get-FileHash -LiteralPath $desktopIcon -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$desktopIcon.sha256" -Value ("$iconChecksum  $desktopIconName") -Encoding ascii
Write-Output ("$iconChecksum  $desktopIconName")
Get-Item -LiteralPath $package, "$package.sha256", $desktopIcon, "$desktopIcon.sha256" | Select-Object FullName,Length
