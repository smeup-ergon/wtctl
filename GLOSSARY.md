# wtctl

wtctl manages persistent tunnels on a device. Its local and remote management interfaces share one desired configuration.

## Language

**Desired configuration**:
The complete description of the device's intended wtctl setup, including managed tunnels, control connectivity, and software source URLs. The latest local or remote submission is authoritative, even if its activation fails.
_Avoid_: Remote configuration, local configuration

**Active configuration**:
The last complete desired configuration whose activation succeeded. It remains the working setup when a replacement fails to activate.

**Bootstrap configuration**:
The active configuration established by installation: no managed tunnels, control disabled, and the installed wtctl source URL accepted. It keeps the service running until the first successful configuration activation.
_Avoid_: Default configuration, empty setup

**Managed tunnel**:
An ordinary forwarding tunnel declared in the desired configuration, maintained automatically until it is removed from that configuration.

**Control tunnel**:
A dedicated tunnel for remotely submitting and retrieving the device's desired configuration. It is managed separately from ordinary managed tunnels, is enabled by default, and can be explicitly disabled.

**Control receiver**:
The device-side loopback listener that executes one control request per connection. Each receiver is a dedicated dropbear instance accepting only the blank-password receiver account, which exists only while control is enabled. It is not an authentication boundary.
_Avoid_: Control server, SSH access

**Accepted control settings**:
The control connectivity settings retained after their connection has succeeded, distinct from an unconfirmed replacement in the desired configuration.

**Draft configuration**:
A submitted replacement for the desired configuration that has not yet passed all acceptance checks. When control settings change, resubmitting the same draft through the replacement control tunnel confirms its reachability.

**Software source URL**:
The configured download location for either wtctl itself or the wstunnel executable. A change of URL requests an update; unchanged URLs do not request another update.

**Activation state**:
The last successfully activated software source URLs and accepted control settings. It records successful activation rather than providing a separate source of desired configuration.

**Configuration activation**:
An attempt to make a desired configuration the device's active configuration. A failed attempt is reported rather than automatically retried; recovery of already accepted software and tunnels is distinct from a new activation attempt.

**Path-prefix secret**:
A shared secret presented when a device establishes a tunnel with a server. It does not grant or restrict access to a control listener already exposed by that server.

**Device qualification**:
Evidence that a supported device can install, activate, recover, and maintain its configured connectivity under its actual operating conditions. Simulated recovery alone does not establish device qualification.
