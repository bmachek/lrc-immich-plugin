# lrc-immich-plugin
[![Github All Releases](https://img.shields.io/github/downloads/bmachek/lrc-immich-plugin/total.svg)]()

Lightroom Classic plug‑in to upload and download photos between Lightroom Classic and an Immich server using the Immich API.  
Provides both **Export** and **Publish Services**, plus tools to **import assets from Immich back into Lightroom**.

> ℹ️ Full, always-up-to-date documentation: see the blog post  
> [lrc-immich-plugin on blog.fokuspunk.de](https://blog.fokuspunk.de/lrc-immich-plugin/)

---

## Features

- **Export to Immich**
  - Send selected photos from Lightroom Classic directly to your Immich server.
  - Uses the Immich API, so uploads go straight into your Immich library.

- **Publish Service integration**
  - Create a Lightroom Publish Service backed by Immich.
  - Keep Lightroom collections and Immich albums aligned via publish operations.

- **Import from Immich**
  - Download assets from Immich albums into a local folder.
  - Import those files into your Lightroom catalog for editing and management.

- **Safe upload handling**
  - Uses temporary files and cleans them up after uploads.
  - Skips failed renders and continues with the rest of the queue.

---

## Requirements

- **Lightroom Classic** on macOS or Windows.
- **Immich server** reachable from your machine.
- An **Immich API key** from your Immich account with the following permissions:
    - activity.read
    - asset.read
    - asset.upload
    - asset.replace
    - asset.delete
    - asset.download
    - asset.update
    - asset.copy
    - albumAsset.create
    - albumAsset.delete
    - album.read
    - album.create
    - album.delete
    - album.update
    - user.read
    - stack.create

---

## Installation

1. **Download the plug‑in**
   - Go to the project’s releases page on GitHub and download the latest version of `immich-plugin.lrplugin` (or the ZIP containing it).

2. **Install into Lightroom Classic**
   - Open Lightroom Classic.
   - Go to **File → Plug‑in Manager…**
   - Click **Add…** and select the `immich-plugin.lrplugin` folder.
   - Confirm that the plug‑in loads without errors.

---

## Configuration

Open **File → Plug‑in Manager…**, select `lrc-immich-plugin`, and click the configuration button to open the plug‑in’s dialog.

- **Immich URL**
  - Base URL of your Immich instance, e.g. `https://immich.example.com`.

- **API Key**
  - Create an API key in your Immich user account.
  - Paste the key into the plug‑in’s API key field.

- **Import path**
  - Local folder where downloaded Immich assets will be stored before/while importing into Lightroom.

- **Import batch size**
  - Number of parallel downloads when importing from Immich.
  - Must be a positive integer (≥ 1).  
  - If unset or invalid, the plug‑in falls back to `5`.

Click **Save** in the dialog to persist these settings.

---

## Usage

### Export to Immich

1. Select the photo(s) you want to send to Immich.
2. Choose **File → Export…** and pick the Immich export preset provided by the plug‑in.
3. Adjust export settings as desired (format, size, etc.).
4. Start the export to upload the rendered files to your Immich server.

### Publish to Immich

1. In the **Publish Services** panel, create a new Immich Publish Service (if not already configured).
2. Create one or more publish collections that map to Immich albums.
3. Drag photos into these collections.
4. Use **Publish** to send new and updated photos to Immich.

### Import from Immich

1. Open the plug‑in’s **Import from Immich** dialog (see full docs on the blog for the exact menu entry).
2. Choose the album (or assets) you want to download.
3. Confirm the target **import path**.
4. Start the import; assets are downloaded in batches (respecting your **import batch size**), then made available for import into Lightroom.

For more detailed, step‑by‑step screenshots and advanced usage, see the blog documentation linked above.

---

## Documentation

Please visit the blog for full documentation, screenshots, and tips:

- [lrc-immich-plugin on blog.fokuspunk.de](https://blog.fokuspunk.de/lrc-immich-plugin/)

---

## Credits

- **All contributors** to this project.
- [Jeffrey Friedl for `JSON.lua`](http://regex.info/blog/lua/json)
- [Enrique García Cota for `inspect.lua`](https://github.com/kikito/inspect.lua)
- [Min Idzelis for giving ideas with his Immich Plug‑in](https://github.com/midzelis/mi.Immich.Publisher)

---

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=bmachek/lrc-immich-plugin&type=Date)](https://www.star-history.com/#bmachek/lrc-immich-plugin&Date)