//=============================================================================
// OutlastSDKLibrary
//
// The script-side surface of the Outlast SDK. Every function here is an ORDINARY
// script function with a placeholder body -- at runtime the SDK overwrites the
// UFunction's dispatch pointer so the real work happens in C++.
// The stub bodies never execute. They exist so the function compiles and carries
// a signature, which is how the C++ side reads parameters and writes the return
// value.
//
// USAGE from any mod script:
//     `class'OutlastSDKLibrary'.static.SDK_WriteFile("..\\dump.txt", Data);`
//
//
// WHAT BELONGS IN HERE
//
// Only things UnrealScript genuinely CANNOT do. Script already has log(),
// GetSystemTime(), FindObject(), ConsoleCommand() and a constrained FileWriter,
// so wrapping those would add surface without adding capability. Each group below
// records why script cannot reach it, so nobody later mistakes one of these for
// redundant and removes it.
//
//
// WHY THE WHOLE SURFACE IS DECLARED UP FRONT
//
// Changing any signature means re-cooking this package. Adding a C++
// implementation does not. So the expensive half -- settling the API -- happens
// once, here, and the cheap half happens whenever.
//
// An unimplemented function is harmless: nothing hijacks it, the stub body runs,
// and it returns the safe default written below. Callers should check the return
// value rather than assume a native is bound.
//
//
// BUILD: compile/cook this into a package the game loads (the SDK's mod mounting,
// or an existing DLC build). On load, the SDK's BindAll() matches these by class
// and function name and binds each to its C++ implementation.
//=============================================================================
class OutlastSDKLibrary extends SDKModLibrary;


//-----------------------------------------------------------------------------
// Filesystem
//
// Script has FileWriter, but it is locked to five engine-chosen directories
// (FWFT_Log / Stats / HTML / User / Debug), so arbitrary paths are out of reach.
// Reading is worse: UnrealScript has no file reader of any kind, which makes
// SDK_ReadFile the one function here with no script workaround whatsoever.
//
// Paths are relative to the game's Binaries\Win64 directory unless absolute.
//-----------------------------------------------------------------------------

/** Read an entire file as text. FALSE if it is missing or unreadable. */
static final function bool SDK_ReadFile(string Path, out string Content)
{
	Content = "";
	return false;
}

/** Write `Content` to `Path`, replacing any existing file. */
static final function bool SDK_WriteFile(string Path, string Content)
{
	return false;
}

/** Append `Content` to `Path`, creating it if needed. */
static final function bool SDK_AppendFile(string Path, string Content)
{
	return false;
}

/** TRUE if `Path` exists and is a file. */
static final function bool SDK_FileExists(string Path)
{
	return false;
}

/** Delete `Path`. FALSE if it did not exist or could not be removed. */
static final function bool SDK_DeleteFile(string Path)
{
	return false;
}

/**
 * List files matching a wildcard, e.g. "..\\Mods\\*.dll". Returns the count.
 * Intended for discovery, where the set is not known ahead of time.
 */
static final function int SDK_FindFiles(string Pattern, out array<string> OutFiles)
{
	OutFiles.Length = 0;
	return 0;
}


//-----------------------------------------------------------------------------
// Level streaming
//
// WorldInfo.StreamingLevels is declared `const`, so script cannot append to it.
// Kismet's streaming actions only toggle levels the persistent map already listed
// at cook time. Attaching one at runtime is C++ only, and it is what lets a
// sublevel join a retail map without re-saving that map.
//
// PackageName is a `name` rather than a string on purpose: a name literal is baked
// into this package's name table when it cooks, so it is already registered in the
// global table by the time the call happens.
//-----------------------------------------------------------------------------

/**
 * Attach a streaming level to the current world.
 *
 * @param PackageName    Sublevel package, without path or extension.
 * @param bVisible       Make it visible once loaded, not merely resident.
 * @param bBlockOnLoad   Finish loading before returning. Use when something queries
 *                       the contents immediately -- navmesh, collision -- and cannot
 *                       tolerate a frame or two of absence.
 */
static final function bool SDK_AddStreamingLevel(name PackageName, optional bool bVisible = true, optional bool bBlockOnLoad = false)
{
	return false;
}

/** Hide, unload and detach a streaming level added earlier. */
static final function bool SDK_RemoveStreamingLevel(name PackageName)
{
	return false;
}

/** TRUE if the level is attached, loaded and currently visible. */
static final function bool SDK_IsStreamingLevelLoaded(name PackageName)
{
	return false;
}


//-----------------------------------------------------------------------------
// Reflection
//
// This build has no GetPropertyText/SetPropertyText, so script can only touch
// properties its own class declares. These reach any property on any object by
// name, including ones no script class exposes.
//
// Values are text in the engine's own property format -- the same one the console
// and .ini files use.
//-----------------------------------------------------------------------------

/** Read any property on any object as text. */
static final function bool SDK_GetProp(Object Obj, name Prop, out string Value)
{
	Value = "";
	return false;
}

/** Write any property on any object from text. */
static final function bool SDK_SetProp(Object Obj, name Prop, string Value)
{
	return false;
}


//-----------------------------------------------------------------------------
// Mod management
//
// The SDK's own state, which by definition has no script equivalent. This is the
// API the Mod Launcher drives, and it is also how one mod can cooperate with
// another rather than assuming it runs alone.
//
// Enabling and disabling are live: the SDK tracks every hook, native and detour by
// owner, so revoking one undoes exactly its own changes and leaves the rest
// running.
//-----------------------------------------------------------------------------

/** Fill `OutMods` with the name of every discovered mod. Returns the count. */
static final function int SDK_ListMods(out array<string> OutMods)
{
	OutMods.Length = 0;
	return 0;
}

/** TRUE if `ModName` is loaded and currently active. */
static final function bool SDK_IsModEnabled(string ModName)
{
	return false;
}

/**
 * Enable or disable a mod without restarting.
 *
 * Script mods extending the same class can conflict, so a caller flipping several
 * at once should expect the SDK to refuse some combinations.
 *
 * Refused (returns false) while a multiplayer session runs on this machine, hosting
 * or joined: the mod set is fixed from login until the session ends.
 */
static final function bool SDK_SetModEnabled(string ModName, bool bEnable)
{
	return false;
}


//-----------------------------------------------------------------------------
// Class swap
//
// The runtime form of an ini class override ([Engine.GameInfo] DefaultGame=...,
// PlayerControllerClass=..., and so on). Script can only set properties its own
// class declares, so pointing an engine class's class-typed property at a modded
// subclass is C++ only -- and it is what lets a mod replace a game type or a
// controller without editing the game's ini.
//
// The swap is owner-tagged: call it from your manifest's OnLoad and the SDK
// reverts it when the mod is disabled. It takes effect the next time the engine
// SPAWNS that class -- for a game type, the next map load.
//-----------------------------------------------------------------------------

/**
 * Point a class-typed property at a class.
 *
 * @param Key     "[Package.]Class.Property", e.g. "Engine.GameInfo.DefaultGame".
 * @param Value   "[Package.]NewClass", e.g. "MultiOL.MultiOLGame". "" clears it.
 * @return        Number of objects rewritten (0 if the class/property wasn't found).
 */
static final function int SDK_SwapClass(string Key, string Value)
{
	return 0;
}


//-----------------------------------------------------------------------------
// Game type
//
// The game class is chosen by the static event GameInfo.SetGameType, not by a
// class-typed property, so SDK_SwapClass cannot set it. This hooks that function to
// return your class instead -- how a mod replaces the game type (a mod menu's OLGame
// subclass, for example). Owner-tagged like a swap: it reverts when your mod is
// disabled, and takes effect on the next map load.
//-----------------------------------------------------------------------------

/**
 * Make the engine spawn `ClassName` (a GameInfo/OLGame subclass) as the game type.
 *
 * @param ClassName  "[Package.]Class", e.g. "MyMod.MyGame".
 * @return           1 on success, 0 if the class was not found.
 */
static final function int SDK_SetGameClass(string ClassName)
{
	return 0;
}


//-----------------------------------------------------------------------------
// On-screen notices
//
// The tutorial strip, the new-objective flash and the message line -- the "picked
// up a battery" kind of notice. The game raises all three from C++ (OLTutorialManager
// AddItem/AddPunctualItem, AOLHUD ShowNewObjective/AddMessage), and none of that has
// a script face, so a mod that wants one has to reproduce the sequence: which fields,
// in which order, against which clock.
//
// This is the one group here that is convenience rather than capability. The fields
// behind these notices are ordinary script variables, so a determined mod could write
// them itself. What it would have to rediscover is the part that is easy to get wrong
// and is the game's decision, not the caller's: that the tutorial strip stays silent
// when the player has tutorials switched off, that a message already on screen gets
// its time refreshed rather than queued a second time, and that a fade measures itself
// against the world clock.
//
// Text is passed in already localized, so a mod is free to use Localize(), its own
// table, or a literal. Note that key-binding tokens are NOT substituted -- the game's
// tutorials run their text through a C++ translator first, which script cannot reach.
//
// Each takes the object that owns the notice rather than finding the local player, so
// these work for any player the caller can reach. A notice still only ever draws on
// the machine that runs it, so in a multiplayer mod each machine raises its own.
//-----------------------------------------------------------------------------

/**
 * Put a line on the tutorial strip.
 *
 * @param Manager     The player's OLTutorialManager (OLPlayerController.TutorialManager).
 * @param Text        Localized text to show.
 * @param bPunctual   Let the game time it out by itself, the way the battery and
 *                    climb-up tutorials do. FALSE holds the line up until
 *                    SDK_HideTutorial, which is how a prompt that waits on the
 *                    player is done.
 * @return            FALSE if the player has tutorials switched off, which the game
 *                    itself honours and so does this.
 */
static final function bool SDK_ShowTutorial(OLTutorialManager Manager, string Text, optional bool bPunctual = true)
{
	return false;
}

/** Take down the tutorial line. */
static final function bool SDK_HideTutorial(OLTutorialManager Manager)
{
	return false;
}

/**
 * Raise the new-objective flash.
 *
 * @param HUD           The player's OLHUD.
 * @param Text          Localized text to show. The game builds this as its
 *                      "New Objective" line followed by the objective itself.
 * @param KeepAliveAt   Where the player is standing, so the flash lingers until they
 *                      have walked away from it (NewObjectiveZoneRadius). Left out,
 *                      it fades on its timer alone.
 */
static final function bool SDK_ShowObjective(OLHUD HUD, string Text, optional vector KeepAliveAt)
{
	return false;
}

/**
 * Add a line to the message queue. The HUD shows it when nothing more important is
 * up, which is what the game does for pickups.
 *
 * @param HUD           The player's OLHUD.
 * @param Text          Localized text to show.
 * @param MessageType   Which style the message screen draws it in.
 * @param Seconds       How long it stays up once shown.
 * @return              TRUE either way: a line already queued is not added twice, it
 *                      simply gets its full time again, which is how the game stops a
 *                      repeated action flooding the queue.
 */
static final function bool SDK_ShowMessage(OLHUD HUD, string Text, optional OLHUD.EHUDMessageType MessageType, optional float Seconds = 3.0)
{
	return false;
}


defaultproperties
{
}