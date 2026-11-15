@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0SqPaint-Korean.ps1" -Mode Apply
pause
