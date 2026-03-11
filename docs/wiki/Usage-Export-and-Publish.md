## Usage: Export & Publish

This plug‑in integrates with both the **Export** dialog and Lightroom Classic’s **Publish Services**.

---

### Export to Immich

Use this when you want a one‑off upload of selected photos to Immich.

1. **Select photos** in your Lightroom catalog.
2. Choose **File → Export…**.
3. In the **Export To** dropdown, select the **Immich** export preset or destination provided by the plug‑in.
4. Adjust the usual export settings as needed:
   - File type, size, and quality.
   - Naming and metadata options.
5. Start the export.

Behind the scenes:

- Lightroom renders the selected photos to temporary files.
- The plug‑in uploads those files to your Immich server via the Immich API.
- Temporary files are cleaned up after a successful upload; failed renders are skipped so the rest of the queue can complete.

---

### Publish Service to Immich

Use this when you want a **persistent relationship** between Lightroom collections and Immich albums.

#### Creating a Publish Service

1. Open Lightroom’s **Library** module.
2. In the **Publish Services** panel, click **Set Up…** next to the Immich entry (or add a new one if needed).
3. Configure the service using your preferred defaults (described in the **Configuration** page).
4. Save the service.

You now have an Immich publish service entry in the left panel.

#### Creating publish collections

1. Right‑click the Immich publish service entry and choose **Create Published Collection…**.
2. Name the collection (this typically maps to an album in Immich).
3. Optionally set additional collection‑specific settings.
4. Add photos to the collection.

#### Publishing changes

- New photos added to a published collection appear as “New Photos to Publish”.
- When you click **Publish**:
  - Lightroom renders the images.
  - The plug‑in uploads them to Immich, creating or updating the corresponding assets.
- Removing or updating photos in the collection behaves like any other publish service:
  - Updates can be republished.
  - Removed items can be marked for deletion, depending on your settings and Immich behaviour.

Use the publish model if you want to keep certain Immich albums always in sync with curated Lightroom collections.

