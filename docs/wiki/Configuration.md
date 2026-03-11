## Configuration

Once the plug‑in is installed, configure it via **File → Plug‑in Manager…**.

Select `lrc-immich-plugin` and open the plug‑in’s configuration dialog.

---

### Immich URL

- Set the **Immich URL** to the base URL of your Immich instance, e.g.:
  - `https://immich.example.com`
  - `https://photos.mydomain.tld`
- Make sure the URL is reachable from the machine running Lightroom.

---

### API Key

Create an API key from your Immich user account and paste it into the plug‑in’s **API Key** field.

The plug‑in expects a key with permissions to:

- Read and write assets
- Create and manage albums and album assets
- Read user information (for basic identity checks)
- Create stacks (for stacked images)

If you want a minimal permission set, use the same ones listed in the repository README under “Requirements”.

After saving, the plug‑in can validate connectivity using the provided URL and key; if validation fails, double‑check your URL, key, and permissions.

---

### Import path

- Choose a local folder where assets downloaded from Immich will be stored.
- This is typically a temporary holding area before assets are imported into your Lightroom catalog.
- Ensure the folder:
  - Is on a drive with enough free space.
  - Is regularly cleaned up if you keep original downloads.

---

### Import batch size

The plug‑in downloads album assets in parallel to speed up imports:

- **Import batch size** controls how many download jobs run at the same time.
- It must be a positive integer (≥ 1).  
- If the value is invalid or empty, the plug‑in falls back to a default of **5**.

Recommendations:

- Start with the default (**5**) and adjust if:
  - Your network or Immich server can handle more parallel traffic → increase.
  - Your machine or network becomes sluggish → decrease.

---

### Saving settings

Click **Save** (or the equivalent button in the dialog) to persist the configuration:

- URL, API key, import path, and import batch size are stored in Lightroom’s plug‑in preferences.
- Changes take effect the next time you run an export/publish/import operation using the plug‑in.

