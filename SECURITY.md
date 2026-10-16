# Security policy

Debora changes Windows settings with administrator rights, so security reports are taken seriously.

## Supported versions

Only the [latest release](https://github.com/okalinon/debora/releases/latest) receives fixes. Debora updates itself,
so please update before reporting.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Use
[GitHub private vulnerability reporting](https://github.com/okalinon/debora/security/advisories/new) and include:

- the Debora version and Windows version (Settings → System → About);
- what an attacker could do and the steps to reproduce;
- if possible, the diagnostics zip (*Change history → Collect diagnostics*), with anything private removed.

You will get an answer within a week. Fixed issues are published in the release notes and
[CHANGELOG](CHANGELOG.md).

## How releases are protected

- Release builds are made by [GitHub Actions](.github/workflows/release.yml) from this repository.
- Every release lists SHA-256 checksums; self-update refuses an archive whose checksum does not match.
- The scheduled-maintenance copy of Debora lives in `%ProgramData%\Debloater9\app`, writable only by SYSTEM and
  administrators.
