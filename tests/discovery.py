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
ok("opt-in issue parser ignores quotes and bulk mirror dumps")

with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    seed = td / "mirrors.txt"
    current = td / "registry.txt"
    sources = td / "sources.json"
    output = td / "candidates.txt"
    report = td / "report.json"
    denylist = td / "denylist.txt"

    seed.write_text("https://seed.example\n", encoding="utf-8")
    current.write_text("https://current.example\n", encoding="utf-8")
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
        "https://current.example",
        "https://optin.example",
        "https://consensus.example",
    ]
    data = json.loads(report.read_text(encoding="utf-8"))
    assert data["candidate_count"] == 4
    assert data["denylist_count"] == 1
    ok("first-party, opt-in, two-source consensus and denylist rules work")

print(f"PASS={PASS} FAIL=0")
