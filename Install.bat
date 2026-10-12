@echo off
setlocal
set TK=%~dp0
rem The engine root is one folder up, resolved so the messages show a plain path.
for %%i in ("%~dp0..") do set "ROOT=%%~fi"

if not exist "%ROOT%\Development\Src\Core\Classes" (
    echo This does not look like an UnrealEngine3 root: %ROOT%
    echo Put OutlastSDK_EditorToolkit inside the engine tree and run this again.
    pause
    exit /b 1
)

echo Installing the OutlastSDK Editor Toolkit into:
echo   %ROOT%
echo.

echo [ScriptMods]
copy /Y "%TK%ScriptMods\MakeMod.bat" "%ROOT%\" > nul
copy /Y "%TK%ScriptMods\RenameMod.bat" "%ROOT%\" > nul
copy /Y "%TK%ScriptMods\DeleteMod.bat" "%ROOT%\" > nul
robocopy "%TK%ScriptMods\MakeModSrcFiles" "%ROOT%\MakeModSrcFiles" /E > nul
if ERRORLEVEL 8 goto Failed
rem The manifest check is shared with NativeMods, so it lives in Shared; script mods call it from MakeModSrcFiles.
copy /Y "%TK%Shared\Check-ModManifest.ps1" "%ROOT%\MakeModSrcFiles\" > nul
if ERRORLEVEL 1 goto Failed
echo   MakeMod.bat + RenameMod.bat + DeleteMod.bat + MakeModSrcFiles\

rem The SDK script package. Its sources go in the compile tree so you can read and
rem rebuild them; the prebuilt .u means a mod compiles without rebuilding it first.
robocopy "%TK%ScriptMods\OutlastSDK\Classes" "%ROOT%\Development\Src\OutlastSDK\Classes" /E > nul
if ERRORLEVEL 8 goto Failed
echo   Development\Src\OutlastSDK\Classes\

if exist "%TK%ScriptMods\OutlastSDK\OutlastSDK.u" (
    copy /Y "%TK%ScriptMods\OutlastSDK\OutlastSDK.u" "%ROOT%\OLGame\Script\" > nul
    echo   OLGame\Script\OutlastSDK.u  ^(prebuilt^)
)

echo.
echo [Registering OutlastSDK with make]
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\MakeModSrcFiles\Register-Package.ps1" -EngineRoot "%ROOT%" -Package OutlastSDK
if ERRORLEVEL 1 goto Failed

echo.
echo Done. Run MakeMod.bat at the engine root to create a mod.
pause
exit /b 0

:Failed
echo.
echo Install failed.
pause
exit /b 1