# Security policy

## Supported versions

Security fixes go into the latest release of the current major version. Update to the latest release to get them.

| Version | Security fixes |
|---|---|
| The latest 1.x release | Yes |
| Earlier 1.x releases | No: update to the latest 1.x release |

When a new major version comes out, the last release of the previous major version keeps getting security fixes for
12 months.

## Reporting a vulnerability

Please don't report security problems in public issues, pull requests or discussions. Report them privately, in one
of these ways:

- **On GitHub:** open this repository's **Security** tab and choose **Report a vulnerability**.
- **By email:** write to security@salla.sa.

Please include:

- the SDK and its version, such as "SallaPush iOS SDK 1.1.0", and the platform and OS version;
- what the problem is, and what an attacker could do with it;
- the steps to reproduce it, ideally with a small sample project;
- the SallaPush log codes you saw, if any.

Never include real tokens, keys or customer data. If the problem depends on one of them, describe it instead.

Problems in Salla's servers, websites or other products are outside this repository: report them to
security@salla.sa.

## What happens next

- We confirm that we received your report within 5 business days.
- We investigate it, keep you informed, and tell you when the fix is released.
- Please keep the problem private until the fix is released, or until we agree on a date with you.
- We credit you in the release notes, unless you ask us not to.
