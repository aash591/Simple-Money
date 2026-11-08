@echo off
setlocal

rem SimpleMoney Windows bootstrap. All paths are resolved from this file and
rem the current Windows user, so the repository can be cloned anywhere.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\SetupEnvironment.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo.
  echo Setup failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo.
echo SimpleMoney setup is complete. Open a new terminal before developing.
exit /b 0
