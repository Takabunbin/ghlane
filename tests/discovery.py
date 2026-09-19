#!/usr/bin/env python3
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "discover_mirrors.py"

spec = importlib.util.spec_from_file_location("discover_mirrors", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

PASS = 0


def ok(name):
    global PASS
    PASS += 1
    print(f"PASS  {name}")


assert mod.canonicalize("https://GH.Example/") == "https://gh.example"
assert mod.canonicalize("https://user:TOKEN@ghproxy.com") is None
assert mod.canonicalize("http://gh.example") is None
assert mod.canonicalize("https://github.com/a/b") is None
ok("URL canonicalization rejects credentials, non-HTTPS and GitHub originals")

post = """
Thanks:
https://one.example/
~~https://retired.example/~~
https://two.example
> https://quoted.example
"""
assert mod.extract_optin_post(post) == ["https://one.example", "https://two.example"]
bulk = "\n".join(f"https://m{i}.example" for i in range(5))
assert mod.extract_optin_post(bulk) == []
ok("opt-in parser ignores quotes, retired links and bulk dumps")


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, limit):
        return b"ok"


class FakeOpener:
    def __init__(self, seen):
        self.seen = seen

    def open(self, request, timeout=0):
        self.seen.append(dict(request.header_items()))
        return FakeResponse()


seen = []
original_build_opener = mod.urllib.request.build_opener
mod.urllib.request.build_opener = lambda *args, **kwargs: FakeOpener(seen)
try:
    mod.fetch_bytes("https://api.github.com/repos/o/r", token="SECRET")
    mod.fetch_bytes("https://raw.githubusercontent.com/o/r/main/list", token="SECRET")
finally:
    mod.urllib.request.build_opener = original_build_opener

assert seen[0].get("Authorization") == "Bearer SECRET"
assert "Authorization" not in seen[1]
ok("GitHub token is sent only to api.github.com")


with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    seed = td / "mirrors.txt"
    current = td / "registry-v1.txt"
    sources = td / "sources.json"
    output = td / "candidates.txt"
    report = td / "report.json"
    denylist = td / "denylist.txt"

    seed.write_text("https://seed.example\n", encoding="utf-8")
    current.write_text(
        "# ghlane-registry-v1\nhttps://incumbent.example\n",
        encoding="utf-8",
    )
    denylist.write_text("https://denied.example\n", encoding="utf-8")
    sources.write_text(
        json.dumps(
            [
                {"name": "opt", "type": "fixture", "trust": "optin"},
                {"name": "hint-a", "type": "fixture", "trust": "hint"},
                {"name": "hint-b", "type": "fixture", "trust": "hint"},
                {"name": "hint-c", "type": "fixture", "trust": "hint"},
            ]
        ),
        encoding="utf-8",
    )

    fixture = {
        "opt": ["https://optin.example", "https://denied.example"],
        "hint-a": ["https://consensus.example", "https://single.example", "https://denied.example"],
        "hint-b": ["https://consensus.example", "https://denied.example"],
        "hint-c": ["https://other.example"],
    }

    original = mod.discover_source
    mod.discover_source = lambda source, token: fixture[source["name"]]
    old_argv = sys.argv[:]
    try:
        sys.argv = [
            str(SCRIPT),
            "--sources",
            str(sources),
            "--seed",
            str(seed),
            "--current",
            str(current),
            "--output",
            str(output),
            "--report",
            str(report),
            "--denylist",
            str(denylist),
        ]
        assert mod.main() == 0
    finally:
        sys.argv = old_argv
        mod.discover_source = original

    got = output.read_text(encoding="utf-8").splitlines()
    assert got == [
        "https://seed.example",
        "https://optin.example",
        "https://consensus.example",
    ]
    data = json.loads(report.read_text(encoding="utf-8"))
    assert data["candidate_count"] == 3
    assert data["denylist_count"] == 1
    assert "https://incumbent.example" not in got
    incumbent = next(c for c in data["candidates"] if c["url"] == "https://seed.example")
    assert incumbent["provenance"][0]["trust"] == "first_party"
    ok("incumbent registry is not promoted to first-party trust")

with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    seed = td / "seed.txt"
    current = td / "current.txt"
    sources = td / "sources.json"
    output = td / "out.txt"
    report = td / "report.json"
    denylist = td / "deny.txt"

    seed.write_text("https://seed.example\n", encoding="utf-8")
    current.write_text("# ghlane-registry-v1\n", encoding="utf-8")
    denylist.write_text("", encoding="utf-8")
    sources.write_text(
        json.dumps([{"name": "opt", "type": "fixture", "trust": "optin"}]),
        encoding="utf-8",
    )
    fixture = {"opt": [f"https://m{i}.example" for i in range(5)]}

    original = mod.discover_source
    mod.discover_source = lambda source, token: fixture[source["name"]]
    old_argv = sys.argv[:]
    try:
        sys.argv = [
            str(SCRIPT),
            "--sources", str(sources),
            "--seed", str(seed),
            "--current", str(current),
            "--denylist", str(denylist),
            "--output", str(output),
            "--report", str(report),
            "--per-source-cap", "2",
            "--max-candidates", "2",
        ]
        assert mod.main() == 0
    finally:
        sys.argv = old_argv
        mod.discover_source = original

    data = json.loads(report.read_text(encoding="utf-8"))
    assert output.read_text(encoding="utf-8").splitlines() == [
        "https://seed.example",
        "https://m0.example",
    ]
    assert data["dropped_by_cap"] == 1
    external = next(x for x in data["sources"] if x["name"] == "opt")
    assert external["discovered"] == 5
    assert external["count"] == 2
    assert external["truncated"] == 3
    ok("per-source and total caps degrade gracefully instead of failing discovery")

print(f"PASS={PASS} FAIL=0")
