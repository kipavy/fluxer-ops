#!/usr/bin/env python3
"""registry.py - ask a container registry about tags, anonymously.

The same token dance `docker pull` does, stdlib only. Used by changelog.sh (what
an update would bring) and autoupdate.sh (is there an update at all).

  registry.py manifests <os/arch> <ref>...
      One line per ref: "<ref> <version> <revision> <digest> <status>".
      version and revision are the org.opencontainers.image.* labels of the
      image for that platform, "-" when absent. digest is the tag's digest (the
      index digest for a multi-arch tag: what RepoDigests records after a pull).
      status is "ok", or why that ref could not be read; a ref that fails does
      not stop the others.
  registry.py tags <host/repo>
      Every tag of the repository, one per line.
"""
import json
import re
import sys
import urllib.error
import urllib.request

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])
tokens = {}


def get(host, repo, path, accept):
    url = f"https://{host}/v2/{repo}/{path}"
    for attempt in (0, 1):
        h = {"Accept": accept}
        if repo in tokens:
            h["Authorization"] = "Bearer " + tokens[repo]
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=20) as r:
                return r.headers, r.read()
        except urllib.error.HTTPError as e:
            auth = e.headers.get("WWW-Authenticate", "")
            if e.code != 401 or attempt or not auth.startswith("Bearer"):
                raise
            p = dict(re.findall(r'(\w+)="([^"]*)"', auth))
            q = f"{p['realm']}?service={p.get('service', '')}&scope=repository:{repo}:pull"
            with urllib.request.urlopen(q, timeout=20) as r:
                j = json.load(r)
            tokens[repo] = j.get("token") or j.get("access_token")
    raise RuntimeError("unreachable")


def manifests(platform, refs):
    os_, arch = platform.split("/", 1)
    for ref in refs:
        name, _, tag = ref.rpartition(":")
        host, _, repo = name.partition("/")
        try:
            hdr, body = get(host, repo, "manifests/" + tag, ACCEPT)
            digest = hdr.get("Docker-Content-Digest", "-")
            m = json.loads(body)
            if "manifests" in m:
                pick = [x for x in m["manifests"] if x.get("platform", {}).get("os") == os_
                        and x.get("platform", {}).get("architecture") == arch]
                if not pick:
                    print(ref, "-", "-", digest, "no image for " + platform)
                    continue
                _, body = get(host, repo, "manifests/" + pick[0]["digest"], ACCEPT)
                m = json.loads(body)
            _, body = get(host, repo, "blobs/" + m["config"]["digest"], "*/*")
            labels = json.loads(body).get("config", {}).get("Labels") or {}
            print(ref, labels.get("org.opencontainers.image.version") or "-",
                  labels.get("org.opencontainers.image.revision") or "-", digest, "ok")
        except Exception as e:
            print(ref, "-", "-", "-", "registry: " + str(e).replace("\n", " ")[:80])


def tags(name):
    host, _, repo = name.partition("/")
    _, body = get(host, repo, "tags/list?n=10000", "application/json")
    for t in json.loads(body).get("tags") or []:
        print(t)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "manifests":
        manifests(sys.argv[2], sys.argv[3:])
    elif len(sys.argv) == 3 and sys.argv[1] == "tags":
        tags(sys.argv[2])
    else:
        sys.exit("usage: registry.py manifests <os/arch> <ref>... | tags <host/repo>")
