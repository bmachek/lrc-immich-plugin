# Lightroom Classic SDK Plugin Development Skill

You are an expert in Adobe Lightroom Classic plugin development using the Lua-based SDK (version 15.3, build 202604090947). Apply this knowledge proactively when the user writes or asks about `.lua` files, `.lrdevplugin` bundles, or `Info.lua` in this repository.

---

## SDK Fundamentals

- **Language**: Lua (runs inside Lightroom's embedded interpreter)
- **Import pattern**: `local LrDialogs = import 'LrDialogs'`
- **Plugin bundle**: a directory named `<name>.lrdevplugin` containing `Info.lua` plus Lua scripts
- **SDK version**: 15.3 (LrSdkVersion = 15.3, LrSdkMinimumVersion = 1.3 minimum)
- **Threading model**: cooperative coroutines on Lightroom's single UI thread — use `LrTasks` for async work; many catalog operations require an async task context

---

## Plugin Structure — Info.lua

```lua
return {
    LrSdkVersion = 15.3,
    LrSdkMinimumVersion = 1.3,
    LrToolkitIdentifier = 'com.yourcompany.pluginname',  -- reverse-DNS, unique
    LrPluginName = LOC "$$$/Plugin/Name=My Plugin",
    LrPluginInfoUrl = "https://yoursite.com",

    -- Menu items (choose one or more entry points):
    LrExportMenuItems = {           -- File > Export menu
        title = "My Export Item",
        file = "MyScript.lua",
    },
    LrLibraryMenuItems = {          -- Library > Plugin Extras menu
        { title = "Action One", file = "Action1.lua" },
        { title = "Action Two", file = "Action2.lua" },
    },
    LrExportServiceProvider = {     -- defines an Export/Publish service
        title = "My Service",
        file = "MyServiceProvider.lua",
    },
    LrMetadataProvider = "MyMetadataDefinition.lua",  -- custom metadata fields
    LrMetadataTagsetFactory = "MyTagsetProvider.lua", -- metadata panel filters

    VERSION = { major=15, minor=3, revision=0, build="202604090947-8f3672ed" },
}
```

---

## Critical Patterns

### Async Task (required for most catalog operations)
```lua
local LrTasks = import 'LrTasks'
LrTasks.startAsyncTask(function()
    -- your code here — yield is now available
    LrTasks.yield()  -- let other tasks run
    LrTasks.sleep(0.5)  -- delay in seconds
end)
```

### Write Access Gate (required to modify catalog)
```lua
local LrApplication = import 'LrApplication'
local catalog = LrApplication.activeCatalog()

LrTasks.startAsyncTask(function()
    catalog:withWriteAccessDo("Undo Step Name", function()
        -- all catalog mutations go here
        -- catalog:addPhoto(), photo:setRawMetadata(), etc.
    end)
end)
```

### Function Context (resource cleanup / error handling)
```lua
local LrFunctionContext = import 'LrFunctionContext'
LrFunctionContext.callWithContext("myAction", function(context)
    LrDialogs.attachErrorDialogToFunctionContext(context)
    -- context cleans up observers, etc. when block exits
end)
```

### UI Binding Pattern
```lua
local LrBinding = import 'LrBinding'
local LrView    = import 'LrView'
LrFunctionContext.callWithContext("dialog", function(context)
    local props = LrBinding.makePropertyTable(context)
    props.myValue = "default"
    local f = LrView.osFactory()
    local contents = f:column {
        bind_to_object = props,
        f:edit_field { value = LrView.bind("myValue") },
        f:static_text { title = LrView.bind("myValue") },
    }
    LrDialogs.presentModalDialog { title = "My Dialog", contents = contents }
end)
```

---

## All SDK Modules

### LrApplication (Namespace)
Access: `local LrApp = import 'LrApplication'`

| Function | Signature | Returns |
|---|---|---|
| activeCatalog | `()` | `LrCatalog` |
| addDevelopPresetForPlugin | `(plugin, presetName, presetValue)` | `LrDevelopPreset` |
| addHapticObserver | `(functionContext, observer, callback)` | nil |
| appStoreReceiptHash | `()` | string or nil |
| backupAtNextShutdown | `(pluginId)` | — |
| developPresetByUuid | `(uuid)` | `LrDevelopPreset` |
| developPresetFolders | `()` | array of `LrDevelopPresetFolder` |
| filenamePresets | `()` | table {name → uuid} |
| getDevelopPresetsForPlugin | `(plugin, uuid?)` | `LrDevelopPreset` or array |
| macAddressHash | `()` | string |
| metadataPresets | `()` | table {name → uuid} |
| purchaseSource | `()` | "retail" \| "MAS" \| "CC" |
| serialNumberHash | `()` | string |
| shutdown | `()` | — (SDK 14.3+) |
| versionString | `()` | string e.g. "15.3" |
| versionTable | `()` | {major, minor, revision, build_version, …} |
| viewFilterPresets | `()` | table, string? |

---

### LrCatalog (Class)
Get via: `LrApplication.activeCatalog()`

**Read operations** (require async task):
| Method | Signature | Returns |
|---|---|---|
| getAllPhotos | `()` | array of `LrPhoto` |
| getTargetPhoto | `()` | `LrPhoto` or nil |
| getTargetPhotos | `()` | array of `LrPhoto` |
| getMultipleSelectedOrAllPhotos | `()` | array of `LrPhoto` |
| findPhotoByPath | `(path, caseSensitivity?)` | `LrPhoto` or nil |
| findPhotoByUuid | `(uuid)` | `LrPhoto` or nil |
| findPhotos | `(args)` | array of `LrPhoto` |
| findPhotosWithProperty | `(pluginId, fieldName, version?)` | array of `LrPhoto` |
| getActiveSources | `()` | array |
| getChildCollections | `()` | array of `LrCollection` |
| getChildCollectionSets | `()` | array of `LrCollectionSet` |
| getCollectionByLocalIdentifier | `(id)` | `LrCollection` or `LrCollectionSet` |
| getFolders | `()` | array of `LrFolder` |
| getFolderByPath | `(path)` | `LrFolder` |
| getKeywords | `()` | array of `LrKeyword` |
| getKeywordsByLocalId | `(ids)` | array of `LrKeyword` |
| getLabelMapToColorName | `()` | table {color → label} |
| getPath | `()` | string (.lrcat path) |
| getPropertyForPlugin | `(plugin, fieldId)` | string or nil |
| getPublishServices | `(pluginId?)` | array of `LrPublishService` |
| getPublishedCollectionByLocalIdentifier | `(id)` | LrPublishedCollection |
| getCurrentViewFilter | `()` | table, presetName? |
| getPhotosAvailableForEditing | `(photos)` | available[], locked[] (SDK 15.3) |
| batchGetFormattedMetadata | `(photos, keys?)` | table [photo → {key → val}] |
| batchGetRawMetadata | `(photos, keys?)` | table [photo → {key → val}] |
| batchGetPropertyForPlugin | `(photos, plugin, fieldIds)` | table |

**Write operations** (require withWriteAccessDo gate):
| Method | Signature | Returns |
|---|---|---|
| addPhoto | `(path, stackWith?, position?, metaPresetUUID?, devPresetUUID?)` | `LrPhoto` |
| createCollection | `(name, parent?, canReturnPrior?)` | `LrCollection` or nil |
| createCollectionSet | `(name, parent?, canReturnPrior?)` | `LrCollectionSet` or nil |
| createSmartCollection | `(name, searchDesc, parent?, canReturnPrior?)` | `LrCollection` |
| createKeyword | `(name, synonyms, includeOnExport, parent?, returnExisting?)` | `LrKeyword` |
| createVirtualCopies | `(copyName?)` | array of `LrPhoto` |
| setActiveSources | `(sources)` | boolean |
| setSelectedPhotos | `(activePhoto, otherPhotos?)` | — |
| setViewFilter | `(filter)` | — |
| setPropertyForPlugin | `(plugin, fieldId, value)` | — |
| applyDevelopPreset | `(photos, preset, plugin?, amount?, updateAI?)` | — |
| pasteSettings | `(photos, updateAI?)` | boolean (SDK 15.3) |
| deleteAllEmptyMasks | `(photos)` | — (SDK 14.0) |
| updateAISettings | `(photos)` | — |
| buildSmartPreviews | `(photos)` | {created, existed, failed} |

**Write access gates:**
- `catalog:withWriteAccessDo(actionName, func, timeoutParams?)` — standard write access, creates undo step
- `catalog:withProlongedWriteAccessDo(params, func, timeoutParams?)` — extended write access for large operations
- `catalog:withPrivateWriteAccessDo(func, timeoutParams?)` — private write for plugin-only fields
- `catalog.hasWriteAccess` — boolean property
- `catalog.hasPrivateWriteAccess` — boolean property

**Catalog constants:**
- `catalog.kAllPhotos` — "All Photographs" source
- `catalog.kPreviousImport` — Previous Import source
- `catalog.kQuickCollectionIdentifier` — Quick Collection source
- `catalog.kTargetCollection` — current target collection
- `catalog.kTemporaryImages` — Temporary Images source
- `catalog.kLastCatalogExport` — Last Catalog Export source

**findPhotos criteria** (searchDesc):
- `criteria`: "rating", "pick", "labelColor", "labelText", "folder", "collection", "all", "filename", "copyname", "fileFormat", "metadata", "title", "caption", "keywords", "iptc", "exif", "captureTime", "touchTime", "camera", "cameraSN", "lens", "isoSpeedRating", "hasGPSData", "country", "state", "city", "location", "creator", "jobIdentifier", "copyrightState", "hasAdjustments", "developPreset", "treatment", "cropped", "aspectRatio", "allPluginMetadata"
- `operation` (string): "any","all","words","noneOf","beginsWith","endsWith","empty","notEmpty","==","!=",">=","<=",">","<","in","isTrue","isFalse","inLast","notInLast","today","yesterday","thisWeek","thisMonth","thisYear"
- `combine`: "union" | "intersect" | "exclude"
- `sort`: "captureTime" (default) | "fileName" | "extension"

---

### LrPhoto (Class)

**Read methods** (async task context):
| Method | Signature | Notes |
|---|---|---|
| getRawMetadata | `(key)` | unformatted values |
| getFormattedMetadata | `(key)` | display strings |
| getPropertyForPlugin | `(plugin, fieldId, version?, noThrow?)` | plugin-specific metadata |
| getDevelopSettings | `()` | full develop settings table (experimental) |
| getDevelopSnapshots | `()` | array of {snapshotID, name, id_global} |
| getContainedCollections | `()` | array of `LrCollection` |
| getContainedPublishedCollections | `()` | array of `LrPublishedCollection` |
| checkPhotoAvailability | `()` | boolean |
| isAvailableForEditing | `()` | boolean (SDK 15.3) |
| needsUpdateAISettings | `()` | boolean (SDK 15.3) |
| getNameViaPreset | `(presetId, customString, seqNum)` | string |
| requestJpegThumbnail | `(width, height, callback)` | async |
| copySettings | `()` | boolean (SDK 10.3) |

**Write methods** (require write access gate):
| Method | Signature | Notes |
|---|---|---|
| setRawMetadata | `(key, value)` | set writable metadata |
| setPropertyForPlugin | `(plugin, fieldId, value, version?)` | plugin metadata |
| addKeyword | `(keyword)` | |
| removeKeyword | `(keyword)` | |
| applyDevelopPreset | `(preset, plugin?, amount?, updateAI?)` | SDK 3.0, updated 15.3 |
| applyDevelopSettings | `(settings, historyName?, flattenAutoNow?)` | |
| applyDevelopSnapshot | `(id)` | |
| applyMetadataPreset | `(presetId)` | |
| createDevelopSnapshot | `(name, updateInPlace)` | boolean |
| deleteDevelopSnapshot | `(id)` | |
| deleteSmartPreview | `()` | "deleted" \| "failed" |
| buildSmartPreview | `()` | "created" \| "existed" \| "failed" |
| pasteSettings | `(updateAI?)` | boolean (SDK 10.3) |
| rotateLeft | `()` | |
| rotateRight | `()` | |
| quickDevelopAdjustImage | `(settingName, size)` | SDK 7.4 |
| quickDevelopAdjustWhiteBalance | `(settingName, amount)` | |
| quickDevelopSetWhiteBalance | `(value)` | |
| quickDevelopSetTreatment | `(value)` | "color"\|"grayscale" |
| quickDevelopCropAspect | `(aspectRatio)` | "original"\|"asshot"\|{w,h} |
| updateAISettings | `()` | SDK 15.3 |

**Other:**
| Method | Notes |
|---|---|
| addOrRemoveFromTargetCollection | `(include_selected?)` SDK 7.4 |
| openExportDialog | SDK 7.4 |
| openExportWithPreviousDialog | SDK 7.4 |

**Properties:**
- `photo.catalog` → `LrCatalog`
- `photo.localIdentifier` → number

**getRawMetadata keys** (selection):
`fileSize`, `rating`, `dimensions`, `croppedDimensions`, `shutterSpeed`, `aperture`, `exposureBias`, `flash`, `isoSpeedRating`, `focalLength`, `focalLength35mm`, `dateTimeOriginal`, `dateTimeDigitized`, `dateTime`, `dateTimeOriginalISO8601`, `dateTimeDigitizedISO8601`, `dateTimeISO8601`, `gps`, `gpsAltitude`, `gpsImgDirection`, `fileFormat`, `width`, `height`, `aspectRatio`, `isCropped`, `lastEditTime`, `editCount`, `copyrightState`, `uuid`, `path`, `isVideo`, `durationInSeconds`, `keywords`, `customMetadata`, `pickStatus`, `countVirtualCopies`, `virtualCopies`, `masterPhoto`, `isVirtualCopy`, `colorNameForLabel`, `countStackInFolderMembers`, `stackInFolderMembers`, `isInStackInFolder`, `stackInFolderIsCollapsed`, `stackPositionInFolder`, `smartPreviewInfo`, `bitDepth`, `isExported`, `altTextAccessibility`, `extDescrAccessibility`

**setRawMetadata writable keys:**
`rating`, `label`, `title`, `caption`, `copyright`, `copyrightState`, `creator`, `city`, `stateProvince`, `country`, `isoCountryCode`, `location`, `headline`, `instructions`, `keywords`, `pickStatus`, `colorNameForLabel`, `gps` (table {latitude, longitude}), `gpsAltitude`, `gpsImgDirection`, `altTextAccessibility`, `extDescrAccessibility`

---

### LrDevelopController (Namespace)
Access: `local LrDC = import 'LrDevelopController'`

**Slider control:**
- `getValue(param)` → number
- `setValue(param, value)` — requires write access
- `increment(param, withClippingOn?)` / `decrement(param, withClippingOn?)`
- `getRange(param)` → min, max
- `resetAllDevelopAdjustments()`
- `resetCrop()`, `resetBrushing()`, `resetHealing()`, `resetGradient()`, `resetCircularGradient()`, `resetRedeye()`, `resetMasking()`

**Tools:**
- `getSelectedTool()` → string
- `goToHealing()`, `goToSpotRemoval()`, `goToMasking()`, `goToRemove(spotType?, whichFeature?)`
- `goToDevelopGraduatedFilter()`, `goToDevelopRadialFilter()`
- `goToEyeCorrection(eyeCorrectionType?)`, `editInPhotoshop()`

**Masking (SDK 11+):**
- `getAllMasks()`, `getSelectedMask()`, `getSelectedMaskTool()`
- `createNewMask(maskType, maskSubtype?)`, `addToCurrentMask(maskType, maskSubtype?)`, `intersectWithCurrentMask(maskType, maskSubtype?)`
- `deleteMask(id, param?)`, `invertMask(id, param?)`, `duplicateAndInvertMask(id, param?)`

**AI features (SDK 15+):**
- `detectDistractingPeople()` / `applyRemovalOnDetectedDistractingPeople(callback, argTable?)`
- `changeDenoiseAmount(amount)`, `changeReflectionRemovalAmount(amount)`, `changeReflectionRemovalQuality(quality, callback, argTable?)`
- `getEnhancePanelState()`, `getReflectionRemovalPanelState()`

**Point Colors:**
- `addPointColorSwatch(swatchTable, isForMasking?)`, `deletePointColorSwatch(deleteAll, deleteAtIndex, isForMasking?)`
- `getSelectedPointColorSwatchIndex(isForMasking?)`

**Remove tool:**
- `getAllSpots(whichFeature?)`, `countAllSpots(whichFeature?)`
- `getSelectedSpotIndex(whichFeature?)`, `getSelectedSpotParams(whichFeature?)`
- `getSelectedSpotType()`, `deleteSelectedSpot(whichFeature?)`, `refreshSelectedSpot(whichFeature?)`
- `moveSelectedSpot(left, up, hUnits, vUnits, moveSrc?)`, `deleteSelectedVariation(whichFeature?)`, `gotoNextVariation(whichFeature?)`, `gotoPreviousVariation(whichFeature?)`

**Observers:**
- `addAdjustmentChangeObserver(functionContext, observer, callback)` — fires whenever Develop adjustments change

**Develop Parameters (complete list for getValue/setValue/increment/decrement):**

*adjustPanel:* Temperature, Tint, Exposure, Highlights, Shadows, Brightness, Contrast, Whites, Blacks, Texture, Clarity, Dehaze, Vibrance, Saturation, PresetAmount, ProfileAmount

*tonePanel:* ParametricDarks, ParametricLights, ParametricShadows, ParametricHighlights, ParametricShadowSplit, ParametricMidtoneSplit, ParametricHighlightSplit, ToneCurve, ToneCurvePV2012, ToneCurvePV2012Red, ToneCurvePV2012Blue, ToneCurvePV2012Green, CurveRefineSaturation

*mixerPanel:* SaturationAdjustment{Red,Orange,Yellow,Green,Aqua,Blue,Purple,Magenta}, HueAdjustment{same}, LuminanceAdjustment{same}, GrayMixer{same}, PointColors

*colorGradingPanel:* SplitToningShadowHue, SplitToningShadowSaturation, ColorGradeShadowLum, SplitToningHighlightHue, SplitToningHighlightSaturation, ColorGradeHighlightLum, ColorGradeMidtoneHue, ColorGradeMidtoneSat, ColorGradeMidtoneLum, ColorGradeGlobalHue, ColorGradeGlobalSat, ColorGradeGlobalLum, SplitToningBalance, ColorGradeBlending

*detailPanel:* Sharpness, SharpenRadius, SharpenDetail, SharpenEdgeMasking, LuminanceSmoothing, LuminanceNoiseReductionDetail, LuminanceNoiseReductionContrast, ColorNoiseReduction, ColorNoiseReductionDetail, ColorNoiseReductionSmoothness

*effectsPanel:* PostCropVignetteAmount, PostCropVignetteMidpoint, PostCropVignetteFeather, PostCropVignetteRoundness, PostCropVignetteStyle, PostCropVignetteHighlightContrast, GrainAmount, GrainSize, GrainFrequency

*lensCorrectionsPanel:* AutoLateralCA, LensProfileEnable, LensProfileDistortionScale, LensProfileVignettingScale, LensManualDistortionAmount, DefringePurpleAmount, DefringePurpleHueLo, DefringePurpleHueHi, DefringeGreenAmount, DefringeGreenHueLo, DefringeGreenHueHi, VignetteAmount, VignetteMidpoint, PerspectiveVertical, PerspectiveHorizontal, PerspectiveRotate, PerspectiveScale, PerspectiveAspect, PerspectiveX, PerspectiveY, PerspectiveUpright

*lensBlurPanel:* LensBlurActive, LensBlurAmount, LensBlurCatEye, LensBlurHighlightsBoost, LensBlurFocalRange

*Crop:* straightenAngle

*Localized Adjustments (local_…):* Temperature, Tint, Exposure, Contrast, Highlights, Shadows, Clarity, Saturation, ToningHue, ToningSaturation, Sharpness, LuminanceNoise, Moire, Defringe, Blacks, Whites, Dehaze, PointColors, Texture, Hue, Amount, Maincurve, Redcurve, Greencurve, Bluecurve, Grain, RefineSaturation

---

### LrDialogs (Namespace)
Access: `local LrDialogs = import 'LrDialogs'`

| Function | Signature | Returns |
|---|---|---|
| message | `(message, info?, style?)` | — (style: "warning"\|"info"\|"critical") |
| showError | `(errorString)` | — |
| confirm | `(message, info?, actionVerb?, cancelVerb?, otherVerb?)` | "ok"\|"cancel"\|"other" |
| messageWithDoNotShow | `(args)` | — (args: {message, info?, actionPrefKey}) |
| promptForActionWithDoNotShow | `(args)` | string |
| presentModalDialog | `(args)` | "ok"\|"cancel" (args: {title, contents, resizable?, …}) |
| presentFloatingDialog | `(plugin, args)` | (non-blocking, SDK 5.0) |
| showBezel | `(message, fadeDelay?)` | — (quick HUD) |
| showModalProgressDialog | `(params)` | — |
| stopModalWithResult | `(dialog, result)` | — |
| runOpenPanel | `(args)` | path string or nil |
| runSavePanel | `(args)` | path string or nil |
| attachErrorDialogToFunctionContext | `(context)` | — |
| resetDoNotShowFlag | `(actionPrefKey)` | — |

---

### LrView (Namespace/Class)
Access: `local LrView = import 'LrView'`; `local f = LrView.osFactory()`

**Factory methods (call on `f`):**
`f:row{}`, `f:column{}`, `f:stack{}`, `f:scrolled_view{}`, `f:view{}` (containers)
`f:static_text{}`, `f:edit_field{}`, `f:password_field{}`, `f:combo_box{}`
`f:checkbox{}`, `f:radio_button{}`, `f:push_button{}`, `f:popup_menu{}`
`f:slider{}`, `f:color_well{}`, `f:catalog_photo{}`, `f:picture{}`, `f:separator{}`

**Binding:**
- `LrView.bind("propertyName")` — binds control to property in bound table
- `LrView.bind({ key="prop", transform=function(v) return v end })` — with transform
- `LrView.negativeOfKey("prop")` — inverts boolean
- `LrView.store{}` — stores UI values to observable table

**Common control properties:**
- `value`, `enabled`, `visible`, `title`, `width`, `height`, `fill_horizontal`, `fill_vertical`
- `tooltip`, `font`, `text_color`, `background_color`
- `action = function(view) end` — for buttons/popup menus
- `items = { { title = "...", value = ... }, ... }` — for popup_menu/combo_box

---

### LrTasks (Namespace)
Access: `local LrTasks = import 'LrTasks'`

| Function | Signature | Notes |
|---|---|---|
| startAsyncTask | `(func, optName?)` | starts coroutine, shows error on failure |
| startAsyncTaskWithoutErrorHandler | `(func, optName?)` | starts coroutine, no auto error dialog |
| yield | `()` | yields to other tasks (must be in async task) |
| sleep | `(seconds)` | yields for at least N seconds |
| canYield | `()` → boolean | true if inside async task |
| pcall | `(func, ...)` → bool, ... | yield-safe pcall |
| execute | `(cmd)` → number | yield-safe os.execute |

---

### LrFunctionContext (Namespace/Class)
Access: `local LrFC = import 'LrFunctionContext'`

| Function | Signature | Notes |
|---|---|---|
| callWithContext | `(name, func)` | synchronous; passes context to func |
| postAsyncTaskWithContext | `(name, func)` | async; starts task with context |
| atexit | `(context, func)` | register cleanup on context exit |

---

### LrBinding (Namespace)
Access: `local LrBinding = import 'LrBinding'`

- `LrBinding.makePropertyTable(context)` → observable table (auto-cleans with context)
- `LrBinding.negativeOfKey(key)` → binding that inverts boolean
- Observable tables fire observers when any field changes

---

### LrPrefs (Namespace)
Access: `local LrPrefs = import 'LrPrefs'`

- `LrPrefs.prefsForPlugin(_PLUGIN)` → prefs table (persistent across sessions)
- Read/write like a normal Lua table: `prefs.myKey = "value"`

---

### LrLogger (Class/Namespace)
Access: `local LrLogger = import 'LrLogger'`

```lua
local myLogger = LrLogger('myLogName')
myLogger:enable("print")   -- or "logfile", or table of actions
myLogger:trace("message")
myLogger:info("message")
myLogger:warn("message")
myLogger:error("message")
```

---

### LrProgressScope (Class/Namespace)
```lua
local LrProgressScope = import 'LrProgressScope'
local scope = LrProgressScope({
    title = "Processing...",
    functionContext = context,  -- auto-cancel when context exits
})
scope:setPortionComplete(0.5)
scope:setCaption("Halfway there")
if scope:isCanceled() then return end
scope:done()
```

---

### LrHttp (Namespace)
Access: `local LrHttp = import 'LrHttp'`

- `LrHttp.get(url, headers?)` → body, headers
- `LrHttp.post(url, body, headers?, method?)` → body, headers
- `LrHttp.postMultipart(url, content, headers?)` → body, headers
- `LrHttp.openUrlInBrowser(url)` — open a URL in the default browser

---

### LrFileUtils (Namespace)
Access: `local LrFileUtils = import 'LrFileUtils'`

- `exists(path)` → "file" | "directory" | nil
- `delete(path)`, `move(src, dst)`, `copy(src, dst)`
- `readFile(path)` → string, `writeFile(path, data)`
- `directoryEntries(path)` → iterator
- `createTempFile(ext?)` → tempPath
- `isWritable(path)` → boolean
- `makeDirectory(path)`

---

### LrPathUtils (Namespace)
Access: `local LrPathUtils = import 'LrPathUtils'`

- `child(parent, leaf)` → path
- `parent(path)` → parent dir
- `leafName(path)` → filename with extension
- `removeExtension(filename)` → name without ext
- `extension(filename)` → ext string
- `addExtension(filename, ext)` → new path
- `isAbsolute(path)` → boolean
- `getStandardFilePath(type)` — type: "documents", "appData", "temp", etc.

---

### LrStringUtils (Namespace)
- `trimWhitespace(str)` → string
- `encodeUrl(str)` → URL-encoded
- `decodeUrl(str)` → decoded
- `encodeBase64(str)` → base64
- `decodeBase64(str)` → decoded
- `upper(str)`, `lower(str)` (locale-aware)
- `split(str, sep)` → array

---

### LrDate (Namespace)
- `LrDate.currentTime()` → seconds since epoch (Lightroom epoch: midnight GMT Jan 1 2001)
- `LrDate.timeFromComponents(year, month, day, hour, min, sec)` → number
- `LrDate.timeToUserFormat(time, format)` → formatted string
- `LrDate.timeToW3CDate(time)` → ISO 8601 string
- `LrDate.timeFromW3CDate(str)` → number

---

### LrSocket (Namespace)
Access: `local LrSocket = import 'LrSocket'`

Used for inter-process communication. See `remote_control_socket_example.lrdevplugin` sample.
- `LrSocket.bind(port, callback, timeout?)` — listen on port
- `LrSocket.send(host, port, data, timeout?)` — send data

---

### LrPasswords (Namespace)
- `LrPasswords.retrieve(serviceName, username)` → password or nil
- `LrPasswords.store(serviceName, username, password)` — uses OS keychain
- `LrPasswords.delete(serviceName, username)`

---

### LrShell (Namespace)
- `LrShell.openPathInShell(path)` — reveal in Finder/Explorer
- Note: to open a URL in the browser use `LrHttp.openUrlInBrowser(url)` — `LrShell` has no such method

---

### LrSystemInfo (Namespace)
- `LrSystemInfo.numCPUs()` → number
- `LrSystemInfo.memSize()` → bytes
- `LrSystemInfo.osVersion()` → string

---

### LrLocalization (Namespace)
- `LOC "$$$/Path/Key=Default String"` — translates using ZString
- Strings live in `TranslatedStrings.txt` files in the plugin bundle

---

### LrDigest (Namespace) — SHA256 / SHA512 (MD5/SHA1 deprecated)
```lua
local LrDigest = import 'LrDigest'
local hasher = LrDigest.SHA256.new()
hasher:addString("data")
local hash = hasher:digest()  -- also resets the hasher
```

---

### LrUndo (Namespace)
- `LrUndo.undo()`, `LrUndo.redo()`
- `LrUndo.canUndo()` → boolean, `LrUndo.canRedo()` → boolean

---

### LrApplicationView (Namespace)
- `LrApplicationView.getActiveModule()` → "library" | "develop" | "slideshow" | "print" | "web"
- `LrApplicationView.switchToModule(moduleName)`
- `LrApplicationView.showModule(moduleName)`

---

### LrSelection (Namespace)
- `LrSelection.getPhoto()`, `LrSelection.setSelectedPhotos()`
- `LrSelection.nextPhoto()`, `LrSelection.previousPhoto()`
- `LrSelection.flagSelected()`, `LrSelection.unflagSelected()`, `LrSelection.rejectSelected()`

---

### LrTether (Namespace) — Tethered Shooting
- `LrTether.isTetheredCaptureSessionRunning()` → boolean
- `LrTether.startTetheredCapture()`, `LrTether.stopTetheredCapture()`
- `LrTether.capturePhoto()`

---

### LrCollection (Class)
- `collection:getName()` → string
- `collection:getPhotos()` → array of `LrPhoto`
- `collection:addPhotos(photos)` — requires write access
- `collection:removePhotos(photos)` — requires write access
- `collection:delete()` — requires write access
- `collection.localIdentifier` → number
- `collection.catalog` → `LrCatalog`

---

### LrKeyword (Class)
- `keyword:getName()` → string
- `keyword:getParent()` → `LrKeyword` or nil
- `keyword:getChildren()` → array of `LrKeyword`
- `keyword:getPhotos()` → array of `LrPhoto`
- `keyword:getSynonyms()` → array of strings
- `keyword:setName(name)` — requires write access
- `keyword.localIdentifier` → number

---

### LrFolder (Class)
- `folder:getPath()` → string
- `folder:getName()` → string
- `folder:getParent()` → `LrFolder` or nil
- `folder:getChildren()` → array of `LrFolder`
- `folder:getPhotos()` → array of `LrPhoto`

---

### LrDevelopPreset (Class)
- `preset:getName()` → string
- `preset:getUuid()` → string
- `preset:getPath()` → string
- `preset:getSetting(key)` → value
- `preset:applyToPhoto(photo)` — use photo:applyDevelopPreset() instead

---

### Export Service Provider Hooks

The service definition script (referenced by `LrExportServiceProvider` in Info.lua) returns a table:

```lua
return {
    -- Required:
    processRenderedPhotos = function(functionContext, exportContext)
        for _, rendition in exportContext:renditions() do
            local success, pathOrMsg = rendition:waitForRender()
            if success then
                -- do something with pathOrMsg (the rendered file path)
            end
        end
    end,

    -- Dialog customization (optional):
    startDialog = function(propertyTable) end,
    endDialog = function(propertyTable, why) end,  -- why: "ok"|"cancel"|"changedServiceProvider"
    sectionsForTopOfDialog = function(f, propertyTable) return {} end,
    sectionsForBottomOfDialog = function(f, propertyTable) return {} end,
    updateExportSettings = function(exportSettings) end,

    -- Control dialog sections (optional):
    showSections = { 'imageSettings', 'exportLocation', 'fileNaming', 'metadata', 'watermarking', 'postProcessing', 'video' },
    hideSections = { ... },
    allowFileFormats = { 'JPEG', 'TIFF', 'DNG', 'PSD', 'PNG' },
    disallowFileFormats = { ... },
    allowColorSpaces = { 'sRGB', 'AdobeRGB', 'ProPhotoRGB' },
    canExportVideo = true,
    canExportToTemporaryLocation = false,
    hidePrintResolution = false,
    supportsIncrementalPublish = 'only',  -- "only" | false (for publish-only plugins)
    exportPresetFields = {
        { key = 'myField', default = 'defaultValue' },
    },
}
```

**ExportContext API:**
- `exportContext:renditions()` → iterator
- `exportContext.exportSettings` → property table
- `exportContext:destinationPath()` → string

**ExportRendition API:**
- `rendition:waitForRender()` → success, pathOrMessage
- `rendition.photo` → `LrPhoto`
- `rendition:recordFailure(msg)`

---

### Custom Metadata Definition

`LrMetadataProvider` script returns:
```lua
return {
    metadataFieldsForPhotos = {
        {
            id = 'myField',
            title = LOC "$$$/Plugin/MyField=My Field",
            dataType = 'string',   -- 'string' | 'number' | 'enum' | 'url' | 'boolean'
            searchable = true,
            browsable = false,
            readOnly = false,
        },
    },
    schemaVersion = 1,
    -- upgradeHandler = function(catalog, plugin, oldVersion, newVersion) end,
}
```

---

## Common Gotchas

1. **Write access required** — `photo:setRawMetadata()`, `photo:addKeyword()`, `catalog:createCollection()`, etc. must be called inside `withWriteAccessDo` or `withPrivateWriteAccessDo`.

2. **Async task required** — `catalog:getAllPhotos()`, `catalog:findPhotos()`, `photo:getFormattedMetadata()`, `photo:checkPhotoAvailability()` require `LrTasks.startAsyncTask`.

3. **No direct `require`** — use `import 'ModuleName'` instead of Lua's `require`.

4. **`_PLUGIN`** — a global table available in all plugin scripts that represents the current plugin. Use for `LrPrefs.prefsForPlugin(_PLUGIN)` and as the `plugin` argument in API calls.

5. **Develop settings are experimental** — `photo:getDevelopSettings()` contents may change between LrC versions.

6. **AI lock** — In SDK 15.3, `photo:isAvailableForEditing()` returns false when an AI operation is in progress. Check before editing. Also use `catalog:getPhotosAvailableForEditing(photos)` for batches.

7. **`LOC` for strings** — Always use `LOC "$$$/path=Default"` for user-visible strings to support localization.

8. **`LrFunctionContext.callWithContext`** is blocking; `LrFunctionContext.postAsyncTaskWithContext` is async. Use async for long operations.
