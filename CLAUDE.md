# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Lightroom Classic plugin (Lua) that syncs photos between Lightroom and an Immich server via the Immich REST API. It provides Export, Publish Service, and Import from Immich workflows.

## No traditional build step

There is no compile step. The plugin is the `immich-plugin.lrplugin/` directory loaded directly by Lightroom. To test changes, reload the plugin in Lightroom's Plugin Manager or restart Lightroom.

**Releases** are created manually via GitHub Actions (`.github/workflows/release.yml`): the workflow zips `immich-plugin.lrplugin/` and publishes a GitHub Release.

## Local Lua environment

`lua_env/` contains a local Lua 5.1 (LuaJIT) installation built with `hererocks` (`.venv/`). It is gitignored and not used at runtime — Lightroom provides its own Lua interpreter. It can be used for local syntax checks:

```bash
source lua_env/bin/activate
lua immich-plugin.lrplugin/util.lua   # quick syntax check (no LR APIs available)
```

## Plugin architecture

All plugin source lives in `immich-plugin.lrplugin/`. Entry points are declared in `Info.lua`:

| Entry point | File |
|---|---|
| Plugin init | `Init.lua` |
| Export service | `ExportServiceProvider.lua` → `ExportDialogSections.lua` + `ExportTask.lua` |
| Publish service | `PublishServiceProvider.lua` → `PublishDialogSections.lua` + `PublishTask.lua` |
| Import menu items | `ImportDialog.lua` + `ImportConfiguration.lua` → `ImportServiceProvider.lua` |
| Custom metadata | `MetadataProvider.lua` + `MetadataTask.lua` |
| Plugin info/prefs | `PluginInfo.lua` + `PluginInfoDialogSections.lua` |

### Global setup (`Init.lua`)

`Init.lua` is the only file that calls `import 'Lr*'` for all Lightroom SDK namespaces. Every other file accesses these as globals: `LrHttp`, `LrTasks`, `LrDialogs`, `LrView`, `LrApplication`, etc. It also sets up `_G.log`, `_G.prefs`, `_G.JSON`, and `_G.inspect`.

### Core modules

- **`ImmichAPI.lua`** — Lua class (OO via metatable) wrapping the Immich REST API. Instantiated as `ImmichAPI:new(url, apiKey)`. HTTP calls go through `doGetRequest`, `doPostRequest`, `doCustomRequest`, `doMultiPartPostRequest`. All methods check connectivity before sending. Errors are silent (returns `nil, errReason`) during batch operations to avoid modal dialogs per photo.

- **`StackManager.lua`** — Handles the "upload original alongside export" stacking feature. Detects edited photos via Lightroom catalog queries (`hasAdjustments`, `cropped`). Builds a cache of edited photo IDs before export for efficiency.

- **`UploadHelpers.lua`** — Shared upload utilities: temp file cleanup, sort order for original+export pairs, and applying Lightroom stack metadata to Immich stacks.

- **`SharedDialogSections.lua`** — UI sections reused by both Export and Publish dialogs: server connection fields (URL + API key + test button) and the original-file/stacking options panel with live observers.

- **`MetadataTask.lua`** — Reads/writes the `immichAssetId` custom metadata field on Lightroom photos (backed by `MetadataProvider.lua`). Used to skip the Immich existence search on repeat exports.

- **`util.lua`** — Stateless helpers: `util.nilOrEmpty`, `util.getPhotoDeviceId` (UUID → localIdentifier fallback), `util.validateExportContextAndConnect`, `util.reportUploadFailuresAndWarnings`, etc.

- **`ErrorHandler.lua`** — Presents a two-row modal (summary + detail) and always logs via `log:error`.

- **`JSON.lua`** / **`inspect.lua`** — Third-party libraries (Jeffrey Friedl / Enrique García Cota), not to be modified.

### Export vs Publish distinction

Export (`ExportTask.lua`) and Publish (`PublishTask.lua`) share the same upload logic but differ in lifecycle:

- **Export**: one-shot. Album resolved at export time; orphan albums deleted if all uploads fail.
- **Publish**: Lightroom manages published photo IDs via `rendition:recordPublishedPhotoId`. In publish mode, disk originals are **not** uploaded for the `stackOriginalExport` path when only one rendition arrives — they would become untracked orphans because Lightroom only cleans up assets registered with `recordPublishedPhotoId`.

### Duplicate detection

`ImmichAPI:checkIfAssetExistsEnhanced` runs a three-step search: (1) LR metadata field, (2) Immich `/search/metadata` by `deviceAssetId` (UUID), (3) fallback by filename + creation date. The `deviceAssetId` stored in Immich is the photo's UUID (stable across catalog re-imports), with `_export`, `_orig`, `_edited` suffixes for stacked variants.

### Lightroom SDK conventions

- All blocking operations must run inside `LrTasks.startAsyncTask` or be called from a task context. Use `LrTasks.pcall` (not bare `pcall`) for error-safe calls inside async tasks.
- UI observers use `propertyTable:addObserver('key', fn)`.
- Catalog writes require `catalog:withWriteAccessDo` or `catalog:withPrivateWriteAccessDo`.
- Progress reporting uses `LrProgressScope` tied to `functionContext` (not `exportContext:configureProgress`) so the bar stays alive until all uploads finish.

## Logging

Enable via Plugin Manager → Immich → "Enable logging". Log file location:
- **LR14+**: `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/ImmichPlugin.log` (macOS)
- **LR<14**: `~/Documents/LrClassicLogs/ImmichPlugin.log` (macOS)

Use `log:trace(...)`, `log:info(...)`, `log:warn(...)`, `log:error(...)` — all gate on the `prefs.logging` flag.
