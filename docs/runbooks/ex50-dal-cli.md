# Runbook: Driving the Digi EX50 DAL config (Admin CLI + `/bin/config`)

How to *script* configuration changes on the live EX50 border router without reverse-engineering the DAL surface each time. Companion to [ex50-console-access.md](ex50-console-access.md) (how to *reach* the CLI) and [ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md). The IaC apply path is [`ansible/playbooks/configure-ex50.yml`](../../ansible/playbooks/configure-ex50.yml) rendering [`ansible/files/ex50/config.dal.j2`](../../ansible/files/ex50/config.dal.j2); this runbook is the manual/diagnostic surface behind it.

Last updated: 2026-07-10 · Router live at `10.0.0.1`.

---

## Two config surfaces, same config

DAL exposes the *same* configuration through two programs. Pick by task:

| Surface | Invoke | Best for |
|---|---|---|
| **Admin CLI** (`/bin/cli`) | `ssh admin@10.0.0.1` (interactive) or pipe into `/bin/cli` from the shell | Structural edits (`add`/`del` list elements, navigating the tree), schema discovery (`?`), `show config` |
| **`/bin/config`** (shell) | `ssh -T admin@10.0.0.1 '<cmd>'` | Scripted get/set of a *known* leaf path — one-liners, scheduled scripts. Commits persistently on its own. |

Both read/write one committed config store. `save` (Admin CLI) == `config commit` (shell) == persistent (survives reboot).

---

## ⚠ The shell-access menu footgun (currently ARMED)

When **Shell access** is enabled (System → Device → Shell access, or it was toggled on for a work session), an interactive SSH login lands on an **Access selection menu** first:

```
    a: Admin CLI
    s: Shell
    q: Quit
```

Consequences:
- **A piped `printf 'config\n…' | ssh admin@host` now feeds the *menu*, not the Admin CLI** — every line comes back `Invalid option`. This is why `configure-ex50.yml`'s apply (which assumes it drops straight into the Admin CLI) **breaks while shell access is on.** Either disable shell access before running the playbook, or reach the Admin CLI explicitly (below).
- To reach the **Admin CLI** through the menu non-interactively: prefix the stream with `a\n`, or from a shell session pipe into `/bin/cli` directly (bypasses the menu entirely):
  ```sh
  ssh -T admin@10.0.0.1 'printf "config\n…\nsave\nexit\n" | /bin/cli'
  ```
- `ssh -T admin@host '<command>'` (command supplied) runs in the **shell** directly, no menu — this is the clean path for `/bin/config` one-liners.

**Leave shell access OFF in steady state** — it widens the SSH surface on the border router and re-arms this footgun. Turn it on only for a work session.

---

## Admin CLI mechanics (the non-obvious ones)

- **`show config`** dumps the full running config as a paste-able command list. This is the IaC source-of-truth read. (`show config <dotted.path>` is *not* valid — `show config` takes no path.)
- **`add <list> end`** appends a new list element **and navigates INTO it.** The single biggest gotcha: after `add system schedule script end` the current context *is* the new element, so set its fields **by bare relative name** — `label X`, `when set_time`, … — **not** `system schedule script 0 label X` (that doubles the path → `# ERROR` + schema dump).
- **`?`** after a node path prints that node's schema (parameters + current values). Works over piped stdin. `?` after a *field* name does **not** expand an enum — that needs interactive Tab, which doesn't render over a pipe. To learn a field's type/options from a script, use `/bin/config type <path>` or just try a value and read the error.
- **Staged edits discard on `exit`/`cancel` unless `save`d** — so you can explore destructively (stage an `add`, inspect, `cancel`) with zero risk. Prefer this for schema discovery.
- **`del <path> end "<value>"`** removes a list element by value (e.g. dropping the `wan` zone from `service ssh acl`).
- Custom firewall **zones** are created just by *naming* them on an interface (`network interface X zone Y`), not via `add firewall zone`. Filter rules match by **zone only** (no src-IP/interface match).

## `/bin/config` mechanics (shell)

```sh
config get <path>              # read a leaf. Booleans read back as 1 / 0.
config set <path> <val>        # write + COMMIT persistently (logs "config change committed")
config dump [<path>]           # full key=value tree under a path (shows ALL schema fields,
                               #   more than the Admin CLI `?` table)
config type <path>             # a leaf's type
```

- `config get`/`set`/`dump` work **without a session** — each `set` self-commits. This is the mechanism for scripted toggles.
- The **session** verbs (`config start`, `new`, `keys`, `delete`, …) need a `socketpair` shell helper that only exists in the *interactive login shell*, so `eval $(config start)` comes back empty over one-shot `ssh -T '…'`. **Don't use the session form in scripts** — use standalone `config set`, or do structural `add`/`del` via `/bin/cli`.
- Creating a *new list element* (`config new`) therefore needs either an interactive session or the Admin CLI (`add … end`). Setting a leaf on an existing element is a plain `config set`.

---

## Recipe: scheduled config change (native, IaC-captured)

DAL's own scheduler is `system schedule script` — a list of scripts run on a time/interval, **stored in `show config`** (so it round-trips through our IaC; a Linux crontab would not, and DAL has no cron anyway). Each element:

| Field | Meaning |
|---|---|
| `when` | `set_time` (daily at `run_time` HH:MM), `interval`, `on boot`, `maintenance_time` |
| `run_time` | HH:MM (box clock is **UTC** — check with `date`) |
| `once` | run once vs. repeat |
| `sandbox` | leave `false` if the script must reach `/bin/config` |
| `commands` | the command line to run (e.g. `config set <path> <val>`) |
| `syslog_stdout` / `syslog_stderr` | capture output to syslog |

Create one (note the **relative** field sets after `add`):

```sh
ssh -T admin@10.0.0.1 'printf "config\nadd system schedule script end\nlabel my-task\nwhen set_time\nrun_time 08:00\nonce false\nsandbox false\ncommands \"config set <path> <val>\"\nsave\nexit\n" | /bin/cli'
```

Verify: `ssh -T admin@10.0.0.1 'config dump system.schedule.script.0'`. Delete: `del system schedule script <n>` via `/bin/cli`.

**Verified 2026-07-10** end-to-end: a `set_time` script fired at its `run_time` and ran `config set …`, committing persistently **as root** (`sandbox false`). Under the hood DAL dispatches these via **fcron** (`/bin/run_task run_once …`) — so the box already has cron; `system schedule script` is the config-captured front end for it, which is why we don't (and shouldn't) install a separate crontab. Set `syslog_stdout`/`syslog_stderr true` to get `script.<label>.stdout/stderr/exit` lines in the syslog for debugging.

## Reading logs / runtime state

- Syslog from the shell: `ssh -T admin@10.0.0.1 'logread'` (filter with `grep` — e.g. `script.`, `config change`, `schedule`).
- The box clock is **UTC** (`date`); `run_time` values are UTC.
