# Security policy

## Supported versions

Until the first stable package release, security fixes are made on the latest
published version and the default branch. Prebuilt native libraries are
supported only when they belong to a release listed by the repository as
**Immutable**.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** form in the repository Security
tab. Do not open a public issue, pull request, or discussion for a suspected
vulnerability. Include the affected package or native-artifact version,
platform and architecture, reproduction steps, impact, and any known
workaround. Never include patient or other sensitive data.

Maintainers aim to acknowledge a report within three business days and provide
an initial assessment within seven business days. Timelines for remediation
and coordinated disclosure depend on severity and upstream involvement. VTK,
Flutter, operating-system, and toolchain vulnerabilities may need coordinated
fixes from their respective projects.

## Supply-chain verification

Native dependency releases contain `SHA256SUMS`, per-asset build manifests, and
GitHub artifact attestations. Verify both the immutable GitHub release and the
downloaded asset as described in `docs/releasing.md`. An attestation proves the
artifact's build origin; it does not by itself prove that the artifact is free
of vulnerabilities.
