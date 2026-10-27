@echo off
rem Inicia o WinDebloat Xerife Tech (o script pede elevacao de administrador sozinho)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0WinDebloat-XerifeTech.ps1"
