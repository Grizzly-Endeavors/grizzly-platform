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

## User identity & access (`social-login.yaml`)

Human users are **not** declared as blueprint objects — there are no `authentik_core.user` entries, by design, so no human PII (emails/names) ever lands in this public repo or in OpenBao. Identity comes from the social provider (Discord/GitHub/Google) at first login; the account is created from the provider's data.

Access is **closed, gated by invitation**. The flow `grizzly-invite-enrollment` prompts for an invitation code and its invitation stage (`continue_flow_without_invitation: false`) halts the flow when the code is missing/invalid — so an uninvited social login creates no account. Enrolled users are auto-added to `grizzly-users` by the User Write stage (`create_users_group`), created active (`create_users_as_inactive: false`). See [ADR-039](../../../../docs/decisions/039-authentik-social-federation-invitation-enrollment.md).

**Onboarding a person** (per-user cost = one invite + a message): create an invitation — Admin UI → *Directory → Invitations* (or the API) — and hand them the code. They open `sso.bearflinn.com`, click **Discord**, **GitHub**, or **Google**, and paste the code. Promotion to `grizzly-admins` is a separate, deliberate step (not automated). Revoking access is deleting the user (and their source connection) in Authentik — there's no blueprint object to remove.

**Break-glass / no-social path:** there is no SMTP, so no self-service email password reset. For a user without a social account, an admin issues a one-time recovery link (Admin UI → *Directory → Users → \<user\> → Create recovery link*) handed out-of-band. `akadmin` retains its bootstrap password.
