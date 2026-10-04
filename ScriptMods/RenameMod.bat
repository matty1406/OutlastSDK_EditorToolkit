@echo off
setlocal

rem Part of the OutlastSDK Editor Toolkit.
rem Renames a mod made with MakeMod.bat: its folder, files, classes and registration.

set OldName=
set NewName=

echo Please enter the name of the mod to rename
set /p OldName=

if not defined OldName (
    echo No name given.
    TIMEOUT /T 3 /nobreak > NUL
    exit /b 1
)

echo Please enter the new name
set /p NewName=

if not defined NewName (
    echo No new name given.
    TIMEOUT /T 3 /nobreak > NUL
    exit /b 1
)

rem Both names go over as environment variables, so quotes or & in what was typed
rem cannot break the call.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MakeModSrcFiles\RenameMod.ps1" -EngineRoot "%~dp0."

if ERRORLEVEL 1 (
    echo.
    echo Rename failed.
)

pause