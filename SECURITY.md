# Security Policy

Flutter Background Location Tracker handles precise location and route data.
Please report suspected vulnerabilities privately and avoid including real
user locations, exported routes, credentials, or device identifiers in public
issues.

## Supported versions

Security fixes are provided for the latest published package release and the
current default branch. Older releases may not receive patches.

| Version | Supported |
| --- | --- |
| Latest `0.1.x` release | Yes |
| Current default branch | Yes |
| Older releases | No |

This table will be updated when the package adopts a new release line.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting
form](https://github.com/amias-samir/flutter_background_location/security/advisories/new)
to submit a report. If private reporting is temporarily unavailable, contact
the maintainer at [samirdangal@gmail.com](mailto:samirdangal@gmail.com).

Do not open a public issue for an unpatched vulnerability.

Include as much of the following as possible:

- A clear description of the issue and its security or privacy impact.
- The affected package version, commit, platform, and OS version.
- Minimal reproduction steps or a proof of concept.
- Relevant logs with location coordinates, route names, tokens, device IDs, and
  other personal data removed.
- Whether the issue affects Android, iOS, exported files, local storage,
  permissions, background services, mock-location detection, or platform
  channels.
- Any known workaround or suggested mitigation.

You can expect an acknowledgement within 5 business days. The maintainer will
then investigate, confirm the impact, and coordinate a fix and disclosure
timeline. Complex platform-specific issues may require additional time, but
reporters will receive progress updates when practical.

## Disclosure process

After a report is validated, the project will aim to:

1. Develop and test a fix without exposing sensitive details.
2. Prepare a patched release and security advisory.
3. Credit the reporter if they want public acknowledgement.
4. Publish details after users have a reasonable opportunity to update.

Please allow coordinated disclosure before publishing technical details or a
proof of concept.

## Security and privacy expectations

Applications integrating this package remain responsible for obtaining proper
location consent, explaining background collection, applying suitable data
retention, protecting exported routes, and complying with applicable laws and
store policies. Mock-location and motion signals are risk indicators, not proof
that a location is genuine or fraudulent.

For ordinary bugs that have no security or privacy impact, use the repository's
[issue templates](https://github.com/amias-samir/flutter_background_location/issues/new/choose).
