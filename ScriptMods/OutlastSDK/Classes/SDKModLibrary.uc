//=============================================================================
// SDKModLibrary
//
// The base a mod's own script library extends, so the SDK can identify it the same
// way it identifies a manifest -- by THIS parent, read straight out of the cooked
// .u. A mod declares ONE class extending this, with `static final function` stubs,
// and its DLL supplies the C++ behind them (OL_NATIVE). After the .u loads, the SDK
// binds each native to this class -- only here, and only to static final functions,
// so nothing else can be repointed through it.
//
// OutlastSDKLibrary, the SDK's own surface, extends this too; but the SDK's natives
// bind to OutlastSDKLibrary specifically. This base carries none of them itself.
//
// Extend it DIRECTLY, and keep to one such class per mod.
//=============================================================================
class SDKModLibrary extends Object
	abstract;