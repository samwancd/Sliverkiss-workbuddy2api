@echo off
REM Launch wb2api watchdog (Windows). Double-click or run from cmd.
REM The watchdog starts wb2api and auto-restarts it on crash/hang.
REM Pass extra args to watchdog.ps1 if needed, e.g.: start-watchdog.bat -Port 7863
cd /d %~dp0
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0watchdog.ps1" %*
