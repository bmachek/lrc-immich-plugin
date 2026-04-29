# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Lightroom Classic plugin (Lua) that synchronizes photos with an Immich server. It provides three workflows: **Export** (upload selected photos), **Publish** (maintain synced collections), and **Import** (download albums from Immich into Lightroom).

## Development & Build

There is no build step — the plugin runs directly from `immich-plugin.lrplugin/` inside Lightroom Classic. Install it via Lightroom's Plugin Manager pointing at that directory.

**Releasing** is done via GitHub Actions (`workflow_dispatch` on `.github/workflows/release.yml`), which zips the plugin folder and creates a GitHub release.

**Testing** is manual: load the plugin in Lightroom Classic and exercise the Export/Publish/Import workflows. Logs are written to Lightroom's log directory; toggle via `_G.prefs.logging` in plugin preferences.

## Architecture

### Entry Points

- **`Info.lua`** — Plugin manifest; declares export providers, menu items, metadata provider, SDK version.
- **`Init.lua`** — Runs at load; imports Lightroom SDK globals into `_G` (`LrHttp`, `LrTasks`, `LrDialogs`, etc.) and initializes preferences.

### Core Workflow Modules

- **`ImmichAPI.lua`** — REST API client. Instantiated with `ImmichAPI:new(url, apiKey)`. All HTTP calls go through here using `LrHttp`. 300s timeout for uploads, 30s otherwise. Uses `x-api-key` header.
- **`ExportTask.lua`** — Export workflow: album resolution → render → upload → metadata write.
- **`PublishTask.lua`** — Publish workflow: incremental sync, collection management, deletion.
- **`ImportServiceProvider.lua`** / **`ImportDialog.lua`** — Import workflow: album selection → batched download.
- **`StackManager.lua`** — Detects edited photos (`hasAdjustments` + `cropped`), uploads originals alongside exports, creates Immich stacks.
- **`UploadHelpers.lua`** — Shared upload utilities: temp file cleanup (`safeDeleteTempFile`), original/export sorting.

### UI Modules

- **`SharedDialogSections.lua`** — Reusable dialog sections (server connection, original file options, edit detection). Bind to `propertyTable` and set up observers.
- **`ExportDialogSections.lua`** / **`PublishDialogSections.lua`** — Extend SharedDialogSections for their respective workflows.

### Supporting Modules

- **`MetadataTask.lua`** / **`MetadataProvider.lua`** — Store/expose Immich asset IDs on photos via plugin metadata (`photo:setPropertyForPlugin`).
- **`util.lua`** — Table helpers, API key sanitization, edit detection, file extension checks, log path detection.
- **`ErrorHandler.lua`** — Centralized error dialogs.
- **`JSON.lua`** / **`inspect.lua`** — External libs for JSON encode/decode and debug printing.

### Lightroom SDK Patterns Used Throughout

- **Async tasks**: All API calls and heavy operations run in `LrTasks.startAsyncTask()`.
- **Property tables**: Dialog state is two-way bound via `LrBinding` to a `propertyTable`.
- **Progress scopes**: `LrProgressScope` for cancelable multi-step operations.
- **Error handling**: `LrTasks.pcall()` (not bare `pcall`) is used everywhere to stay compatible with Lightroom's coroutine-based task system.
- **Preferences**: Global settings (`url`, `apiKey`, `logging`, `importPath`, `importBatchSize`) stored in `LrPrefs.prefsForPlugin()`.

### Key Data Flow

1. Dialog opens → `SharedDialogSections` initializes `ImmichAPI`, binds UI to `propertyTable`.
2. User starts export/publish → `ExportTask`/`PublishTask` iterates renditions.
3. Per photo: `StackManager` detects edits → `UploadHelpers` sorts originals/exports → `ImmichAPI` uploads and creates stacks → `MetadataTask` writes asset IDs back to the photo.

### Album Modes

Export supports modes: `none`, `existing`, `new`, `folder` (dynamic per-folder album), `onexport`. Publish uses Lightroom collection IDs mapped to Immich album IDs.

### Photo Identity

Photos are identified by UUID (stable across reimports) with fallback to `localIdentifier` for backward compatibility with older metadata.
