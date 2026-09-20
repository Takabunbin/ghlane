# Security model

ghlane accelerates a deliberately narrow class of requests: public GitHub Release
asset downloads. The security rule is fail-closed: when ghlane cannot prove that
an accelerated transfer is safe, it executes the original system curl/wget
command against GitHub instead.

## Trust boundaries

- GitHub and the GitHub Releases API are the integrity trust root.
- Public acceleration mirrors are **not** trusted for content integrity.
- `mirrors.txt` is the manually approved production mirror set.
- Automated mirror discovery is untrusted input. Discovery runs in a read-only
  job and cannot modify the repository.
- `registry-v1.txt` may include bounded, health-checked discovered endpoints.
  v1 clients do not trust those endpoints: every accelerated asset is verified
  against GitHub's SHA-256 metadata before it becomes visible to the caller.
- Legacy `registry.txt` is deliberately DIRECT-only. It contains an unusable
  GitHub prefix so 0.2.0 clients, which lack end-to-end digest verification,
  cannot successfully use a mirror from the remote registry.

## Integrity

An accelerated transfer is attempted only when all of the following hold:

1. The URL is a public `https://github.com/.../releases/download/...` asset URL.
2. The command uses a supported, conservative curl/wget option set.
3. The destination is one explicit, previously non-existent output file.
4. GitHub's Releases API provides a valid SHA-256 digest and size for the exact
   asset.
5. The complete downloaded file matches both that size and SHA-256 digest.

Expected digest metadata is fetched fresh from GitHub for each accelerated
transfer. ghlane intentionally does not cache integrity metadata, avoiding a
stale-digest replay window when a Release asset is replaced.

Mirror output is first written to a temporary file beside the requested
destination. It is moved into place only after verification. A mirror transfer
that fails or does not match GitHub metadata is discarded; ghlane clears that
route and retries the same request directly from GitHub into a fresh temporary
file, verifying it before commit.

If Python 3, SHA-256 tooling, GitHub metadata, or a safe temporary file is not
available, ghlane does not weaken verification: it bypasses acceleration and
runs the original command directly.

## Credential and option safety

ghlane uses a safe allowlist for accelerated curl/wget options. Unknown options,
credential/header/cookie/config/proxy/TLS override/referer/query mutation
options, partial/range/resume semantics, multiple URLs, implicit user config,
and possible netrc credentials cause a direct bypass.

This is intentional. New curl/wget options default to DIRECT until explicitly
reviewed.

## Registry protocol

The remote production registry uses the line protocol `ghlane-registry-v1`:

```text
# ghlane-registry-v1
https://mirror.example
```

Clients reject a wrong/missing protocol header, non-HTTPS entries, malformed
entries, and registries above their configured size cap. A syntactically valid
empty v1 registry means DIRECT-only.

Central health checks compare a fixed GitHub Release sample byte-for-byte.
This proves protocol/content compatibility for the canary only; it is **not** a
trust grant. Mirror admission is not an integrity trust grant; every v1 user transfer is
independently verified against GitHub's asset digest.

A GitHub-hosted runner is only one network viewpoint. A previously published
v1 endpoint may be retained across a transient runner-only network failure, but
a content/protocol mismatch is a hard rejection. Client-side full-file digest
verification remains mandatory regardless of how the endpoint entered v1.

## Discovery

External discovery sources are untrusted hints.

- GitHub credentials are sent only to `api.github.com`, never generic source
  URLs, and are stripped on cross-host redirects.
- Source and total candidate counts are bounded.
- Existing registry membership does not become first-party trust.
- Denylisted/retired endpoints are excluded.
- Discovery runs read-only and publishes only a workflow artifact/report.
- A separate write-scoped job consumes that artifact strictly as URL data,
  performs byte-for-byte canary checks, and may place verified discoveries only
  in the versioned v1 registry. The legacy registry remains DIRECT-only.

## Installer and updates

Installer upgrades preserve existing configuration, migrate only the old
official registry URL to v1, and stage all replacement files before committing
them. Commit order is mirrors -> core -> config: a new core safely tolerates
the old legacy registry configuration, while an old core is never left pointing
at dynamic v1. Existing custom `/usr/local/bin/curl` or `wget` files are
never overwritten.

The installer payload is intended to be pinned to an immutable commit for
normal installation. `GHLANE_REF` remains an explicit operator override.

## Non-security limitations

- Unsupported/ambiguous command forms intentionally bypass acceleration.
- Files that already exist at the requested destination bypass acceleration to
  preserve curl/wget overwrite, link, and resume semantics.
- DIRECT remains available at all times.
- No client daemon or cron job is installed.

Security reports should include a minimal reproducer, affected ghlane version,
and whether the issue can cause content substitution, credential disclosure, or
unexpected replacement of local files.
