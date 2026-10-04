@echo off
setlocal

rem Part of the OutlastSDK Editor Toolkit.
rem Workflow based on Outlast-Level-Editor by superboo07
rem https://github.com/superboo07/Outlast-Level-Editor

set ModName=
set ModAuthor=

echo Please enter the name of your mod
set /p ModName=

if not defined ModName (
    echo No name given.
    TIMEOUT /T 3 /nobreak > NUL
    exit /b 1
)

echo Please enter your author name
set /p ModAuthor=

if not defined ModAuthor (
    echo No author given.
    TIMEOUT /T 3 /nobreak > NUL
    exit /b 1
)

rem The real work is in PowerShell - it has to edit a specific ini SECTION, which
rem batch cannot do without rewriting the file by hand. The name and author go over
rem as environment variables, so quotes or & in what was typed cannot break the call.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MakeModSrcFiles\MakeMod.ps1" -EngineRoot "%~dp0."

if ERRORLEVEL 1 (
    echo.
    echo Mod creation failed.
)

pause