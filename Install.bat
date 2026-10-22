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
rem The manifest check and name helpers are shared with the other sections, so they live in Shared.
copy /Y "%TK%Shared\Check-ModManifest.ps1" "%ROOT%\MakeModSrcFiles\" > nul
if ERRORLEVEL 1 goto Failed
copy /Y "%TK%Shared\ModNames.ps1" "%ROOT%\MakeModSrcFiles\" > nul
if ERRORLEVEL 1 goto Failed
echo   MakeMod.bat + RenameMod.bat + DeleteMod.bat + MakeModSrcFiles\

rem The SDK script package. Its sources go in the compile tree so you can read and
rem rebuild them; the prebuilt .u means a mod compiles without rebuilding it first.
robocopy "%TK%ScriptMods\OutlastSDK\Classes" "%ROOT%\Development\Src\OutlastSDK\Classes" /E > nul
if ERRORLEVEL 8 goto Failed
echo   Development\Src\OutlastSDK\Classes\

if exist "%TK%ScriptMods\OutlastSDK\OutlastSDK.u" (
    copy /Y "%TK%ScriptMods\OutlastSDK\OutlastSDK.u" "%ROOT%\OLGame\Script\" > nul
    rem A download can give the .u the same date as its sources, which the editor reads as out of date.
    rem copy /B with +,, stamps it with the current time instead.
    pushd "%ROOT%\OLGame\Script"
    copy /B OutlastSDK.u +,, > nul
    popd
    echo   OLGame\Script\OutlastSDK.u  ^(prebuilt^)
)

rem The SDK's own content, which the SDK package refers to, so the editor can load it cleanly.
rem /XO never replaces a newer copy, so edits made in the editor are kept.
if exist "%TK%ScriptMods\OutlastSDK\OutlastSDKContent.upk" (
    robocopy "%TK%ScriptMods\OutlastSDK" "%ROOT%\OLGame\Content\OutlastSDK" OutlastSDKContent.upk /XO > nul
    if ERRORLEVEL 8 goto Failed
    echo   OLGame\Content\OutlastSDK\OutlastSDKContent.upk
)

echo.
echo [CustomMaps]
copy /Y "%TK%CustomMaps\MakeMap.bat" "%ROOT%\" > nul
if ERRORLEVEL 1 goto Failed
robocopy "%TK%CustomMaps\MakeMapSrcFiles" "%ROOT%\MakeMapSrcFiles" /E > nul
if ERRORLEVEL 8 goto Failed
copy /Y "%TK%Shared\ModNames.ps1" "%ROOT%\MakeMapSrcFiles\" > nul
if ERRORLEVEL 1 goto Failed
copy /Y "%TK%Shared\Find-Outlast.ps1" "%ROOT%\MakeMapSrcFiles\" > nul
if ERRORLEVEL 1 goto Failed
echo   MakeMap.bat + MakeMapSrcFiles\

echo.
echo [Registering OutlastSDK with make]
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\MakeModSrcFiles\Register-Package.ps1" -EngineRoot "%ROOT%" -Package OutlastSDK
if ERRORLEVEL 1 goto Failed

echo.
echo Done. Run MakeMod.bat at the engine root to create a script mod, or MakeMap.bat for a map.
pause
exit /b 0

:Failed
echo.
echo Install failed.
pause
exit /b 1