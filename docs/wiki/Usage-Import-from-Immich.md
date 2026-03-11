## Usage: Import from Immich

In addition to sending images to Immich, the plug‑in can download assets from Immich and bring them into your Lightroom Classic catalog.

---

### Importing an Immich album

1. Open the plug‑in’s **Import from Immich** dialog (menu name may vary slightly; look under the plug‑in’s menu entry or the Library module menus).
2. Authenticate/connect using your configured Immich URL and API key (see **Configuration** if needed).
3. Choose an **album** (or another supported asset grouping) from the list returned by Immich.
4. Confirm or adjust the **Import path**:
   - This is the local folder where downloaded assets will be written.
5. Start the import.

The plug‑in:

- Queries Immich for the selected album’s assets.
- Downloads assets in **batches**, using the configured **import batch size**:
  - Higher batch sizes = more parallel downloads.
  - Lower batch sizes = reduced load on your system and network.
- Writes the files into the chosen import path.

---

### Bringing downloaded files into Lightroom

After the plug‑in has finished downloading:

1. In Lightroom Classic, go to **Library → Import Photos and Video…**.
2. Point the import dialog at the folder used as your **Import path**.
3. Choose **Add** or **Copy** according to your catalog organization preferences.
4. Complete the import.

You now have Immich assets represented as regular files inside your Lightroom catalog for editing, keywording, and further export or publish workflows.

---

### Performance and reliability tips

- If imports are slow or your network becomes unstable:
  - Lower the **Import batch size** in the plug‑in configuration.
- If your Immich server is powerful and your network is fast:
  - You can experiment with gradually increasing the batch size to speed up large imports.
- Periodically clean up the import folder if you don’t need to keep original downloaded files around after they’ve been added to Lightroom.

