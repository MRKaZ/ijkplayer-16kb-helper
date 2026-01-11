<#
Verify that ijkplayer's bundled FFmpeg (libijkffmpeg.so) has HTTPS/TLS protocols enabled.

We check for the presence of FFmpeg protocol symbols in the shared library:
  - ff_https_protocol
  - ff_tls_protocol

Usage:
  .\verify_ijkffmpeg_https.ps1 -Path ..\out
  .\verify_ijkffmpeg_https.ps1 -Path ..\out -Ndk "C:\Android\ndk\26.2.11394342"

Notes:
  - Uses llvm-readelf/readelf.
  - On Windows, if no NDK is set and no readelf is in PATH, it will attempt WSL.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Path,

  [Parameter(Mandatory = $false)]
  [string]$ReadElf,

  [Parameter(Mandatory = $false)]
  [string]$Ndk
)

$ErrorActionPreference = 'Stop'

function Resolve-ReadElf {
  param(
    [string]$ReadElf,
    [string]$Ndk
  )

  if ($ReadElf) {
    if (-not (Test-Path -LiteralPath $ReadElf)) { throw "ReadElf not found: $ReadElf" }
    return @{ Mode = 'native'; Command = (Resolve-Path -LiteralPath $ReadElf).Path }
  }

  foreach ($candidate in @('llvm-readelf', 'readelf')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Mode = 'native'; Command = $cmd.Source } }
  }

  if (-not $Ndk) {
    $Ndk = $env:ANDROID_NDK
    if (-not $Ndk) { $Ndk = $env:ANDROID_NDK_HOME }
  }

  if (-not $Ndk) {
    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    if ($wsl) {
      $wslCmd = & wsl -e bash -lc "command -v llvm-readelf || command -v readelf" 2>$null
      $wslCmd = ($wslCmd | Select-Object -First 1).Trim()
      if ($wslCmd) { return @{ Mode = 'wsl'; Command = $wslCmd } }
    }
    throw "No readelf/llvm-readelf in PATH. Set ANDROID_NDK (or pass -Ndk / -ReadElf), or install binutils in WSL."
  }

  $prebuilt = Join-Path $Ndk 'toolchains\llvm\prebuilt'
  if (-not (Test-Path -LiteralPath $prebuilt)) { throw "Invalid NDK path (missing toolchains\\llvm\\prebuilt): $Ndk" }

  $winPrebuilt = Join-Path $prebuilt 'windows-x86_64'
  $binPath = if (Test-Path -LiteralPath $winPrebuilt) { $winPrebuilt } else { (Get-ChildItem -LiteralPath $prebuilt -Directory | Select-Object -First 1).FullName }

  $llvmReadElf = Join-Path $binPath 'bin\llvm-readelf.exe'
  if (-not (Test-Path -LiteralPath $llvmReadElf)) {
    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    if (-not $wsl) { throw "llvm-readelf.exe not found under: $binPath" }
    $wslCmd = & wsl -e bash -lc "command -v llvm-readelf || command -v readelf" 2>$null
    $wslCmd = ($wslCmd | Select-Object -First 1).Trim()
    if (-not $wslCmd) { throw "No readelf/llvm-readelf in PATH and NDK llvm-readelf.exe missing. Install NDK on Windows or install binutils in WSL." }
    return @{ Mode = 'wsl'; Command = $wslCmd }
  }

  return @{ Mode = 'native'; Command = (Resolve-Path -LiteralPath $llvmReadElf).Path }
}

function Get-IjkFfmpegSos {
  param([string]$Path)

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    if ($Path.ToLowerInvariant().EndsWith('libijkffmpeg.so')) {
      return @((Resolve-Path -LiteralPath $Path).Path)
    }
    return @()
  }

  if (Test-Path -LiteralPath $Path -PathType Container) {
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter 'libijkffmpeg.so' | ForEach-Object { $_.FullName } | Sort-Object)
  }

  throw "Path not found: $Path"
}

function Get-ReadElfOutput {
  param(
    [hashtable]$ReadElf,
    [string]$SoPath
  )

  if ($ReadElf.Mode -eq 'native') {
    $out = & $ReadElf.Command -Ws $SoPath 2>$null
    if ($LASTEXITCODE -ne 0) { throw "readelf failed for $SoPath" }
    return $out
  }

  if ($ReadElf.Mode -eq 'wsl') {
    $linuxPath = & wsl -e wslpath -a -u $SoPath 2>$null
    $linuxPath = ($linuxPath | Select-Object -First 1).Trim()
    if (-not $linuxPath) { throw "wslpath failed for $SoPath" }
    $bash = "{0} -Ws '{1}'" -f $ReadElf.Command, ($linuxPath.Replace("'", "'\\''"))
    $out = & wsl -e bash -lc $bash 2>$null
    if ($LASTEXITCODE -ne 0) { throw "WSL readelf failed for $SoPath" }
    return $out
  }

  throw "Unknown ReadElf mode: $($ReadElf.Mode)"
}

function Has-Symbol {
  param(
    [string[]]$ReadElfOutput,
    [string]$Symbol
  )

  foreach ($line in $ReadElfOutput) {
    foreach ($tok in ($line -split '\s+')) {
      if ($tok -eq $Symbol) { return $true }
    }
  }
  return $false
}

$resolved = Resolve-ReadElf -ReadElf $ReadElf -Ndk $Ndk
$libs = Get-IjkFfmpegSos -Path $Path

if ($libs.Count -eq 0) {
  Write-Host "No libijkffmpeg.so found under: $Path"
  exit 2
}

$bad = @()
foreach ($so in $libs) {
  $out = Get-ReadElfOutput -ReadElf $resolved -SoPath $so
  $hasHttps = Has-Symbol -ReadElfOutput $out -Symbol 'ff_https_protocol'
  $hasTls = Has-Symbol -ReadElfOutput $out -Symbol 'ff_tls_protocol'

  if (-not $hasHttps -or -not $hasTls) {
    $bad += [PSCustomObject]@{ Path = $so; Https = $hasHttps; Tls = $hasTls }
  }
}

if ($bad.Count -gt 0) {
  Write-Host "FAIL: HTTPS/TLS protocol symbols missing in libijkffmpeg.so"
  foreach ($b in $bad) {
    Write-Host ("  {0} (ff_https_protocol={1}, ff_tls_protocol={2})" -f $b.Path, $b.Https, $b.Tls)
  }
  exit 1
}

Write-Host ("OK: HTTPS/TLS enabled in {0} libijkffmpeg.so file(s)" -f $libs.Count)
exit 0
