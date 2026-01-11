[CmdletBinding()]
param(
  [string]$OutDir = "dist",
  [string]$Name = "ijkplayer-16kb-helper",
  [switch]$NoGit,
  [switch]$Force,
  [switch]$KeepStaging,
  # Back-compat alias: older README used -NoStaging to mean "clean staging".
  [switch]$NoStaging
)

$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
  $here = Get-Location
  if (Test-Path (Join-Path $here "docker-compose.yml")) { return $here.Path }
  if (Test-Path (Join-Path $here "ijkplayer-16kb-helper\docker-compose.yml")) {
    return (Resolve-Path (Join-Path $here "ijkplayer-16kb-helper")).Path
  }
  throw "Run this from the helper repo root (the folder containing docker-compose.yml)."
}

$repoRoot = Get-RepoRoot
Push-Location $repoRoot
try {
  $dist = Join-Path $repoRoot $OutDir
  New-Item -ItemType Directory -Force -Path $dist | Out-Null

  # Default behavior: staging is deleted after zipping.
  # If caller passes -NoStaging (old name), treat it as "do not keep staging".
  if ($NoStaging) { $KeepStaging = $false }

  # Clean old staging folders to avoid clutter.
  Get-ChildItem -LiteralPath $dist -Directory -Filter '_staging-*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $gitRef = "nogit"

  if (-not $NoGit) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
      try {
        $gitRef = (git rev-parse --short HEAD 2>$null).Trim()
      } catch {
        $gitRef = "nogit"
      }
    }
  }

  $archive = Join-Path $dist ("{0}-{1}-{2}.zip" -f $Name, $timestamp, $gitRef)

  if ((Test-Path $archive) -and (-not $Force)) {
    throw "Archive already exists: $archive (use -Force to overwrite)"
  }
  if (Test-Path $archive) { Remove-Item -Force $archive }

  # Only include what is needed to build.
  $include = @(
    ".github",
    "android-16kb",
    "docker",
    "patches",
    "scripts",
    ".gitignore",
    "README.md",
    "docker-compose.yml"
  )

  # Exclude generated / huge directories.
  $excludeDirNames = @(
    ".git",
    "dist",
    "work",
    "ijkplayer",
    "android-16kb\\out",
    "android-16kb\\.deps"
  )

  $staging = Join-Path $dist ("_staging-{0}" -f $timestamp)
  if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
  New-Item -ItemType Directory -Force -Path $staging | Out-Null

  # Exclude patterns while copying.
  $excludeRegex = [regex]'\\(\.git|dist|work|ijkplayer|\.android-sdk)(\\|$)|\\android-16kb\\(out|\.deps)(\\|$)|\\scripts\\android-env\.sh$'

  function Copy-WithProgress([string]$sourcePath, [string]$destPath) {
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
      $destDir = Split-Path -Parent $destPath
      New-Item -ItemType Directory -Force -Path $destDir | Out-Null
      Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
      return
    }

    $allFiles = Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force | Where-Object {
      -not $excludeRegex.IsMatch($_.FullName)
    }

    $total = [Math]::Max($allFiles.Count, 1)
    $i = 0
    foreach ($f in $allFiles) {
      $i++
      $pct = [int](($i * 100) / $total)
      Write-Progress -Activity "Staging files" -Status "$i / $total" -PercentComplete $pct

      $rel = $f.FullName.Substring($sourcePath.Length).TrimStart([char[]]'\\/')
      $dstFile = Join-Path $destPath $rel
      $dstDir = Split-Path -Parent $dstFile
      New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
      Copy-Item -LiteralPath $f.FullName -Destination $dstFile -Force
    }

    Write-Progress -Activity "Staging files" -Completed
  }

  foreach ($item in $include) {
    $src = Join-Path $repoRoot $item
    if (Test-Path -LiteralPath $src) {
      $dst = Join-Path $staging $item
      Copy-WithProgress $src $dst
    }
  }

  # Remove excluded dirs if they got copied.
  foreach ($ex in $excludeDirNames) {
    $p = Join-Path $staging $ex
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
  }

  # Safety check: ensure no outputs slipped in.
  $bad = @()
  $bad += Get-ChildItem -LiteralPath $staging -Recurse -Directory -Force | Where-Object {
    $_.FullName -match "\\android-16kb\\(out|\.deps)(\\|$)" -or $_.FullName -match "\\(work|ijkplayer)(\\|$)"
  }
  if ($bad.Count -gt 0) {
    $bad | Select-Object -First 10 FullName | Format-List | Out-String | Write-Host
    throw "Packaging refused: staging contains excluded directories."
  }

  Write-Host "[*] Compressing archive (this may take a moment)..."
  Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archive

  Write-Host "OK: Created $archive"
  if ($KeepStaging) {
    Write-Host "Staging kept: $staging"
  }
}
finally {
  # Always clean staging unless explicitly requested to keep it.
  try {
    if ((-not $KeepStaging) -and ($staging) -and (Test-Path $staging)) {
      Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    }
  } catch { }
  Pop-Location
}
