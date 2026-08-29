# Kernel arguments

How a karg declared in `recipes/recipe.yml` does — and does not — reach the boot
loader entry, and how to repair one that never arrived.

Written after `reserve_mem=`/`ramoops.*` from [`crash-capture.md`](crash-capture.md)
sat in the image for days without ever appearing on `/proc/cmdline`.

## The path from recipe to cmdline

BlueBuild's `kargs` module does not edit anything at install time. It writes a
file into the image:

```
/usr/lib/bootc/kargs.d/bluebuild-kargs.toml
  kargs = ["loglevel=4", "reserve_mem=2M:4096:oops", "ramoops.mem_name=oops", "ramoops.ecc=1"]
```

secureblue and the NVIDIA layer ship their own alongside it (`10-secureblue.toml`,
`20-nvidia.toml`). Something on the host has to read those files and merge them
into the BLS entry's `options` line.

**Only `bootc` does.** `rpm-ostree` has no `kargs.d` support whatsoever — not in
the client, not in `librpmostree`, not in `libostree`:

```
$ strings /usr/bin/bootc | grep -c 'kargs\.d'                    # 2
$ strings /usr/bin/rpm-ostree | grep -c 'kargs\.d'               # 0
$ strings /usr/lib64/librpmostree-1.so.1 | grep -c 'kargs\.d'    # 0
$ strings /usr/lib64/libostree-1.so.1 | grep -c 'kargs\.d'       # 0
```

So a deployment created by `rpm-ostree rebase`, `rpm-ostree upgrade`, or
`rpm-ostreed-automatic.service` silently ignores every karg the recipe declares.
No warning, no diagnostic — the deployment just boots with the previous
`options` line carried forward.

Use `bootc upgrade`. `rpm-ostreed-automatic.timer` should be disabled in favour
of `bootc-fetch-apply-updates.timer` (mind the behaviour difference: the bootc
unit runs `bootc upgrade --apply`, which **reboots**, on a timer with
`RandomizedDelaySec=2h`; the rpm-ostree default here was `stage` only).

## The trap: bootc applies kargs.d as a *delta*

This is the part that cost a day. `bootc` does not treat `kargs.d` as desired
state. `crates/lib/src/bootc_kargs.rs` reads the files from the **booted**
deployment, reads them from the **incoming** image, and applies the difference —
its own trace strings are `current_kargs=`, `new_kargs=`, `kargs: added= removed=`.

That is fine when a karg is added to the recipe and the next update is done with
`bootc`. It is a permanent dead end in one specific case:

> A karg first shipped in a deployment created by **rpm-ostree** never reaches the
> BLS. From then on, every image contains it and every booted deployment contains
> it, so the delta is empty **forever**. No number of `bootc upgrade` runs will
> ever apply it.

That is exactly what happened to the ramoops kargs, and why `ujust
check-crash-capture` kept reporting them missing across a rebase, a `bootc
upgrade`, and two reboots — while `/usr/lib/bootc/kargs.d/bluebuild-kargs.toml`
in both the old and the new deployment listed all four correctly.

Symptom to recognise: the karg is present in the deployment's `kargs.d`, absent
from `/proc/cmdline`, and there are no `x-options-source-*` keys in
`/boot/loader/entries/*.conf`.

Only the *stuck set* is affected. Once the values are in the BLS by any means,
later recipe *changes* to them produce a real delta and apply normally.

## Repairing a stuck karg

`bootc` has a first-class escape hatch. It writes an `x-options-source-<name>`
key into the BLS entry and recomputes `options` as the merge of all tracked
sources plus any untracked pre-existing ones:

```bash
run0 --pipe bash -c 'bootc loader-entries set-options-for-source \
  --source fromelicks \
  --options "reserve_mem=2M:4096:oops ramoops.mem_name=oops ramoops.ecc=1"'
```

It stages a deployment; the BLS entry is only rewritten by
`ostree-finalize-staged.service` at shutdown, so `/boot/loader/entries/` still
shows the old `options` until you reboot. Verify the staged deployment instead:

```bash
strings /run/ostree/staged-deployment | grep -E 'x-options-source|reserve_mem'
```

Then reboot and confirm:

```bash
grep -o 'reserve_mem=[^ ]*\|ramoops\.[^ ]*' /proc/cmdline
grep x-options-source /boot/loader/entries/*.conf
```

Pick a source name of your own (`fromelicks`). Do **not** reuse
`bootc-kargs-d`, which the `--help` text uses as an example: `bootc`'s own
`kargs.d` path writes *untracked* options via
`ostree_sysroot_deployment_set_kargs_in_place` and claims no source name, so
reusing it invites a collision.

The origin is preserved — it stays `ostree-image-signed:`, so cosign
verification is not affected.

### Fallback

`rpm-ostree kargs --append-if-missing=…` also works and is well-trodden; it is
how `loglevel=4` has survived every deployment on this machine since June. It
writes the args as untracked options, which future `bootc upgrade` runs carry
forward. Less tidy — nothing records *why* the args are there — but it does not
depend on a subcommand that behaved inconsistently for us (see below).

### The declarative alternative

To avoid a local edit entirely: remove the kargs from the recipe, build and
`bootc upgrade`; then re-add them, build and `bootc upgrade` again. The second
diff is non-empty so `bootc` applies all of them properly. Correct, and leaves
zero drift — at the cost of two build cycles and two reboots.

## `run0` gotchas hit along the way

Three separate ways the repair command failed before it worked. All three are
about `run0`, not about `bootc`.

**`-i` is `--via-shell` and destroys quoting.**

```
$ run0 --help
     --via-shell    Invoke command via target user's login shell
  -i                Shortcut for --via-shell --chdir='~'
```

It re-joins argv into a command line for a second shell, so quotes consumed by
your shell never reach it. `--options "a b c"` arrives as three arguments:

```
error: unexpected argument 'ramoops.mem_name=oops' found
```

Harmless for `run0 -i bootc upgrade`; fatal for anything with a quoted argument.

**An absolute path to `bootc` hits an SELinux denial.** `/usr/bin/bootc` is
labelled `install_exec_t`, and `run0`'s transient unit cannot exec it directly:

```
AVC avc: denied { entrypoint } for comm="(bootc)" path="/usr/bin/bootc"
  scontext=unconfined_u:unconfined_r:unconfined_t  tcontext=system_u:object_r:install_exec_t
Failed at step EXEC spawning /usr/bin/bootc: Permission denied
```

Passing the bare name `bootc` makes `run0` resolve it through a shell, which
works. So: never give `run0` an absolute path to `bootc`.

**`run0` allocates a pty by default, so output does not reach the journal.** A
failing command can look like it produced nothing at all. Use `--pipe` when you
need to capture or read the output, and `RUST_LOG=debug` to see what `bootc` is
doing.

The invocation known to work here is `run0 --pipe bash <script>` with the
command written to a file, which sidesteps all of the above.

One unexplained data point, recorded rather than guessed at: an earlier
`set-options-for-source` run with identical arguments exited without staging
anything and without printing an error. The successful run differed in using
`--pipe` and a script file. `bootc`'s debug output shows it cares about the
working directory (`Target . is a mountpoint, remounting rw`), which may be
related. If the command appears to no-op, re-run it as above and check
`/run/ostree/staged-deployment` before concluding anything.

## Checklist for adding a karg to the recipe

1. Add it to the `kargs:` block in `recipes/recipe.yml`.
2. Build, then update with **`bootc upgrade`** — never `rpm-ostree`.
3. Reboot and confirm it is on `/proc/cmdline`.
4. If it is missing, check `/usr/lib/bootc/kargs.d/bluebuild-kargs.toml` in the
   booted deployment. Present there but absent from the cmdline means the delta
   was empty — repair it with `set-options-for-source` above.

Step 3 is not optional. The failure mode here is entirely silent.
