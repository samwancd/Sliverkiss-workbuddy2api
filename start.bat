@echo off
REM Start wb2api gateway on Windows.
REM Uses cmd's "start" (Win32 CreateProcess) instead of PowerShell Start-Process,
REM to avoid the .NET "Item has already been added" bug that fires when the
REM environment block contains case-duplicated proxy vars (HTTPS_PROXY + https_proxy).
REM The service runs detached from this window; closing this window does NOT stop it.

cd /d "%~dp0" || exit /b 1

if not exist "wb2api.exe" (
    echo [ERROR] wb2api.exe not found, see README for build instructions.
    echo         go build -o wb2api.exe ./cmd/server
    pause
    exit /b 1
)

echo Starting wb2api. Logs at wb2api.log / wb2api.err. Closing this window will NOT stop the service.
start "" cmd /c "wb2api.exe %* > wb2api.log 2> wb2api.err"

echo Started. Verify with: curl.exe -s http://127.0.0.1:7863/status -H "Authorization: Bearer test_key"
