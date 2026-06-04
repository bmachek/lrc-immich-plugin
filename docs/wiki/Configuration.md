## Configuration

This page covers every setting exposed by the plug‑in, organized by where they appear.

---

### Immich Server Connection

These two fields are required for every workflow (Export, Publish, and Import).

| Setting | Description |
|---------|-------------|
| **URL** | Full base URL of your Immich server, e.g. `https://immich.example.com`. The plug‑in will auto‑correct common mistakes (missing scheme, trailing slash). Use **Test connection** to verify. |
| **API Key** | An Immich API key with sufficient permissions. See [API Key Permissions](#api-key-permissions) below. |

For **Export** and **Publish**, these are entered in the Export/Publish Service dialog.  
For **Import**, they are saved globally in plug‑in preferences (accessible via the Import configuration dialog or the plug‑in menu).

---

### API Key Permissions

Create a dedicated API key for this plug‑in under **Account Settings → API Keys** in your Immich web UI.

Enable the following scopes:

| Scope | Required for |
|-------|-------------|
| `asset.read` | All workflows |
| `asset.upload` | Export, Publish |
| `asset.replace` | Export, Publish |
| `asset.delete` | Publish (deletion sync) |
| `asset.download` | Import |
| `asset.update` | Export, Publish |
| `asset.copy` | Export, Publish |
| `album.read` | Album modes, Import |
| `album.create` | Album modes (new, folder) |
| `album.update` | Album modes |
| `album.delete` | Publish (album cleanup) |
| `albumAsset.create` | Adding photos to albums |
| `albumAsset.delete` | Removing photos from albums |
| `stack.create` | Original file stacking |
| `user.read` | Connection test |
| `activity.read` | General API access |

Using a dedicated key (rather than your main account key) limits blast radius if the key is ever exposed.

---

### Original File Behavior

Controls whether raw/original files are uploaded alongside the rendered export. Available in both Export and Publish dialogs.

| Option | Behavior |
|--------|----------|
| **Don't upload original files** | Only the rendered export (JPEG, TIFF, etc.) is uploaded. |
| **Upload originals for edited photos only** | Uploads the original file as well, but only for photos that have edits or crops applied in Lightroom. |
| **Upload originals for all photos** | Always uploads the original file alongside the export. |
| **Always upload original only (no export)** | Skips the rendered export entirely; only the original is sent. |
| **Always upload original + rendered export (if edited)** | Always sends the original; also sends the rendered export when the photo has edits. |

> **Tip:** Uploading originals preserves RAW data at the cost of extra storage and upload time.  
> **Warning:** If your export format is set to **Original** in Lightroom and you select an option that produces a separate export, the plug‑in will warn you because no distinct rendered file will be produced for stacking.

---

### Stack Options

Available alongside the Original File Behavior setting.

| Option | Behavior |
|--------|----------|
| **Stack Original + Export in Immich** | When both an original and an export are uploaded, the plug‑in creates an Immich stack with them. |
| **Preserve Lightroom stacks in Immich** | Mirrors existing Lightroom stacks into Immich stacks on upload. |

---

### Locked Folder

Uploaded assets can be placed in Immich's locked folder, which hides them from the main timeline and requires a PIN to view.

| Option | Behavior |
|--------|----------|
| **Don't use locked folder** | Assets are uploaded normally (default). |
| **Always upload to locked folder** | Every upload goes into the locked folder automatically. |
| **Ask on each run** | A prompt appears before each export or publish run asking whether to use the locked folder. |

---

### Album Options (Export only)

Controls how the plug‑in assigns uploaded photos to an Immich album during an Export operation. This section appears at the top of the Export dialog.

| Option | Behavior |
|--------|----------|
| **Choose on export** | A dialog prompts you to pick or create an album each time you run an export. |
| **Existing album** | Select a specific album from a dropdown populated with your Immich albums. |
| **Create new album** | Enter a name; the plug‑in creates a new album each export run. |
| **Create/use folder name as album** | Uses the Lightroom source folder name as the album name, creating the album if it doesn't exist. Useful for keeping folder‑based organization in sync. |
| **Do not use an album** | Photos are uploaded to Immich without being added to any album. |

For **Publish Services**, the album is determined by the Lightroom collection name when the service is set up.

---

### Import Settings

These settings appear in the **Import from Immich** configuration dialog, and are saved globally across sessions.

| Setting | Description |
|---------|-------------|
| **Import Path** | Local folder where downloaded assets are written. Defaults to `Pictures/Immich Import`. Use **Browse…** to choose a different location. |
| **Import Batch Size** | Number of assets downloaded in parallel. Default is `2`. Increase for faster imports on a fast network; decrease if you see timeouts or high memory usage. Must be a positive integer. |

---

### Plug‑in Preferences (Logging)

A **Logging** toggle is available in Lightroom's **Plug‑in Manager** under the plug‑in entry. When enabled, the plug‑in writes a log file to Lightroom's standard log directory. Disable it during normal use to avoid filling up disk space with log data.
