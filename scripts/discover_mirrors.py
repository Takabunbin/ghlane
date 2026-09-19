#!/usr/bin/env python3
"""Discover ghproxy-style GitHub mirrors from multiple public sources."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from collections import OrderedDict, defaultdict
from pathlib import Path
from typing import Iterable

URL_RE = re.compile(r"https://[^\s<>()\[\]{}\"']+")
DENY_HOSTS = {
    "github.com",
    "www.github.com",
    "api.github.com",
    "raw.githubusercontent.com",
    "gist.githubusercontent.com",
    "objects.githubusercontent.com",
    "codeload.github.com",
    "cdn.jsdelivr.net",
    "fastly.jsdelivr.net",
    "gcore.jsdelivr.net",
}
TRAILING = ".,;:!?)]}'\""


def canonicalize(raw: str) -> str | None:
    raw = raw.strip().rstrip(TRAILING)
    if not raw or "TOKEN" in raw.upper() or "<" in raw or ">" in raw:
        return None
    try:
        parts = urllib.parse.urlsplit(raw)
    except ValueError:
        return None
    if parts.scheme.lower() != "https" or not parts.hostname:
        return None
    if parts.username or parts.password or parts.query or parts.fragment:
        return None
    host = parts.hostname.lower().rstrip(".")
    if host in DENY_HOSTS or host.endswith(".githubusercontent.com"):
        return None
    if host == "localhost" or host.endswith(".localhost"):
        return None
    try:
        literal_ip = ipaddress.ip_address(host)
    except ValueError:
        literal_ip = None
    if literal_ip is not None and not literal_ip.is_global:
        return None
    try:
        port = parts.port
    except ValueError:
        return None
    netloc = host
    if port and port != 443:
        netloc += f":{port}"
    path = re.sub(r"/+", "/", parts.path or "").rstrip("/")
    return urllib.parse.urlunsplit(("https", netloc, path, "", ""))


def extract_urls(text: str) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for match in URL_RE.findall(text or ""):
        url = canonicalize(match)
        if url and url not in seen:
            seen.add(url)
            out.append(url)
    return out


def strip_quotes_and_code(text: str) -> str:
    kept: list[str] = []
    fenced = False
    fence = chr(96) * 3
    for line in (text or "").splitlines():
        if line.lstrip().startswith(fence):
            fenced = not fenced
            continue
        if fenced or line.lstrip().startswith(">"):
            continue
        # Markdown strike-through commonly marks retired mirrors in source issues.
        line = re.sub(r"~~.*?~~", "", line)
        kept.append(line)
    return "\n".join(kept)


def extract_optin_post(text: str, max_urls: int = 4) -> list[str]:
    urls = extract_urls(strip_quotes_and_code(text))
    if not urls or len(urls) > max_urls:
        return []
    return urls


def recursive_strings(value) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from recursive_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from recursive_strings(child)


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        old_host = (urllib.parse.urlsplit(req.full_url).hostname or "").lower()
        new_host = (urllib.parse.urlsplit(newurl).hostname or "").lower()
        if old_host != new_host:
            redirected.remove_header("Authorization")
        return redirected


def fetch_bytes(url: str, token: str | None = None, timeout: int = 15) -> bytes:
    headers = {
        "User-Agent": "ghlane-mirror-discovery/0.2",
        "Accept": "application/vnd.github+json",
    }
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    if token and host == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    opener = urllib.request.build_opener(SafeRedirectHandler())
    with opener.open(request, timeout=timeout) as response:
        return response.read(1_048_576)


def fetch_text(url: str, token: str | None = None) -> str:
    return fetch_bytes(url, token=token).decode("utf-8", "replace")


def read_urls_file(path: Path) -> list[str]:
    if not path.exists():
        return []
    out: list[str] = []
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        url = canonicalize(line)
        if url and url not in seen:
            seen.add(url)
            out.append(url)
    return out


def fetch_github_issue(source: dict, token: str | None) -> list[str]:
    repo = source["repo"]
    issue = int(source["issue"])
    base = f"https://api.github.com/repos/{repo}/issues/{issue}"
    issue_obj = json.loads(fetch_text(base, token=token))
    posts = [issue_obj.get("body") or ""]
    page = 1
    while True:
        url = f"{base}/comments?per_page=100&page={page}"
        batch = json.loads(fetch_text(url, token=token))
        if not batch:
            break
        posts.extend(item.get("body") or "" for item in batch)
        if len(batch) < 100:
            break
        page += 1
        if page > 10:
            break
    out: list[str] = []
    seen: set[str] = set()
    for post in posts:
        for url in extract_optin_post(post):
            if url not in seen:
                seen.add(url)
                out.append(url)
    return out


def discover_source(source: dict, token: str | None) -> list[str]:
    kind = source["type"]
    if kind == "github_issue_optin":
        return fetch_github_issue(source, token)
    text = fetch_text(source["url"], token=token)
    if kind == "text_urls":
        return extract_urls(text)
    if kind == "json_urls":
        payload = json.loads(text)
        out: list[str] = []
        seen: set[str] = set()
        for value in recursive_strings(payload):
            for url in extract_urls(value):
                if url not in seen:
                    seen.add(url)
                    out.append(url)
        return out
    raise ValueError(f"unsupported source type: {kind}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", default="sources.json")
    parser.add_argument("--seed", default="mirrors.txt")
    parser.add_argument("--current", default="registry.txt")
    parser.add_argument("--output", required=True)
    parser.add_argument("--report")
    parser.add_argument("--denylist", default="denylist.txt")
    parser.add_argument("--hint-quorum", type=int, default=2)
    parser.add_argument("--per-source-cap", type=int, default=32)
    parser.add_argument("--max-candidates", type=int, default=128)
    args = parser.parse_args()

    source_defs = json.loads(Path(args.sources).read_text(encoding="utf-8"))
    token = os.environ.get("GITHUB_TOKEN")
    denied = set(read_urls_file(Path(args.denylist)))
    accepted: OrderedDict[str, None] = OrderedDict()
    provenance: dict[str, list[dict]] = defaultdict(list)
    hint_sources: dict[str, set[str]] = defaultdict(set)
    source_results: list[dict] = []

    def accept(url: str, source: str, trust: str) -> None:
        if url in denied:
            return
        accepted.setdefault(url, None)
        provenance[url].append({"source": source, "trust": trust})

    seed_urls = read_urls_file(Path(args.seed))
    for url in seed_urls:
        accept(url, "manual seed", "first_party")
    source_results.append({"name": "manual seed", "trust": "first_party", "count": len(seed_urls), "ok": True})

    incumbent_urls = read_urls_file(Path(args.current))
    for url in incumbent_urls:
        provenance[url].append({"source": "current registry", "trust": "incumbent"})
    source_results.append({"name": "current registry", "trust": "incumbent", "count": len(incumbent_urls), "ok": True})

    for source in source_defs:
        name = source["name"]
        trust = source.get("trust", "hint")
        try:
            discovered = discover_source(source, token)
            urls = discovered[: args.per_source_cap]
            source_results.append({
                "name": name,
                "trust": trust,
                "count": len(urls),
                "discovered": len(discovered),
                "truncated": max(0, len(discovered) - len(urls)),
                "ok": True,
            })
        except Exception as exc:
            print(f"WARN  source failed: {name}: {exc}", file=sys.stderr)
            source_results.append({"name": name, "trust": trust, "count": 0, "discovered": 0, "truncated": 0, "ok": False})
            continue
        for url in urls:
            if url in denied:
                continue
            provenance[url].append({"source": name, "trust": trust})
            if trust == "optin":
                accepted.setdefault(url, None)
            elif trust == "hint":
                hint_sources[url].add(name)
            else:
                print(f"WARN  unknown trust '{trust}' for {name}", file=sys.stderr)

    for url, names in sorted(hint_sources.items()):
        if url not in denied and len(names) >= args.hint_quorum:
            accepted.setdefault(url, None)

    candidates_all = list(accepted)
    candidates = candidates_all[: args.max_candidates]
    dropped_by_cap = max(0, len(candidates_all) - len(candidates))

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(f"{url}\n" for url in candidates), encoding="utf-8")
    report = {
        "candidate_count": len(candidates),
        "candidate_count_before_cap": len(candidates_all),
        "dropped_by_cap": dropped_by_cap,
        "denylist_count": len(denied),
        "hint_quorum": args.hint_quorum,
        "candidates": [
            {"url": url, "provenance": provenance.get(url, [])}
            for url in candidates
        ],
        "sources": source_results,
    }
    if args.report:
        Path(args.report).write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
            encoding="utf-8",
        )

    print("=== ghlane mirror discovery ===")
    for result in source_results:
        state = "OK" if result["ok"] else "FAIL"
        print(f"{state:4}  {result['name']}: {result['count']}")
    print(f"denylisted endpoints: {len(denied)}")
    print(f"accepted candidates: {len(candidates)} (dropped_by_cap={dropped_by_cap})")
    for url in candidates:
        print(f"CAND  {url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
