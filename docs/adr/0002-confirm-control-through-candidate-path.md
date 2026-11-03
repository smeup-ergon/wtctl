---
status: accepted
---

# Confirm control changes through a distinct candidate path

Confirm changed or newly enabled control connectivity, and software updates with enabled control, by receiving byte-identical draft configuration through a distinct candidate loopback receiver. Process startup alone cannot prove end-to-end reachability, while a shared receiver cannot distinguish the old tunnel from its replacement. This avoids another authentication/protocol mechanism but requires temporary receiver lifecycle management and permits outages when old and candidate server listeners conflict; rollback remains best-effort while the activation process survives.
