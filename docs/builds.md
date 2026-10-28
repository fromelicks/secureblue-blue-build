# Daily image builds

The scheduled workflow rebuilds on the latest secureblue base every day.
Any failing application integration blocks publication of the whole image,
so a persistent failure also delays base hardening updates.

After a scheduled build fails, a separate job opens an issue titled
`Scheduled image build is failing` with the run link. It needs only issue
write permission and does not check out or execute repository code. Further
failures reuse that open issue without adding daily comments. Check Actions
for the latest run, and close the issue after a successful scheduled build;
a later failure will then open a new issue. Push and pull-request builds do
not create these issues. Issue notifications follow GitHub subscription settings.

The DMS 2.0.0 update broke our lock-screen patch on October 21, 2026 and
blocked every scheduled build through October 28. DMS and its patch were
removed because the Niri session is moving to another shell. The alert
addresses the silent-failure part of that incident; it does not decouple
application failures from base-image publication.

Vendor integration assertions and signature checks still fail the build on
unexpected packaging or verification failures. Do not make those steps
best-effort to get a green build. Third-party version pinning is a separate
update-policy change: it needs retained package artifacts and automated bump
PRs to avoid freezing application security updates. This change adds failure
reporting while retaining the existing update policy.
