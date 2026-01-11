@echo off
setlocal enableextensions

rem Package the repo into a clean zip (Windows CMD entrypoint).
rem Uses PowerShell packager and auto-cleans temp staging by default.

set SCRIPT_DIR=%~dp0
set REPO_ROOT=%SCRIPT_DIR%..

pushd "%REPO_ROOT%" >nul

where powershell >nul 2>nul
if errorlevel 1 (
  echo ERROR: powershell not found.
  popd >nul
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%package.ps1" %*
set EC=%ERRORLEVEL%

popd >nul
exit /b %EC%
