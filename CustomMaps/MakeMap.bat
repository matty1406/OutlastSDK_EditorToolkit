@echo off
setlocal

rem Part of the OutlastSDK Editor Toolkit. Creates a map project.

set MapName=
set MapAuthor=

echo Please enter the name of your map project
set /p MapName=

if not defined MapName (
    echo No name given.
    TIMEOUT /T 3 /nobreak > NUL
    exit /b 1
)

echo Please enter your author name
set /p MapAuthor=

if not defined MapAuthor (
    echo No author given.
    TIMEOUT /T 3 /nobreak > NUL
    exit /b 1
)

rem The name and author go over as environment variables, so quotes or & in what was typed cannot break the call.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MakeMapSrcFiles\MakeMap.ps1" -EngineRoot "%~dp0."

if ERRORLEVEL 1 (
    echo.
    echo Map project creation failed.
)

pause