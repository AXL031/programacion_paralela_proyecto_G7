@echo off
setlocal
title Iniciar demo G7
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\control-demo.ps1" -Action Start
if errorlevel 1 goto error
exit /b 0
:error
echo.
echo No se pudo iniciar la demo. Revisa el mensaje anterior.
pause
exit /b 1
