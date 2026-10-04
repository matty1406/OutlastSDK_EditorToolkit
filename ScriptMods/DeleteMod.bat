@echo off
setlocal

rem Part of the OutlastSDK Editor Toolkit.
rem Deletes a mod made with MakeMod.bat: its folder, build and registration.

set ModName=

echo Please enter the name of the mod to delete
set /p ModName=

if not defined ModName (
    echo No name given.
    TIMEOUT /T 3 /nobreak > NUL
    exit /b 1
)

rem The name goes over as an environment variable, so quotes or & in what was typed
rem cannot break the call. The script lists what it will delete and asks to confirm.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MakeModSrcFiles\DeleteMod.ps1" -EngineRoot "%~dp0."

if ERRORLEVEL 1 (
    echo.
    echo Delete failed.
)

pause