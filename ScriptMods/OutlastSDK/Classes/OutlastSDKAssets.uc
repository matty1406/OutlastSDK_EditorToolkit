//=============================================================================
// OutlastSDKAssets
//
// The SDK's own content: icons, logos and anything else it shows. Always loaded
// while the SDK is, so any mod or map can use it.
//
// USAGE from any mod script:
//     `class'OutlastSDKAssets'.default.DefaultMapIcon`
// or by path, e.g. in Flash:
//     `img://OutlastSDKContent.Icons.DefaultMap`
//=============================================================================
class OutlastSDKAssets extends Object
    abstract;

/** Shown in the Mods menu's Maps tab for a map without a thumbnail of its own. */
var const Texture2D DefaultMapIcon;

defaultproperties
{
    DefaultMapIcon=Texture2D'OutlastSDKContent.Icons.DefaultMap'
}