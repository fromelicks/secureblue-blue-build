# User Groups on rpm-ostree Systems

Fedora Atomic systems can expose system groups from `/usr/lib/group` while
local membership changes live in `/etc/group` and `/etc/gshadow`. If a group is
only present in `/usr/lib/group`, tools like `usermod -aG` may update
`/etc/gshadow` without creating a matching `/etc/group` entry. The result is
that `getent group <group>` still shows no members.

Fedora documents the workaround here:
<https://docs.fedoraproject.org/en-US/atomic-desktops/troubleshooting/#_unable_to_add_user_to_group>

## TPM Access for ssh-tpm-agent

Symptom:

```text
ssh-tpm-keygen
open /dev/tpmrm0: permission denied
```

On this image, `/dev/tpmrm0` is owned by `root:tss` with mode `0660`, so the
login user needs supplemental membership in the `tss` group.

Use the Fedora Atomic workaround before adding the user:

```bash
grep -E '^tss:' /usr/lib/group | run0 -i tee -a /etc/group
run0 -i usermod -aG tss "$USER"
```

Then log out and back in, or reboot, so the login session picks up the new
supplemental group.

Verify:

```bash
getent group tss
id
tpm2_getrandom --hex 8
ssh-tpm-keygen --supported
```

Expected results:

- `getent group tss` includes the login user.
- `id` includes `59(tss)` after a fresh login.
- `tpm2_getrandom` and `ssh-tpm-keygen --supported` run without
  `/dev/tpmrm0` permission errors.
