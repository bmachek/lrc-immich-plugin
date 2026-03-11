## Advanced options & Troubleshooting

### Advanced options

#### Import batch size tuning

The import batch size controls how many downloads are executed in parallel when importing from Immich:

- Default: **5** (if the configured value is missing or invalid).
- Higher values:
  - Can speed up imports on fast networks and servers.
  - Increase concurrent load on your machine and Immich.
- Lower values:
  - Reduce simultaneous download load.
  - Can help on slower hardware or unstable networks.

Change this value in the plug‑in’s configuration dialog, then re‑run imports to test the effect.

---

### Troubleshooting

#### Plug‑in does not appear in Lightroom

- Re‑open **File → Plug‑in Manager…** and verify that `lrc-immich-plugin` is listed.
- If it shows an error:
  - Remove the entry.
  - Re‑add the plug‑in from the `immich-plugin.lrplugin` folder.

#### Cannot connect to Immich

- Double‑check:
  - **Immich URL** (protocol, domain, path).
  - **API key** (no extra spaces; still valid; correct user).
- Confirm that the Immich server is reachable from your machine in a browser.
- Ensure the key has sufficient permissions for:
  - Reading/writing assets.
  - Managing albums and album assets.

#### Uploads fail for some photos

- Lightroom may fail to render certain images; the plug‑in skips failed renders but continues with the rest.
- Check Lightroom’s own error reporting/log for problematic files.
- If failures are consistent, try:
  - Changing export settings (format, size).
  - Testing with a smaller subset of images.

#### Imports are very slow or time out

- Try lowering the **Import batch size** in the configuration.
- Verify that:
  - Your network connection is stable.
  - The Immich server is not overloaded by other tasks (e.g. heavy background processing).

If problems persist, consider opening an issue on the GitHub repository, including logs and details about your setup (OS, Lightroom version, Immich version).

