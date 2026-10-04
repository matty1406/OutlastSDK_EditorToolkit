# OutlastSDK Editor Toolkit

Everything you need to build Outlast mods in the engine source tree, split by what you are writing:

| Folder | What it is |
| --- | --- |
| `ScriptMods\` | UnrealScript mods. MakeMod scaffolding plus the OutlastSDK script package. |
| `NativeMods\` | C++ mods. MakeNativeMod scaffolding and the SDK headers. |

A mod can be either one, or both at once with C++ hosting the script half.

> [!WARNING]
> **C++ mods are not available yet.** `NativeMods\` is not included in this release, so only UnrealScript mods can be built for now. The C++ sections below describe what is coming.

> [!WARNING]
> **The OutlastSDK is not out yet.** For now this toolkit is for making non-SDK mods, loaded the usual way, with SDK support coming later. Until then the manifest, the Mods menu and the `OutlastSDKLibrary` functions do nothing in game. You can delete the generated manifest, and the build will tell you it made a plain script package.

**[MODDING.md](MODDING.md)** is the reference: every macro, every library function, what hooks and detours each reach, and what the SDK does with your mod once it is installed.

## Requires the [Outlast Retail Package Patch](https://github.com/matty1406/Outlast_Retail_Package_Patch)

Install that [patch](https://github.com/matty1406/Outlast_Retail_Package_Patch) and rebuild the engine first. It adds the `-SaveAsRetail` switch, so without it `CompileRetail.bat` silently does nothing and your mods cannot be loaded by retail Outlast.

## Install

Put this folder inside the engine tree and run `Install.bat`. It copies each group where it belongs and registers the SDK script package with the compiler. `NativeMods\` stays put, since it is an include folder you point your compiler at.

## Quick start: UCScript mod

Run `MakeMod.bat` at the engine root and type a mod name and your author name. You get:

```
Development\Src\<Mod>\
    Classes\<Mod>Manifest.uc     your mod's manifest - start here
    Compile.bat                  build
    CompileRetail.bat            build so retail Outlast can load it
    Deploy.bat                   package the retail build into Development\Src\<Mod>\Output\<Mod>\
    <Mod>.code-workspace         workspace, with Core/Engine/OLGame alongside
```

Fill in the manifest and run `Compile.bat` while you work on it. To ship it, run `CompileRetail.bat`, then `Deploy.bat`. That is a mod. Deploy refuses a build that is not in retail format, since retail Outlast could not load it.

### The manifest

Every SDK script mod needs one, and `MakeMod.bat` writes it for you. It extends `SDKModManifest`, which is how the SDK recognises your mod: it reads the parent class straight out of the compiled `.u` without loading it, so your mod can be listed while still disabled.

Set the `SDKMod*` defaults for the name, version and author, and put your setup in `OnLoad()`. Class swaps, hooks and detours made there are tagged to your mod, so disabling it undoes them, and `OnUnload()` is there for anything the SDK cannot know about.

**Your `SDKModId` is namespaced by your `SDKModAuthor`** - `"YourName.MyMod"`, not `"MyMod"`. That way two people can both ship a mod of the same name without clashing. The build scripts check it before compiling and tell you if it does not match, because the SDK refuses such a mod at load. Leave `SDKModId` out entirely and you get `Author.ClassName`, which is usually what you wanted.

**If your mod needs another mod**, say so with `SDKModRequires(0) = "SomeoneElse.TheirLib"` (or `OL_MOD_REQUIRES(L"SomeoneElse.TheirLib")` in C++). The SDK loads it first whatever the load orders say, switches it on with yours if it is off, and holds your mod back with a readable reason if it is missing.

### The OutlastSDK package

`ScriptMods\OutlastSDK\` holds the two classes your mod compiles against:

- **`SDKModManifest`** - the manifest base class described above.
- **`OutlastSDKLibrary`** - file reading and writing, level streaming, reflection, mod management and class swapping. Things UnrealScript genuinely cannot do. Every function is a stub the SDK rebinds to C++ at runtime, so call them like any other static: `class'OutlastSDKLibrary'.static.SDK_WriteFile(Path, Data)`.
- **`SDKModLibrary`** - a third class that ships here but is optional - it only matters for the uncommon case of a C++ mod exposing its own natives to its script half. Ignore it otherwise.

Both the sources and a prebuilt `OutlastSDK.u` ship here. `Install.bat` puts the sources in the compile tree and the `.u` in `OLGame\Script\`, so your first mod compiles without rebuilding the SDK first. Edit the sources and recompile whenever you want to change it.

## Quick start: C++ mod

> [!WARNING]
> Not available yet. `NativeMods\` is not part of this release.

Run `NativeMods\MakeNativeMod.bat` and type a name. You get:

```
NativeMods\Mods\<Mod>\
    <Mod>.cpp                    your mod - start here
    mod.ini                      optional settings
    Build.bat                    build and install into the game
    <Mod>.code-workspace         workspace, with the SDK headers alongside
```

Run `Build.bat`. It compiles your mod and copies the dll into the game's `Mods` folder. `Build.bat nodeploy` builds without installing.

Your Outlast install is found automatically from Steam. For a non-Steam copy, set it once with `setx OUTLAST_DIR "C:\path\to\Outlast"`.

## Quick start: both together

> [!WARNING]
> Not available yet. This needs C++ mods, which are not part of this release.

A mod can have both halves, with C++ as the host. The dll carries the mod's identity and the `.u` adds the script side.

Scaffold each half as above, giving both the same name, then link them from the C++ side with one line:

```cpp
OL_MOD(L"YourName.MyMod", L"My Mod")
OL_MOD_VERSION(L"1.0")
OL_MOD_AUTHOR(L"YourName")
OL_MOD_ORDER(100)
OL_MOD_SCRIPT()
```

`OL_MOD_SCRIPT()` takes nothing: the SDK reads the package, its `SDKModManifest` subclass and the identity straight off the `.u`, so there is nothing to type twice and let drift.

**The dll is tied to its exact `.u` by a hash.** `Build.bat` embeds the SHA-256 of the cooked `.u` in the dll, and the SDK re-hashes the `.u` on disk at load and refuses the mod if it differs - so a `.u` swapped or edited after the build is caught. The rule is simple: **re-cook the `.u`, then rebuild the dll.** Compile the script half first so the `.u` exists for the dll build to hash.

**Optional: your own natives.** A script half also lets you expose C++ to your own UnrealScript. Declare one `class MyLibrary extends SDKModLibrary` in the `.u` with `static final function` stubs, implement each with `OL_NATIVE` in the dll, and the SDK binds them after the `.u` loads - only to that one class, and only if the function is `static final`.

Ship the dll, `mod.ini` and the `.u` together in the mod folder.

## Notes

- **Your mod shows up in the game's Mods menu** once it is in `OLGame\Mods\`, with its name, author, version and live state, and can be switched on and off from there. Anything that goes wrong loading it is reported there too, so check that before assuming the build failed.

- **Both build scripts rebuild only your package**, every time, so an edit never silently fails to take effect.

- **`CompileRetail.bat` needs the [Retail Package Patch](https://github.com/matty1406/Outlast_Retail_Package_Patch) and a rebuilt engine.** Until then the switch is ignored and you get a normal package.

## Licence

MIT, see [LICENSE](LICENSE). Mods you build with this are your own work, under whatever terms you like.

This repository is the development kit for OutlastSDK: the scaffolding, the templates and the SDK's public headers. The OutlastSDK runtime itself is proprietary and is not published here.

The licence covers this project's own files only. It does not cover Unreal Engine 3 (Epic Games) or Outlast and its data (Red Barrels). `NativeMods/include/ol/engine.h` is generated from Outlast's reflection data and is provided for interoperability.

## Credits

- **Epic Games** - Unreal Engine 3, the engine this SDK & toolkit is built on.

- **Red Barrels** - Outlast, the game this SDK & toolkit is designed for.

- **[Outlast-Level-Editor](https://github.com/superboo07/Outlast-Level-Editor)** by **superboo07** - The mod-scaffolding workflow (MakeMod, per-mod build bats, the generated workspace and tasks) comes from this project, reimplemented for the real source rather than UDK.

- **[Outlast Modding Community](https://discord.gg/hPYAappJSM)** - The wonderful people in the community who this is for, and for being a great help in learning how to mod Outlast in the first place.