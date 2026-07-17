# Security policy

## Supported versions

The package has not been published. Security fixes are made on the default
branch until a supported release policy is announced. Prebuilt native
libraries are supported only when they belong to a repository release marked
**Immutable** and match the artifact contract pinned by the source revision.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** form in the repository Security tab.
Do not open a public issue, pull request, or discussion for a suspected
vulnerability. Include the affected source revision or native-artifact
version, platform and architecture, reproduction steps, impact, and any known
workaround. Do not include private or sensitive input data.

Maintainers aim to acknowledge a report within three business days and provide
an initial assessment within seven business days. Timelines for remediation
and coordinated disclosure depend on severity and upstream involvement. VTK,
Flutter, operating-system, and toolchain vulnerabilities may need coordinated
fixes from their respective projects.

## Supply-chain verification

Native dependency releases contain `SHA256SUMS`, per-target build manifests,
license notices, and GitHub artifact attestations. Verify the immutable GitHub
release and downloaded asset as described in
[`doc/native-artifacts.md`](../doc/native-artifacts.md). An attestation
proves build origin; it does not by itself prove that an artifact is free of
vulnerabilities.
