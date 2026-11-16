@echo off
rem Shoji check GUI launcher
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0owned-gui.ps1"
