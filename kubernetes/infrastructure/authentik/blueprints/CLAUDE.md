# Authentik blueprints

Declarative config-as-code for Authentik, delivered through the Helm chart's `blueprints.configMaps` key (see [ADR-037](../../../../docs/decisions/037-authentik-config-as-code-blueprints.md)). Each entry is `{model, identifiers, attrs}`, upserted idempotently and reconciled every 60 min.

## Removal means deletion, not omission

Blueprints are **stateless upsert** — they only manage the objects they mention. Removing an entry (or deleting a blueprint file) does **not** delete the object in Authentik; it just stops managing it, leaving orphaned cruft that lingers until removed by hand. There is no state file that reconciles "the full desired set" the way Terraform would.

So when you remove a managed object, the removal is a two-step that you must complete in the same change:

1. Delete the entry/file from this directory, **and**
2. Ensure the object is actually gone from Authentik — either by first marking the entry `state: absent` (let one reconcile delete it, then drop the entry in a follow-up), or by deleting it directly via the API/UI as part of the change.

Never leave a removed object orphaned in the running instance. A blueprint disappearing from git must coincide with the object disappearing from Authentik.

## Cross-references: `!KeyOf` is same-file only

`!KeyOf <id>` resolves the PK of another entry's `id:` **within the same blueprint file**; it cannot reach an entry in a different file. For references across files, use `!Find [model, [field, value]]`, which resolves lazily against the DB at apply time.

**Order matters within a file:** `!KeyOf` resolves to an *already-applied* entry, so the target entry must appear **above** every entry that references it. Entries are applied top-to-bottom in one transaction; a forward reference fails with `KeyOf: failed to find entry with id ...` and rolls the whole blueprint back. Arrange dependencies-first (e.g. flow + stages → sources that reference the flow → bindings that reference both). Beware: if file A `!Find`s an object that file B creates, and B hasn't applied yet, the `!Find` returns null that pass and only converges on a later reconcile (up to 60 min). When two objects reference each other (e.g. a source's `enrollment_flow` and that flow's stages referencing the source), keep them in **one file** so every link is `!KeyOf` and resolves in a single atomic transaction. This is why `social-login.yaml` is one file rather than split.

## `attrs` is a partial update, but validation is not

An entry only writes the attrs it lists — but the serializer validates **only what the entry supplies**, never merged with the stored object. So on any model whose serializer has a cross-field rule, a single-attr patch fails even though the stored object would satisfy the rule.

The one that has already bitten: `default-authentication-identification` enforces *"When no user fields are selected, at least one source must be selected"*. An entry setting just `enrollment_flow` is rejected, and because the whole blueprint applies in one transaction, that one bad entry rolls back everything else in the file. Hence `social-login.yaml` owns that stage whole — `sources` and `enrollment_flow` together — rather than letting `email-otp.yaml` patch one attr of it.

So: two files may each own a *disjoint* attr of the same object only when the serializer has no cross-field validator. When in doubt, give the object a single owning file.

## Debugging a failed blueprint

`BlueprintInstance.status == "error"` with nothing useful in the worker logs. The real serializer error is **masked**: `KeyOf.__repr__` resolves against an empty `Blueprint()`, so it raises while structlog is serializing the failing entry, and what surfaces is a misleading `KeyOf: failed to find entry with id ...` naming the file's *first* entry. Chasing that leads nowhere.

Get the actual error by running the importer directly — `transaction_rollback()` makes this safe to do against production:

```
kubectl -n authentik exec deploy/authentik-worker -- ak shell -c "
from authentik.blueprints.v1.importer import Importer, transaction_rollback
imp = Importer.from_string(open('/blueprints/mounted/cm-authentik-blueprints/<file>.yaml').read())
try:
    with transaction_rollback():
        print('OK' if imp._apply_models(raise_errors=True) else 'FALSE')
except Exception as exc:
    print('FAILED:', exc)
"
```

Note the mounted file lags the ConfigMap by up to a minute or two after Flux applies — check the file in the pod, not just `kubectl get cm`, before concluding a fix didn't work.

## User identity & access (`social-login.yaml`, `email-otp.yaml`)

Human users are **not** declared as blueprint objects — there are no `authentik_core.user` entries, by design, so no human PII (emails/names) ever lands in this public repo or in the secret store. Identity comes from the social provider (Discord/GitHub/Google) at first login, or from the address the person types into the email sign-up flow.

Access is **closed, gated by invitation**, on both paths. The `grizzly-invite-gate` **expression policy** is re-evaluated on the user-write stage binding of each enrollment flow: it reads the `grizzly_invite` cookie planted by the [grizzly-invite broker](https://github.com/Grizzly-Endeavors/grizzly-invite) and POSTs it to the broker's `/verify`; a missing/invalid/used invitation (or a broker error) denies the flow, so an uninvited sign-up creates no account. The cookie is the bridge that survives the OAuth round-trip Authentik flow context does not. Enrolled users are auto-added to `grizzly-users` by the User Write stage (`create_users_group`). See [ADR-040](../../../../docs/decisions/040-invite-broker-cookie-bridged-enrollment.md) (and [ADR-039](../../../../docs/decisions/039-authentik-social-federation-invitation-enrollment.md) for the original invitation model).

The two flows differ in what they do with the account once the gate passes. `grizzly-invite-enrollment` creates it active from the provider's data. `grizzly-email-enrollment` creates it **inactive** and activates it only after a one-time code mailed to the address is confirmed, so an account existing always means its address was proven ([ADR-066](../../../../docs/decisions/066-email-otp-passwordless-signin.md)).

**Onboarding a person** (per-user cost = one invite + a message): mint an invite in the broker (`POST /api/invites` with the admin bearer token) and send them the returned `invite.grizzly-endeavors.com/i/<token>` link. They click it, then either sign in with **Discord**, **GitHub**, or **Google**, or use **Sign up** to enroll with just an email address and the code they are sent. To pre-scope the person into one or more groups (e.g. a household or friend circle from `groups.yaml`), pass `{"groups": ["Big Bear Hollow"]}` in the mint body; the enrollment gate adds them on top of `grizzly-users` (unknown names are ignored). Promotion to `grizzly-admins` is a separate, deliberate step (not automated). Revoking access is deleting the user (and their source connection) in Authentik; revoking an *unused* invite is `DELETE /api/invites/<id>` on the broker.

**Credentials:** email enrollees have no password — the mailed code is the credential, and the password stage is skipped for them by the `grizzly-email-passwordless` policy. Social enrollees have neither password nor code until they add an email authenticator from User Settings (the `grizzly-email-otp-setup` flow); until then their provider is their only way in. `akadmin` retains its bootstrap password and is unaffected by any of this. An admin can still issue a one-time recovery link out-of-band (Admin UI → *Directory → Users → \<user\> → Create recovery link*).
