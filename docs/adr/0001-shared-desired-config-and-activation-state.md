---
status: accepted
---

# Share desired configuration across local and remote management

Replace interactive/per-record mutation with one complete INI desired configuration and a shared local/remote activation path, using last-write-wins rather than revisions or merging. Persist active configuration and successful software/control activation state separately so a rejected desired configuration remains inspectable without being retried on boot; retries require explicit submission. This deliberately adds a desired/active distinction to preserve availability and simple update semantics without a second configuration authority.
