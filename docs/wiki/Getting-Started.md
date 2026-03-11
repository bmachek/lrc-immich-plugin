## Getting Started / Installation

### Requirements

- **Lightroom Classic** on macOS or Windows.
- An **Immich server** reachable from your machine.
- An **Immich API key** created from your Immich user account.

For best results, create a dedicated API key for this plug‑in and restrict it to the permissions documented on the **Configuration** page.

---

### Downloading the plug‑in

1. Go to the GitHub repository for `lrc-immich-plugin`.
2. Open the **Releases** section.
3. Download the latest release that contains the `immich-plugin.lrplugin` folder (either directly or inside a ZIP archive).

---

### Installing into Lightroom Classic

1. Start **Lightroom Classic**.
2. Open **File → Plug‑in Manager…**.
3. Click **Add…**.
4. Browse to the downloaded `immich-plugin.lrplugin` folder and select it.
5. Confirm that `lrc-immich-plugin` appears in the list with a green status indicator (no errors).

You can remove or update the plug‑in later by using the same **Plug‑in Manager…** dialog.

---

### Verifying basic setup

After installation:

- You should see **Immich** as an available **Export** target in the **Export…** dialog.
- You should be able to create a new **Publish Service** entry for Immich in the **Publish Services** panel (after configuration).

If either of these is missing, check the **Plug‑in Manager…** for error messages and refer to the **Troubleshooting** section.

