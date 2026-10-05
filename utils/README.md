# Stable release download on the device

Copy `download-release.sh` onto the Kindle, then run:

```sh
sh download-release.sh 1.7.0
```

The default runtime is `/mnt/us/koreader`; the ZIP is saved in `/mnt/us/Downloads`.
For a Kobo/Tolino or a different installation, pass its actual runtime/output paths:

```sh
sh download-release.sh 1.7.0 --runtime /path/to/koreader --output /path/to/downloads
```

Only an official, published stable GitHub release is accepted. The script checks
release metadata, the exact asset URL, file size and GitHub's SHA-256 digest.
It downloads only: it does not replace the running plugin, erase notebooks or
restart KOReader. Stop KOReader before manually replacing a plugin installation
with an older package, and keep a backup of the current plugin outside its directory.

For an upgrade test, keep a backup of the installed plugin, download a previous
stable release (for example `1.6.3`), restart KOReader, and use
**Updates → Check update** to install the current stable release.
Development prereleases are intentionally ignored.
