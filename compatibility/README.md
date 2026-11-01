# Verified core releases

Each file in `cores/` lists releases reviewed for Sky UI. The API and privileged
updater read the corresponding file from this repository's `main` branch over
HTTPS. An unavailable or invalid file disables updates. Upstream release feeds
are not used to decide compatibility.

To approve a version, set `verified` to true, list exact tested Sky UI versions
in `panelVersions`, and add each tested platform with its own `verified` flag,
official asset filename and compressed asset SHA-256. Do not approve platforms
or panel versions that have not passed the relevant checks. `verifiedAt` records
the review date. Unverified entries may be retained with `verified: false`.

Check basic supported protocols, current configuration validation, real client
traffic, access revocation and update rollback before approval. New transports
or protocol options need adapter/export support before being advertised in UI.

Downloads always come from the fixed original core repository, with the hash
specified here. Revoking approval takes effect when the catalog is refreshed;
the worker rechecks it immediately before any download or installation.
