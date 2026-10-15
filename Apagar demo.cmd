@echo off
setlocal
title Apagar demo G7
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\control-demo.ps1" -Action Stop
if errorlevel 1 goto error
exit /b 0
:error
echo.
echo No se pudo completar el apagado. Revisa el mensaje anterior.
pause
exit /b 1
