# Security policy

## Supported versions

Only the latest release on `main` gets fixes. The in-game System page shows
your version, and its `CHECK` / `UPDATE` buttons install the latest one.

| Version | Supported |
| --- | --- |
| 4.2 (latest) | Yes |
| Older | No: update first |

## What counts as a security issue

The program runs on in-game computers, but some parts reach outside the
game:

- **The installer and in-game updater** download code over HTTP from this
  repository (`install.lua`, `updater.lua`).
- **Remote logging** sends log lines over HTTP(S) with a token
  (`log_shipper.lua`) to the collector (`tools/log_collector.py`), which
  runs on a real computer and listens on a network port.
- **Server-side effects**: a fault that lets other players on a
  multiplayer server trigger a reactor explosion, or crash or lag the
  server.

Examples:

- a way to make the updater run code that isn't from this repository;
- a collector bug that allows writing outside its log directory, or
  reading files;
- token leaks;
- a crafted input that makes the controller drive a reactor unsafe.

Normal control bugs, such as a reactor running hotter than configured, are
ordinary bugs: report them as issues.

## Reporting a vulnerability

Please **don't open a public issue**. Report privately through GitHub:
[Report a vulnerability](https://github.com/owzo/CC-Tweaked-Draconic-Manager/security/advisories/new)
(Security tab, then "Report a vulnerability"). Include:

- what is affected and how to reproduce it;
- versions (manager, CC: Tweaked, the mod, Python for the collector);
- the impact you expect.

This is a hobby project maintained by one person. Expect:

- an acknowledgement within about a week;
- a fix or a mitigation plan as soon as practical;
- credit in the release notes, unless you prefer to stay anonymous.

## Hardening tips

- Keep the collector on a private network or behind a firewall, and give
  it a long random `--token`. It speaks plain HTTP, so if logs must cross
  the internet, put it behind an HTTPS reverse proxy. See "Logs on a real
  computer" in the README.
- Only allow the collector's address in `computercraft-server.toml`, not
  whole private ranges.
- Install from this repository's `main` branch; keep `config.update.repoBase`
  pointing at it unless you run your own fork.
