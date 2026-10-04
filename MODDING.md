# Modding with the Outlast SDK

What you can build with this toolkit, and how. See [README](README.md) to install it and scaffold your first mod.

> [!WARNING]
> **C++ mods are not available yet.** `NativeMods\` is not included in this release, so only UnrealScript mods can be built for now. The C++ parts below describe what is coming.

## Two kinds of mod

| | UnrealScript (`.u`) | C++ (`.dll`) |
| --- | --- | --- |
| Scaffold with | `MakeMod.bat` | `NativeMods\MakeNativeMod.bat` |
| You get | game classes, the SDK library, your own classes | every class in the game, typed, plus raw memory |
| Good for | gameplay logic, new actors, menus, anything UnrealScript can express | changing existing behaviour, intercepting engine calls, things script cannot reach |
| Turn it off mid-game | stops working, package stays in memory until restart | fully unloaded, nothing left running |

A mod can be both at once, with the C++ half hosting the script half.

## Identity

Every mod declares who it is, in its own code. Not in an ini file.

**C++** - in your `.cpp`:

| Macro | Required | What it is |
| --- | --- | --- |
| `OL_MOD(Id, DisplayName)` | yes | the two names: the key other mods use, and the one players see |
| `OL_MOD_VERSION(L"1.0")` | yes | your version, compared component-wise (`1.10` is newer than `1.2`) |
| `OL_MOD_AUTHOR(L"YourName")` | yes | you |
| `OL_MOD_ORDER(100)` | no | lower loads earlier; 100 if you say nothing |
| `OL_MOD_DESCRIPTION(L"...")` | no | a sentence or two for the mod menu |
| `OL_MOD_REQUIRES(Id[, MinVer])` | no | another mod you cannot run without |
| `OL_MOD_SCRIPT()` | no | this mod also ships a `.u` |
| `OL_MOD_NEEDS_BINARY()` | no | refuse to load on a different `OLGame.exe` |

Leave out one of the required four and the build fails naming what you missed.

**UnrealScript** - in your manifest's `defaultproperties`:

| Property | Required | What it is |
| --- | --- | --- |
| `SDKModId` | yes | the key other mods use |
| `SDKModName` | yes | the name players see |
| `SDKModVersion` | yes | your version, compared component-wise |
| `SDKModAuthor` | yes | you |
| `SDKModOrder` | no | lower loads earlier; 100 if you say nothing |
| `SDKModRequires(n)` | no | another mod you cannot run without |

Both kinds of mod require the same four things: an Id, a Name, a Version and an Author. Miss one and your build stops and tells you which. Order is optional on both sides.

### Rules for the Id

- It must read `Author.Something`, so two authors can both ship a `HUDTweaks`.
- The author part must match your declared author, ignoring case, spaces and punctuation. `Matty D.` owns `MattyD.*`.
- Your build scripts check this before compiling and tell you if it is wrong.
- Two installed mods claiming the same Id are **both** refused, because neither can be told from the other.
- Pick it once. It keys the player's on/off choice, so renaming it resets that for everyone.

## Dependencies

```cpp
OL_MOD_REQUIRES(L"Them.CoreLib")            // any version
OL_MOD_REQUIRES(L"Them.CoreLib", L"1.2")    // 1.2 or newer
```

```unrealscript
SDKModRequires(0) = "Them.CoreLib"
SDKModRequires(1) = "Them.Other>=1.2"
```

What the SDK does with them:

- **Loads them first.** Whatever the `Order` numbers say. `Order` only separates mods that do not depend on each other.
- **Switches them on with yours.** If a dependency is installed but off, enabling your mod enables it too, and the player is asked first.
- **Switches yours off with them.** If the player disables something you need, your mod goes off too rather than run broken.
- **Blocks your mod, with a reason**, if a dependency is missing, too old, or if two mods require each other in a circle.

## Script mods

### The manifest

One class per mod, extending `SDKModManifest`. It is how the SDK finds your mod, and it is where your mod starts.

```unrealscript
class MyModManifest extends SDKModManifest;

function OnLoad()
{
    // your setup
}

function OnUnload()
{
    // optional
}
```

- `OnLoad` runs every time your mod is enabled, including a re-enable. Not just the first.
- `OnUnload` runs when it is disabled, while your mod is still live.
- Class swaps, hooks, natives and detours you make in `OnLoad` are tagged to your mod and undone for you. `OnUnload` is only for what the SDK cannot know about, like a streaming level you attached.

### `OutlastSDKLibrary`

Things UnrealScript cannot do on its own. Call them like any other static:

```unrealscript
class'OutlastSDKLibrary'.static.SDK_WriteFile("Mods\\MyMod\\save.txt", Data);
```

**Files** - paths are relative to the Outlast install folder.

| Function | Does |
| --- | --- |
| `SDK_ReadFile(Path, out Content)` | read a whole text file |
| `SDK_WriteFile(Path, Content)` | write, creating or replacing |
| `SDK_AppendFile(Path, Content)` | append to the end |
| `SDK_FileExists(Path)` | test for one |
| `SDK_DeleteFile(Path)` | remove one |
| `SDK_FindFiles(Pattern, out OutFiles)` | list matches, returns the count |

**Streaming levels** - load extra map content at runtime.

| Function | Does |
| --- | --- |
| `SDK_AddStreamingLevel(Package, [bVisible], [bBlockOnLoad])` | stream a package into the current map |
| `SDK_RemoveStreamingLevel(Package)` | take it back out |
| `SDK_IsStreamingLevelLoaded(Package)` | test one |

**Reflection** - reach properties UnrealScript has no accessor for.

| Function | Does |
| --- | --- |
| `SDK_GetProp(Obj, Prop, out Value)` | read any property by name, as a string |
| `SDK_SetProp(Obj, Prop, Value)` | write one |

**Other mods**

| Function | Does |
| --- | --- |
| `SDK_ListMods(out OutMods)` | every installed mod's Id, returns the count |
| `SDK_IsModEnabled(ModId)` | is it on |
| `SDK_SetModEnabled(ModId, bEnable)` | turn it on or off, cascading like the menu does |

**Class swapping**

| Function | Does |
| --- | --- |
| `SDK_SwapClass(Key, Value)` | point a class property at your subclass, e.g. `"Engine.GameInfo.PlayerControllerClass"` |
| `SDK_SetGameClass(ClassName)` | replace the game class itself, which is not a property and needs its own path |

Both take effect on the **next map load**, and both are reverted when your mod is disabled.

### Your own natives

If your mod has a C++ half, it can put its own functions behind UnrealScript. Declare one class extending `SDKModLibrary` with `static final function` stubs, and implement each with `OL_NATIVE` in the DLL. The SDK binds them after your `.u` loads - only to that one class, and only if the function is `static final`.

## Native mods

> [!WARNING]
> Not available yet. `NativeMods\` is not part of this release.

### A whole mod

```cpp
#include <ol/mod.h>
#include <ol/engine.h>
using namespace ol;

OL_MOD(L"YourName.HalfDamage", L"Half Damage")
OL_MOD_VERSION(L"1.0")
OL_MOD_AUTHOR(L"YourName")
OL_MOD_ORDER(100)

OL_HOOK(OLHero, TakeDamage)
{
    P.DamageAmount /= 2;
    return false;
}
```

### Hooks

`OL_HOOK(Class, Func)` intercepts an UnrealScript function.

- `Self` is the object, typed.
- `P` is the parameter struct, with named fields you can read and rewrite.
- `return false` lets the original run, and every other mod's hook with it.
- `return true` blocks the original and all later hooks. A full override.
- Matching is **by name across the whole subclass tree**, so overrides in subclasses are covered without naming each one.
- Any number of mods can hook the same function. They nest in load order.

### Detours

`OL_DETOUR(Class, Func)` patches machine code instead, for what hooks cannot reach.

| Reach | `OL_HOOK` | `OL_DETOUR` |
| --- | --- | --- |
| Script functions | yes | no |
| Native functions called from script | yes | yes |
| Intrinsic natives | **no** | yes |
| Engine C++ calling engine C++ | no | yes, with the right address |
| Several mods on one target | yes, they chain | no, last wins |

Inside the body:

| | |
| --- | --- |
| `Self` | the object, typed |
| `A1`, `A2`, `A3` | the register arguments after `this` |
| `Frame()`, `Result()` | the same two, named for script exec thunks |
| `Original()` | run the real function; simply don't call it to replace it outright |

Detours can decline to install if the target's first instructions cannot be safely relocated. That disables the detour and logs why, rather than failing your mod.

### Reading and writing the game

Every generated class is a pure accessor over the engine's own memory.

| Call | Does |
| --- | --- |
| `FindFirst<T>()` | the first live object of that class |
| `ForEach<T>(fn)` | visit every live object of that class, returns how many |
| `Cast<T>(obj)` | type-checked cast, null if it isn't one |
| `obj->Name()` | its object name |
| `obj->IsA(L"Class")` | inheritance test |
| `obj->Call(L"Class", L"Func", &parms)` | call any UnrealScript function on it |

```cpp
if (OLHero* hero = FindFirst<OLHero>())
{
    hero->Health() = 100.0f;
}
```

### Settings

Reads `mod.ini` in your own mod folder. You cannot read another mod's.

| Call | Does |
| --- | --- |
| `ConfigString(section, key, def, out, cap)` | a string setting |
| `ConfigInt(section, key, def)` | a number |
| `ConfigBool(section, key, def)` | accepts `true` / `yes` / `on` / `1` |

### Other helpers

| Call | Does |
| --- | --- |
| `Log(L"...")` | write to `OutlastSDK.log`, tagged with your mod |
| `MapName()` | the current map |
| `SwapClass(key, value)` | the C++ form of `SDK_SwapClass` |
| `AddStreamingLevel` / `RemoveStreamingLevel` / `IsStreamingLevelLoaded` | streaming, as above |
| `GroundAt(xyz)` | trace to the floor under a point |
| `OL_ON_LOAD { ... }` | startup code; return `false` to abort loading your mod |

## Mod states

What the player sees in the Mods menu, and what it means:

| Shown as | Meaning |
| --- | --- |
| `on` | loaded and running |
| `on (applies on map load)` | loaded, but its class swap only takes effect next map load |
| `off` | not loaded |
| `off (package stays loaded until restart)` | disabled, but its script classes are still in memory |
| `failed` | it tried to load and could not, and has been switched off |

## Limits worth knowing

- **A script package cannot be unloaded.** UE3 keeps it until the game exits. Disabling a script mod stops it working, but its classes stay resident.
- **Your mod can load at any time**, not just at startup. The player can enable it mid-game, and enabling another mod can pull yours in as a dependency.
- **A DLL with a script half is tied to that exact `.u`** by a hash. Re-cook the `.u`, then rebuild the DLL.
- **RVAs belong to one build of the game.** Mods that patch raw addresses should declare `OL_MOD_NEEDS_BINARY()` so they refuse to load on a different `OLGame.exe` instead of crashing it.