<#
Verify ELF PT_LOAD segment alignment (p_align).

This enforces that the maximum LOAD segment alignment is <= MaxAlign (default 0x4000).

Usage:
  .\verify_elf_page_size.ps1 -Path .\out
  .\verify_elf_page_size.ps1 -Path .\out -MaxAlign 0x4000
  .\verify_elf_page_size.ps1 -Path .\out -Ndk "C:\Android\ndk\26.2.11394342"

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
  [string]$Ndk,

  [Parameter(Mandatory = $false)]
  [string]$MaxAlign = '0x4000'
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

function Get-SoFiles {
  param([string]$Path)

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    if ($Path.ToLowerInvariant().EndsWith('.so')) {
      return @((Resolve-Path -LiteralPath $Path).Path)
    }
    return @()
  }

  if (Test-Path -LiteralPath $Path -PathType Container) {
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.so' | ForEach-Object { $_.FullName } | Sort-Object)
  }

  throw "Path not found: $Path"
}

function Get-ReadElfOutput {
  param(
    [hashtable]$ReadElf,
    [string]$SoPath
  )

  if ($ReadElf.Mode -eq 'native') {
    $out = & $ReadElf.Command -W -l $SoPath 2>$null
    if ($LASTEXITCODE -ne 0) {
      $out = & $ReadElf.Command -l $SoPath 2>$null
      if ($LASTEXITCODE -ne 0) { throw "readelf failed for $SoPath" }
    }
    return $out
  }

  if ($ReadElf.Mode -eq 'wsl') {
    $linuxPath = & wsl -e wslpath -a -u $SoPath 2>$null
    $linuxPath = ($linuxPath | Select-Object -First 1).Trim()
    if (-not $linuxPath) { throw "wslpath failed for $SoPath" }

    $bash = "{0} -W -l '{1}'" -f $ReadElf.Command, ($linuxPath.Replace("'", "'\\''"))
    $out = & wsl -e bash -lc $bash 2>$null
    if ($LASTEXITCODE -ne 0) {
      $bash2 = "{0} -l '{1}'" -f $ReadElf.Command, ($linuxPath.Replace("'", "'\\''"))
      $out = & wsl -e bash -lc $bash2 2>$null
      if ($LASTEXITCODE -ne 0) { throw "WSL readelf failed for $SoPath" }
    }

    return $out
  }

  throw "Unknown ReadElf mode: $($ReadElf.Mode)"
}

function Parse-MaxLoadAlign {
  param(
    [string[]]$ReadElfOutput
  )

  $max = 0
  foreach ($line in $ReadElfOutput) {
    $trim = $line.Trim()
    if (-not $trim.StartsWith('LOAD')) { continue }

    $toks = $trim -split '\s+'
    if ($toks.Count -lt 2) { continue }
    $alignTok = $toks[$toks.Count - 1]

    if ($alignTok -match '^0x[0-9a-fA-F]+$') {
      $v = [Convert]::ToInt64($alignTok.Substring(2), 16)
      if ($v -gt $max) { $max = $v }
    }
  }

  return $max
}

$resolved = Resolve-ReadElf -ReadElf $ReadElf -Ndk $Ndk
$files = Get-SoFiles -Path $Path

if ($files.Count -eq 0) {
  Write-Host "No .so found under: $Path"
  exit 2
}

$maxAlignDec = if ($MaxAlign -match '^0x') { [Convert]::ToInt64($MaxAlign.Substring(2), 16) } else { [int64]$MaxAlign }

$bad = @()
foreach ($so in $files) {
  $out = Get-ReadElfOutput -ReadElf $resolved -SoPath $so
  $max = Parse-MaxLoadAlign -ReadElfOutput $out
  if ($max -gt $maxAlignDec) {
    $bad += [PSCustomObject]@{ Path = $so; MaxAlign = ('0x{0:x}' -f $max) }
  }
}

if ($bad.Count -gt 0) {
  Write-Host "FAIL: one or more files exceed max LOAD alignment $MaxAlign"
  foreach ($b in $bad) {
    Write-Host ("  {0} (maxLoadAlign={1})" -f $b.Path, $b.MaxAlign)
  }
  exit 1
}

Write-Host ("OK: {0} file(s) have max LOAD align <= {1}" -f $files.Count, $MaxAlign)
exit 0
