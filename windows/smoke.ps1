param([string]$Installer = "", [string]$PreviousInstaller = "", [string]$ExpectedVersion = "1.16+6", [switch]$LocalizationOnly)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
$marketingVersion, $expectedBuild = $ExpectedVersion -split '\+', 2
if (-not $Installer) {
    $Installer = Join-Path $PSScriptRoot "dist\GaoCaoZuo-Windows-$marketingVersion-build$expectedBuild-x64-Setup.exe"
}
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$sha = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash
if (((Get-Content -LiteralPath "$Installer.sha256") -split '\s+')[0] -ne $sha) { throw 'Installer checksum differs.' }
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('GaoCaoZuo-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$scratch = (Resolve-Path -LiteralPath $scratch).Path
$installDir = Join-Path $scratch 'installed'
$dataDir = Join-Path $scratch 'isolated data'
$smokeToken = [guid]::NewGuid().ToString('N')
$setupLog = Join-Path $scratch 'setup.txt'
$output = Join-Path $scratch 'created'
$server = $null
$stdout = Join-Path $scratch 'stdout.txt'
$stderr = Join-Path $scratch 'stderr.txt'
$previousEnvironment = @{}
$uninstaller = $null

function Remove-IsolatedInstall {
    if ($uninstaller -and (Test-Path -LiteralPath $uninstaller)) {
        $removed = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru -WindowStyle Hidden
        if ($removed.ExitCode -ne 0) { throw "Uninstaller exited $($removed.ExitCode)." }
    }
}

function Assert-X64([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = [BitConverter]::ToInt32($bytes, 60)
    if ([BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0x8664) { throw "Installed PE is not x64: $Path" }
}

try {
    $clipboard = Join-Path $dataDir 'Clipboard'
    New-Item -ItemType Directory -Path $clipboard, $output | Out-Null
    $old = Join-Path $dataDir 'settings.json'
    [IO.File]::WriteAllText($old, '{"schema":1,"appearance":"dark","clipboardEnabled":false,"favorites":["new.text"],"unknownLegacyKey":{"mark":"keep"}}')
    $legacySettingsHash = (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash
    $history = Join-Path $clipboard 'history.json'
    [IO.File]::WriteAllText($history, '{"schema":1,"items":[{"text":"isolated fixture","pinned":true}]}')
    $historyHash = (Get-FileHash -LiteralPath $history -Algorithm SHA256).Hash
    if ($PreviousInstaller) {
        $PreviousInstaller = (Resolve-Path -LiteralPath $PreviousInstaller).Path
        $previousVersion = (Get-Item -LiteralPath $PreviousInstaller).VersionInfo.FileVersion.Trim()
        $oldArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ISOLATEDSMOKE=1 /DIR="' + $installDir + '"'
        $prior = Start-Process -FilePath $PreviousInstaller -ArgumentList $oldArguments -Wait -PassThru -WindowStyle Hidden
        if ($prior.ExitCode -ne 0) { throw "Previous installer exited $($prior.ExitCode)." }
        if ((Get-Item -LiteralPath (Join-Path $installDir 'GaoCaoZuo.exe')).VersionInfo.FileVersion -ne $previousVersion) { throw 'Previous installed build mismatch.' }
    }
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ISOLATEDSMOKE=2 /SMOKETOKEN=' + $smokeToken + ' /DIR="' + $installDir + '" /LOG="' + $setupLog + '"'
    $setup = Start-Process -FilePath $Installer -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($setup.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $setupLog) { Get-Content -LiteralPath $setupLog -Tail 16 | Write-Output }
        throw "Installer exited $($setup.ExitCode)."
    }
    if ((Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ne $legacySettingsHash -or (Get-FileHash -LiteralPath $history -Algorithm SHA256).Hash -ne $historyHash) {
        throw 'The installer changed isolated legacy data.'
    }
    $cli = Join-Path $installDir 'GaoCaoZuo-cli.exe'
    $gui = Join-Path $installDir 'GaoCaoZuo.exe'
    $uninstaller = (Get-ChildItem -LiteralPath $installDir -Filter 'unins*.exe' -File | Select-Object -First 1).FullName
    if (!$uninstaller) { throw 'Controlled uninstall was not installed.' }
    Assert-X64 $cli
    Assert-X64 $gui
    $exeVersion = (Get-Item -LiteralPath $gui).VersionInfo
    if ($exeVersion.ProductVersion -ne $marketingVersion -or $exeVersion.FileVersion -ne "$marketingVersion.$expectedBuild.0") { throw 'Installed version mismatch.' }
    if (!(Test-Path -LiteralPath (Join-Path $installDir 'Licenses\Third-Party.txt'))) { throw 'Dependency notices are missing.' }

    foreach ($key in @('PATH','PYTHONPATH','PYTHONHOME','TCL_LIBRARY','TK_LIBRARY','CONDA_PREFIX','PYTHONUTF8')) {
        $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $env:PYTHONUTF8 = '1'
    $capabilities = & $cli --capabilities | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or !($capabilities.actions | Where-Object action -eq 'ocr.files')) { throw 'Installed OCR provider discovery failed.' }

    $arguments = '--no-browser --data-dir "' + $dataDir + '" --port 0'
    $server = Start-Process -FilePath $cli -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $deadline = (Get-Date).AddSeconds(40)
    $base = $null
    do {
        if ($server.HasExited) { throw 'Installed CLI exited before opening its loopback listener.' }
        if (Test-Path -LiteralPath $stdout) {
            $base = Select-String -LiteralPath $stdout -Pattern '^http://127\.0\.0\.1:\d+/$' | Select-Object -First 1 -ExpandProperty Line
        }
        if (-not $base) { Start-Sleep -Milliseconds 250 }
    } while (-not $base -and (Get-Date) -lt $deadline)
    if (-not $base) { throw 'Installed CLI did not open loopback listener.' }
    $page = Invoke-WebRequest -Uri $base -UseBasicParsing -NoProxy -TimeoutSec 5
    $token = [regex]::Match($page.Content, 'name="gao-token" content="([^"]+)"').Groups[1].Value
    if (-not $token) { throw 'Installed workbench did not deliver session token.' }
    $headers = @{ 'X-Gao-Token' = $token }

    function Post([string]$Route, $Payload) {
        Invoke-RestMethod -Method POST -Uri ($base + $Route) -Headers $headers -ContentType 'application/json; charset=utf-8' `
            -Body ($Payload | ConvertTo-Json -Depth 12 -Compress) -TimeoutSec 30 -NoProxy
    }

    $state = Invoke-RestMethod -Uri ($base + 'api/state') -Headers $headers -TimeoutSec 10 -NoProxy
    if ($state.version -ne $ExpectedVersion -or $state.status -ne 'ready' -or $state.clipboardReads -ne 0 -or $state.settings.appearance -ne 'dark') { throw 'Legacy startup or disabled clipboard regression.' }
    if ($LocalizationOnly) {
        $sourceMessage = '按应用设置的规则可限定到指定的 Windows 程序。'
        $archiveMessage = '请选择与原包同格式的本机目标文件。'
        $distinct = @{}
        foreach ($language in @('zh-Hant','en','ja','de','fr','es','it','ko','pt')) {
            $strings = (Invoke-RestMethod -Uri ($base + 'api/localization?lang=' + $language) -Headers $headers -TimeoutSec 10 -NoProxy).strings
            if (!$strings.$sourceMessage -or !$strings.$archiveMessage -or $strings.$sourceMessage -eq $sourceMessage) { throw "Missing packaged Windows prompts for $language." }
            $distinct[$strings.$sourceMessage] = $true
        }
        if ($distinct.Count -ne 9) { throw 'A packaged Windows prompt is falling back across multiple locales.' }
        $baseStrings = (Invoke-RestMethod -Uri ($base + 'api/localization?lang=zh-Hans') -Headers $headers -TimeoutSec 10 -NoProxy).strings
        if ($null -eq $baseStrings -or @($baseStrings.PSObject.Properties).Count -ne 0) { throw 'The Chinese UI must retain the authored prompt.' }
        Post 'api/shutdown' @{} | Out-Null
        if (!$server.WaitForExit(25000) -or $server.ExitCode -ne 0) { throw 'Installed CLI failed to shut down cleanly.' }
        Remove-IsolatedInstall
        $uninstaller = $null
        if ((Test-Path -LiteralPath $gui) -or (Test-Path -LiteralPath $cli) -or !(Test-Path -LiteralPath $old) -or !(Test-Path -LiteralPath $history)) { throw 'Uninstall did not remove binaries and retain isolated user data.' }
        Write-Output 'OK x64 installer, previous build upgrade, legacy data, nine translated dictionaries and Chinese default, and uninstall retaining data.'
        return
    }
    Post 'api/settings' @{appearance='light'} | Out-Null
    if ((Get-Content -LiteralPath $old -Raw | ConvertFrom-Json).unknownLegacyKey.mark -ne 'keep') { throw 'Unknown settings field changed.' }
    if ((Get-FileHash -LiteralPath $history -Algorithm SHA256).Hash -ne $historyHash) { throw 'Disabled clipboard history changed.' }
    $file = (Post 'api/action' @{id='new.text';payload=@{directory=$output}}).result.path
    [IO.File]::WriteAllText($file, 'GaoCaoZuo isolated install fixture')
    $archive = (Post 'api/action' @{id='archive.custom';payload=@{paths=@($file);format='7z';password='isolated test'}}).result.path
    $listed = (Post 'api/action' @{id='archive.list';payload=@{path=$archive;password='isolated test'}}).result.members
    if ($listed.Count -ne 1) { throw 'Installed 7Z list failed.' }
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $addition = Join-Path $output 'added.txt'
    [IO.File]::WriteAllText($addition, 'edit fixture')
    $preview = (Post 'api/archive/edit/preview' @{path=$archive;password='isolated test'}).result
    $copy = Join-Path $output 'edited.7z'
    $edited = (Post 'api/archive/edit/save' @{previewID=$preview.previewID;password='isolated test';mode='copy';destination=$copy;confirm=$true;add=@($addition);remove=@($listed[0].name)}).result
    if (!$preview.encrypted -or $edited.members[0].name -ne 'added.txt' -or !$edited.members[0].encrypted -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $archiveHash) { throw 'Encrypted archive edit or original preservation failed.' }
    $extracted = (Post 'api/action' @{id='archive.extract';payload=@{paths=@($archive);password='isolated test'}}).result.items[0].destination
    if ((Get-Content -LiteralPath (Join-Path $extracted ([IO.Path]::GetFileName($file))) -Raw) -ne 'GaoCaoZuo isolated install fixture') { throw 'Installed 7Z extraction differed.' }
    $languages = (Post 'api/screenshot/ocr/languages' @{}).result
    if ($null -eq $languages) { throw 'Installed WinRT OCR helper did not run.' }
    $ocrCheck = 'helper only (no Windows OCR language installed)'
    if (@($languages.languages).Count -gt 0 -and $languages.languages[0]) {
        Add-Type -AssemblyName System.Drawing.Common
        $requestID = [guid]::NewGuid().ToString()
        $package = Join-Path $scratch "$requestID.gaoaction"
        $payloadDir = Join-Path $package 'payload'
        New-Item -ItemType Directory -Path $payloadDir | Out-Null
        $png = Join-Path $payloadDir 'fixture.png'
        $bitmap = [Drawing.Bitmap]::new(1000, 260)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $font = [Drawing.Font]::new('Arial', 75)
        try {
            $graphics.Clear([Drawing.Color]::White)
            $graphics.DrawString('12345 67890', $font, [Drawing.Brushes]::Black, 60, 75)
            $bitmap.Save($png, [Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $font.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
        $now = [DateTime]::UtcNow
        $nonce = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $sha = (Get-FileHash -LiteralPath $png -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = @{
            schemaVersion=1; kind='request'; requestID=$requestID; nonce=$nonce
            sourceBundleID='com.gaoseries.GaoWenJian'; targetBundleID='com.gaoseries.GaoCaoZuo'; action='ocr.files'
            createdAt=$now.ToString('yyyy-MM-ddTHH:mm:ssZ'); expiresAt=$now.AddSeconds(110).ToString('yyyy-MM-ddTHH:mm:ssZ')
            references=@(); parameters=@{languages=@($languages.languages[0]); outputs=@('text','searchablePDF')}
            items=@(@{id='test-image';relativePath='fixture.png';uti='public.png';byteCount=(Get-Item -LiteralPath $png).Length;sha256=$sha})
        } | ConvertTo-Json -Depth 8
        $manifestPath = Join-Path $package 'manifest.json'
        [IO.File]::WriteAllText($manifestPath, $manifest)
        $older = $now.AddDays(-2)
        [IO.File]::SetCreationTimeUtc($manifestPath, $older)
        [IO.File]::SetCreationTimeUtc($png, $older)
        $review = (Post 'api/ocr-provider/review' @{path=$package}).result
        if ($review.status -ne 'pending' -or $review.requestID -ne $requestID) { throw 'Installed OCR review did not retain request ID.' }
        $approved = (Post 'api/ocr-provider/approve' @{requestID=$requestID;confirm=$true}).result
        if ($approved.status -ne 'completed') { throw 'Installed OCR did not process the synthetic request.' }
        $result = (Post 'api/ocr-provider/result' @{requestID=$requestID;directory=$output;confirm=$true}).result.path
        $response = Get-Content -LiteralPath (Join-Path $result 'manifest.json') -Raw | ConvertFrom-Json
        if ($response.inReplyTo -ne $requestID -or $response.items.Count -ne 2 -or $response.provenance.networkUsed) { throw 'Installed OCR response differing from request.' }
        $txt = $response.items | Where-Object uti -eq 'public.utf8-plain-text' | Select-Object -First 1
        $recognized = Get-Content -LiteralPath (Join-Path (Join-Path $result 'payload') $txt.relativePath) -Raw
        if (($recognized -replace '\s','') -notmatch '1234567890') { throw 'Installed OCR response omitted synthetic digits.' }
        $ocrCheck = 'packaged offline OCR request, approval and result'
    }
    Post 'api/shutdown' @{} | Out-Null
    if (!$server.WaitForExit(25000) -or $server.ExitCode -ne 0) { throw 'Installed CLI failed to shut down cleanly.' }
    Remove-IsolatedInstall
    $uninstaller = $null
    if ((Test-Path -LiteralPath $gui) -or (Test-Path -LiteralPath $cli) -or !(Test-Path -LiteralPath $old) -or !(Test-Path -LiteralPath $history)) { throw 'Uninstall did not remove binaries and retain isolated user data.' }
    Write-Output "OK installer, optional prior build upgrade, x64 PE, version, loopback, settings migration, disabled clipboard, text, encrypted 7Z and edit preserving original, $ocrCheck, shutdown, and uninstall retaining data."
} finally {
    if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -Force }
    Remove-IsolatedInstall
    foreach ($key in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process')
    }
    $tempParent = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path.TrimEnd('\') + '\'
    if ($scratch.StartsWith($tempParent, [System.StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($scratch) -match '^GaoCaoZuo-smoke-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
