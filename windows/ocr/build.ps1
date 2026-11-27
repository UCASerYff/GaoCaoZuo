param([Parameter(Mandatory = $true)][string]$OutputPath)

$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$winmd = Join-Path $env:SystemRoot 'System32\WinMetadata'
$compiler = Join-Path $framework 'csc.exe'
$source = Join-Path $PSScriptRoot 'WinOcr.cs'
$target = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
$references = @('Data', 'Foundation', 'Globalization', 'Graphics', 'Media', 'Storage') |
    ForEach-Object { '/r:' + (Join-Path $winmd ('Windows.' + $_ + '.winmd')) }
$references += @('System.Runtime.dll', 'System.Runtime.WindowsRuntime.dll', 'System.Web.Extensions.dll') |
    ForEach-Object { '/r:' + (Join-Path $framework $_) }
& $compiler /nologo /platform:x64 /optimize+ /target:exe "/out:$target" @references $source
if ($LASTEXITCODE -ne 0) { throw 'Windows OCR helper compilation failed' }
