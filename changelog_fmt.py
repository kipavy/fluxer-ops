#!/usr/bin/env python3
"""changelog_fmt.py - commit subjects into a changelog a human wants to read.

Upstream writes Conventional Commits (`feat(threads): ...`, `fix(app,api): ...`)
but no release notes, and an update typically brings 100+ commits of which a
third is CI, i18n refreshes, tests and desktop-shell work that never reaches a
self-hosted server. This keeps what an instance owner cares about, grouped:

  heads-up   breaking (`!`, BREAKING), reverts, and feat/chore removals (`remove X`)
  new        feat
  fixes      fix, perf
  other      subjects that are not Conventional Commits
  hidden     ci, chore, test, docs, refactor, build, style, and anything whose
             scopes are all desktop/CI/tooling: counted, not listed

Reads "<sha>\\t<subject>" lines on stdin, writes chat markdown (Fluxer/Discord)
on stdout. Used by `changelog.sh --summary`, which autoupdate.sh posts.

  changelog_fmt.py [--compare URL]
"""
import re
import sys

CONVENTIONAL = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?: (?P<text>.+)$")
HIDDEN_TYPES = {"ci", "chore", "test", "docs", "refactor", "build", "style"}
HIDDEN_SCOPES = {"desktop", "ci", "repo", "tooling"}
REMOVAL = re.compile(r"^(remove|drop)\b", re.I)
CAPS = {"notable": 15, "new": 30, "fixes": 25, "other": 10}
TITLES = {"notable": "⚠️ À noter", "new": "✨ Nouveautés", "fixes": "🐛 Corrections", "other": "Autres"}


def classify(subject):
    """-> (group, line) where group is notable/new/fixes/other/hidden."""
    m = CONVENTIONAL.match(subject)
    if not m:
        return "other", subject
    kind, scope, text = m["type"], m["scope"] or "", m["text"]
    scopes = {s.strip() for s in scope.split(",") if s.strip()}
    line = f"{scope}: {text}" if scope else text
    if m["bang"] or "BREAKING" in subject or kind == "revert":
        return "notable", line
    if scopes and scopes <= HIDDEN_SCOPES:
        return "hidden", line
    if kind in ("feat", "chore") and REMOVAL.match(text):
        return "notable", line
    if kind == "feat":
        return "new", line
    if kind in ("fix", "perf"):
        return "fixes", line
    if kind in HIDDEN_TYPES:
        return "hidden", line
    return "other", line


def render(subjects, compare=""):
    groups = {k: [] for k in ("notable", "new", "fixes", "other", "hidden")}
    for s in subjects:
        g, line = classify(s)
        groups[g].append(line)
    out = []
    for g in ("notable", "new", "fixes", "other"):
        items = groups[g]
        if not items:
            continue
        out.append(f"**{TITLES[g]} ({len(items)})**")
        out += [f"- {i}" for i in items[:CAPS[g]]]
        if len(items) > CAPS[g]:
            out.append(f"- … et {len(items) - CAPS[g]} autres")
        out.append("")
    tail = []
    if groups["hidden"]:
        tail.append(f"_{len(groups['hidden'])} commits masqués (CI, i18n, tests, docs, refactor, desktop)_")
    if compare:
        tail.append(f"Tout voir : <{compare}>")
    if not subjects:
        tail.insert(0, "Aucun commit à lister.")
    return "\n".join(out + tail).strip() + "\n"


def main(argv):
    compare = ""
    if len(argv) == 2 and argv[0] == "--compare":
        compare = argv[1]
    elif argv:
        sys.exit("usage: changelog_fmt.py [--compare URL] < 'sha<TAB>subject' lines")
    subjects = [l.split("\t", 1)[-1].strip() for l in sys.stdin if l.strip()]
    sys.stdout.write(render(subjects, compare))


if __name__ == "__main__":
    main(sys.argv[1:])
