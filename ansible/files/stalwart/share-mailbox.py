#!/usr/bin/env python3
"""Grant another account IMAP ACL rights on folders of a Stalwart mailbox.

Logs in once as the mailbox owner and sets each folder's ACL entry for the
grantee to exactly the requested rights, leaving folders that already match
untouched. Prints "changed: <folders>" when it set anything, "unchanged"
otherwise, so the calling Ansible task can report changed state.

The owner password comes from the SHARE_OWNER_PASSWORD environment variable,
never argv. Exactly one login per run: repeated failed logins from outside
10.0.0.0/8 get the caller's IP banned on the mail server.

Usage:
  share-mailbox.py HOST OWNER GRANTEE RIGHTS FOLDER [FOLDER ...]
"""

import imaplib
import os
import re
import sys


def current_rights(conn, folder, grantee):
    typ, data = conn.getacl(f'"{folder}"')
    if typ != "OK":
        raise SystemExit(f"GETACL {folder} failed: {data!r}")
    # Response: "<folder>" "<id>" <rights> "<id>" <rights> ...
    line = data[0].decode()
    pairs = re.findall(r'"([^"]+)"\s+(\S+)', line.split(" ", 1)[1])
    return dict(pairs).get(grantee, "")


def main():
    host, owner, grantee, rights, *folders = sys.argv[1:]
    if not folders:
        raise SystemExit(__doc__)
    conn = imaplib.IMAP4_SSL(host, 993, timeout=30)
    try:
        conn.login(owner, os.environ["SHARE_OWNER_PASSWORD"])
        changed = []
        for folder in folders:
            if sorted(current_rights(conn, folder, grantee)) == sorted(rights):
                continue
            typ, data = conn.setacl(f'"{folder}"', grantee, rights)
            if typ != "OK":
                raise SystemExit(f"SETACL {folder} failed: {data!r}")
            changed.append(folder)
    finally:
        conn.logout()
    print(f"changed: {', '.join(changed)}" if changed else "unchanged")


if __name__ == "__main__":
    main()
