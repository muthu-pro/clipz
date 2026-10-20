# Security Policy

Clipz stores your clipboard history locally and is built privacy-first, so we
take security reports seriously.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, email **mail@muthu.pro** with:

- a description of the issue and its impact,
- steps to reproduce (a proof of concept if possible),
- the Clipz version / build number and your macOS version.

You can expect an acknowledgement within a few days. We'll work with you on a
fix and coordinate disclosure once a patched build is available. Credit is
given to reporters who wish to be named.

## Supported versions

Clipz is distributed as a rolling release; only the **latest** released build
receives security fixes. Please upgrade before reporting.

## Scope

Clipz runs entirely on-device with no servers, accounts, or cloud sync, so the
relevant surface is local: clipboard data at rest, the biometric lock,
sensitive-clip handling, and the app's file/keychain access. Reports about
these are in scope.
