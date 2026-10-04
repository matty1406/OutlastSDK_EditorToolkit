//=============================================================================
// SDKModManifest
//
// The base class a script mod's manifest extends. The SDK identifies a manifest
// by THIS parent -- read straight out of the cooked .u without loading it -- so
// nothing that merely happens to share a property name can be mistaken for one.
//
// Extend it DIRECTLY, set the SDKMod* defaults, and override OnLoad.
//
//=============================================================================
class SDKModManifest extends Object
	abstract;

// Read off the cooked .u by the SDK to list the mod while it is still disabled.
// Set them in the subclass's defaultproperties.
//
// Id, Name, Version and Author are ALL REQUIRED, the same four a native mod must
// declare. A mod missing any of them is refused at load, and the build scripts say so
// first. SDKModOrder is optional and defaults to 100.
//
// SDKModId is namespaced by SDKModAuthor: it must read "Author.Something", with the
// author part matching SDKModAuthor once spaces and punctuation are dropped. Two
// authors can then both ship a "HUDTweaks" without colliding.

var string SDKModId; // Unique identifier, "Author.Name". Required.
var string SDKModName; // Human-readable name for the mod. Required.
var string SDKModVersion; // Version string for the mod, e.g. "1.0". Required.
var string SDKModAuthor; // Author for the mod. Required -- SDKModId is namespaced by it.
var int    SDKModOrder; // Relative load order. Optional, defaults to 100. Higher numbers load later, so they can override lower-numbered mods; 0 is lowest.

// Other mods this one cannot run without, each "Author.Id" or "Author.Id>=1.2".
// The SDK checks them before loading anything and, if one is missing, disabled or
// too old, holds this mod back and says which -- instead of letting it half-run.
// It also loads them first, whatever their SDKModOrder, so there is no load order
// to hand-tune here.
var array<string> SDKModRequires;

/**
 * Runs once when the SDK enables this mod, after its package is resident. Override
 * it and do the mod's modifications.
 */
function OnLoad()
{
}

/**
 * Runs once when the SDK disables this mod, while it is still live. Undo anything
 * OnLoad did that the SDK does not revert for you. Class swaps, hooks, natives and
 * detours revert automatically; you do not undo those here. Optional.
 */
function OnUnload()
{
}

defaultproperties
{
	SDKModOrder = 100
}