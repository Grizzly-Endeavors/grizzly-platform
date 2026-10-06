# ADR-079: Home Automation Stack and How It Is Gated

**Date:** 2026-10-06
**Status:** Accepted
**Relates to:** [ADR-025](025-personal-apps-in-separate-repo.md) (lab-apps), [ADR-037](037-authentik-config-as-code-blueprints.md) (blueprints), [ADR-043](043-invite-admin-ui-forward-auth.md) (forward-auth pattern)

## Context

Bear bought an SMLIGHT SLZB-06U Zigbee coordinator (CC2652P radio, Z-Stack 20250321, PoE/Ethernet) and Philips Hue bulbs. The coordinator serves its radio over TCP (`10.0.0.144:6638`), so the controlling software can run anywhere on the LAN. Bear chose Home Assistant plus Zigbee2MQTT and an MQTT broker, run in the cluster from lab-apps (`apps/home-automation`), and asked that everything touching the home's IoT be restricted to the `grizzly-admins` Authentik group.

The platform's usual way to restrict a web app to a group is nginx forward-auth through the embedded outpost (Metabase, webmail, the invite admin UI). That works for browser-only apps. Home Assistant also has a companion phone app, whose websocket (`/api/websocket`), webhook (`/api/webhook/*`) and token (`/auth/token`) calls carry no Authentik session. Behind forward-auth they fail. The common workaround is to exempt those paths, which leaves HA's login page and API reachable without Authentik and defeats the group restriction.

## Decision

1. **Zigbee2MQTT talks to the coordinator over the LAN** (`serial.port: tcp://10.0.0.144:6638`, adapter `zstack`). There is no USB passthrough, so the pod is not pinned to a node. Zigbee channel 25.
2. **Home Assistant signs in over OIDC**, using the [hass-oidc-auth](https://github.com/christiaangoossens/hass-oidc-auth) custom integration. Its ingress has no forward-auth.
   - The provider is a **public** OAuth2 client (`client_id: home-assistant`, PKCE, strict redirect `https://home.grizzly-endeavors.com/auth/oidc/callback`) in `blueprints/home-iot.yaml`. There is no client secret, so nothing goes to 1Password.
   - The **Authentik application binding to `grizzly-admins`** is the control: a user outside the group is refused before a token is issued.
   - HA re-checks the group (`auth_oidc.roles.admin` and `roles.user` both `grizzly-admins`) from the `groups` claim that Authentik's `profile` scope carries.
   - HA's local login stays enabled as break-glass, at `/?skip_oidc_redirect=true`.
   - The integration is installed by an init container from a pinned release with a checksum, not by HACS, so its version lives in git.
3. **The Zigbee2MQTT frontend uses forward-auth** (proxy provider `zigbee2mqtt`, bound to `grizzly-admins`). It has no login of its own and no app, so the proxy gate fits and is its only protection.
4. **Mosquitto is anonymous, unpersisted and namespace-only.** A NetworkPolicy admits only pods in `home-automation`. Nothing on the broker needs to survive a restart, because Zigbee2MQTT republishes state and HA discovery when HA reconnects.
5. **State lives on `iscsi-zfs-retain` volumes**, one for each of HA and Zigbee2MQTT. Neither can use the foundation stores for this state:
   - Zigbee2MQTT keeps its network key and device database as files.
   - HA keeps auth, devices and integrations as files under `.storage`.
   HA's recorder stays on SQLite in that same volume, so one volume restores the whole of HA. Block storage, not NFS, because of the SQLite locking risk. The Retain class means deleting a PVC can't destroy the zvol.

6. **Agent access goes through a dedicated `claude` HA user**: administrator, local-network only. Its password and long-lived token live in the 1Password item `home-assistant-claude`. An ExternalSecret mounts the token into the HA pod at `/run/secrets/hassapi/token`. The `hassapi` wrapper on the control node calls the REST and WebSocket APIs through `kubectl exec` against `127.0.0.1:8123`. Because the user is local-only, the token is refused from outside the pod, and HA's logbook attributes agent changes to "Claude". Zigbee2MQTT needs no extra credential: agents drive it over MQTT through the Mosquitto pod.

## Alternatives Considered

- **Forward-auth in front of all of HA.** Rejected: it breaks the companion app. The hass-oidc-auth maintainer calls proxy auth with the app an unsupported setup.
- **Forward-auth with `/api` and `/auth` exempted.** Rejected: the exempt paths include HA's login and API, so the group restriction would only cover the HTML shell.
- **Header auth (`BeryJu/hass-auth-header`).** Rejected: the repository was archived on 2025-10-23.
- **`cavefire/hass-openid`.** A viable alternative that Authentik's integration docs also list. hass-oidc-auth was chosen because it has YAML-configurable role and group enforcement and a device-code login for the companion app.
- **Agent access through Bear's own HA account or a token on it.** Rejected: agent changes would be indistinguishable from Bear's in the logbook, and revoking the agent would mean touching Bear's login.
- **Confidential OIDC client.** Rejected: PKCE with a strict redirect URI is enough, and the integration recommends a public client. A secret would add a 1Password item and an ExternalSecret without adding protection.
- **Zigbee2MQTT and HA on the desktop over USB.** Rejected: the lights would depend on a workstation being on.
- **HA alone with ZHA.** Bear chose Zigbee2MQTT for its device coverage and frontend.

## Consequences

- **Phone app sign-in takes an extra step.** The app shows a code, which is confirmed in the phone's browser through Authentik. After that the app stays signed in.
- **HA's login page is publicly reachable**, as it is for any internet-exposed HA. Authentik guards new OIDC logins, and HA's own password plus MFA guards the break-glass local account.
- **hass-oidc-auth is a community integration.** Re-test sign-in after HA upgrades. To upgrade it, bump `AUTH_OIDC_VERSION` and `AUTH_OIDC_SHA256` together in `home-assistant.yaml`.
- **Both configuration files are seeded only on the first start.** After that the apps own them on their volumes, so changing the ConfigMap does not change a running install.
- **Losing the Zigbee2MQTT volume means re-pairing every device.**
- **Health:** readiness probes on HA (`/manifest.json`), Zigbee2MQTT (`/`) and Mosquitto (TCP 1883). The SLZB dashboard at `http://10.0.0.144/` shows whether a Zigbee2MQTT socket is connected.
- **Metrics and alerts:** there are no app-specific ones yet. `FluxReconciliationFailure`, `IngressNginx5xxRate` and `AuthentikDown` cover the delivery path. Backups and app alerting are tracked as lab-apps issues.
- **Logs:** container stdout for all three pods (`kubectl -n home-automation logs deploy/<name>`).
- **First steps when the lights stop responding:**
  1. Check that `deploy/zigbee2mqtt` is Ready and its log shows the coordinator connected.
  2. Check that `10.0.0.144` answers and its dashboard shows the socket connected.
  3. Check Mosquitto.
  4. If HA can't see the devices, check its MQTT integration.
- **Dependencies:** the SLZB on the LAN, the iSCSI volumes on the R730xd, Authentik (OIDC and forward-auth) and ingress-nginx.
