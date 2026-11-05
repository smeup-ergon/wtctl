---
status: accepted
---

# Receive control through dropbear with a blank-password account

Stock OpenWrt (22.03.4) can't run the original `nc -lk -e` receiver: its BusyBox `nc` has no listen mode, and it has no `inetd`, `tcpsvd`, `httpd` or socket-capable Lua/ucode. Each control receiver is instead a dedicated loopback dropbear instance that forces `wtctl _handle` as its command, with forwarding disabled and only blank-password logins accepted (`-B`). It logs in through a wtctl-owned `wtctl` account with root's user ID, which exists only while control is accepted as enabled. dropbear is already part of OpenWrt's base system, so no dependency is added. The request protocol, per-port receivers and candidate confirmation ([ADR 0002](0002-confirm-control-through-candidate-path.md)) are unchanged; operators use plain `ssh` without keys instead of `nc`.

Authentication stays out of scope by choice: the server firewall remains the only access control. Rejected alternatives were SSH keys (key management for operators, and OpenWrt's dropbear reads root keys only from the shared `/etc/dropbear/authorized_keys`), and an unprivileged account handing requests to the root supervisor (a new privilege-handoff mechanism). Also rejected: uhttpd CGI (often removed with LuCI, and a protocol change) and the device fetching configuration from the server (requires server software). The cost is a passwordless root-equivalent account while control is enabled. Normal SSH refuses it, but a local password prompt would accept it. wtctl also now edits `/etc/passwd`, changing only its own marked entry.
