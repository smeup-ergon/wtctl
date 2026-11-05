---
status: accepted
---

# Remove interactive and per-record management without migration

Remove the menus, wizards, prompts, `server`/`tunnel` record commands, installer flags and binary setup path, leaving the complete INI desired configuration ([ADR 0001](0001-shared-desired-config-and-activation-state.md)) as the only way to manage a device. The installer takes no parameters: it installs, writes a placeholder sample that cannot be applied unedited, records its own manager URL as accepted, and starts an idle bootstrap service, so the first apply is an ordinary activation against an init-owned supervisor. Software updates happen only through URL changes. Rerunning the installer is refused, and `uninstall` removes boot integration itself. Record-based installations from before 0.3.0 are rejected with reinstall instructions rather than migrated. Keeping two models would have added a second configuration authority and doubled the test surface for a handful of development devices. The cost is a manual reinstall for those devices and no interactive path for operators without an editor.
