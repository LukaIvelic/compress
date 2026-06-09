@echo off
setlocal

if "%~1"=="" (
  echo Usage: compress ^<path-to-video^>
  exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0compress-core.ps1" %*
exit /b %ERRORLEVEL%
