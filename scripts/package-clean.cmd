@echo off
setlocal enableextensions

rem Convenience: package with force overwrite and ensure no staging remains.

set SCRIPT_DIR=%~dp0
call "%SCRIPT_DIR%package.cmd" -Force
exit /b %ERRORLEVEL%
