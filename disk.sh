#!/bin/sh
# Where the disk goes, and how fast it is filling.
#
# Backups live on the same disk as the data they protect, and backup.sh takes a
# full copy every night, so its cost grows as total size x 14. `fluxer status`
# shows free space today, which says nothing about when it runs out. This splits
# usage into the parts that grow (volumes, backups, images) and keeps a dated
# line per run, so growth per day and a days-until-full estimate come from
# measurements rather than a guess.
#
# The history is $BACKUP_ROOT/disk-history.tsv: next to backup.log, written by
# the same user cron, outside the git-tracked ops/ tree, and untouched by backup
# retention (which only removes auto-*).
#
#   ./disk.sh            report, and append to the history
#   ./disk.sh --record   append to the history only, print nothing (cron)
#   ./disk.sh --json     report as JSON, and append to the history
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
BACKUP_ROOT=${BACKUP_ROOT:-/home/ubuntu/Documents/fluxer-backups}
RECORD_DIR=${RECORD_DIR:-$FLUXER_DIR/backups}
HISTORY=${DISK_HISTORY:-$BACKUP_ROOT/disk-history.tsv}
MODE=text
case "${1:-}" in
	'') ;;
	--record) MODE=record ;;
	--json) MODE=json ;;
	*) echo "usage: disk.sh [--record | --json]" >&2; exit 2 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Filesystem holding the deployment, and Docker's, if that is a different one.
df -Pk "$FLUXER_DIR" | awk 'NR == 2 { print $1, $2, $3, $4, $6 }' > "$tmp/fs"
droot=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
if [ -n "$droot" ]; then
	df -Pk "$droot" 2>/dev/null | awk 'NR == 2 { print $1, $2, $3, $4, $6 }' > "$tmp/dockerfs" || true
fi

# Volumes, images and build cache in one call. The daemon measures the volumes
# itself, so no helper container is started (this runs from cron).
docker system df -v --format '{{json .}}' > "$tmp/df-v.json"
docker system df --format '{{json .}}' > "$tmp/df.json"

# kB, one line per backup directory. du reads root-owned tarballs fine: only the
# directories need to be readable.
for d in "$BACKUP_ROOT"/auto-*/; do
	[ -d "$d" ] && du -sk "$d"
done > "$tmp/auto" 2>/dev/null || true
for d in "$RECORD_DIR"/record-*/; do
	[ -d "$d" ] && du -sk "$d"
done > "$tmp/records" 2>/dev/null || true

mkdir -p "$(dirname "$HISTORY")"
python3 - "$tmp" "$HISTORY" "$MODE" <<'PY'
import json, os, re, sys, time
tmp, history, mode = sys.argv[1:4]
units = {"B": 1, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}
def dsize(s):
    m = re.match(r"([\d.]+)\s*([kMGT]?B)", s or "0B")
    return int(float(m.group(1)) * units[m.group(2)]) if m else 0
def human(n):
    sign = "-" if n < 0 else ""
    n = abs(n)
    for u in "BKMGT":
        if n < 1024 or u == "T":
            return f"{sign}{n:.0f}{u}" if u == "B" else f"{sign}{n:.1f}{u}"
        n /= 1024
def read(name):
    p = os.path.join(tmp, name)
    return open(p).read().split("\n") if os.path.exists(p) else []

dev, size, used, avail, mount = read("fs")[0].split()
fs = {"device": dev, "mount": mount, "size": int(size) * 1024, "used": int(used) * 1024, "avail": int(avail) * 1024}
dockerfs = None
line = (read("dockerfs") or [""])[0].split()
if line and line[4] != mount:
    dockerfs = {"device": line[0], "mount": line[4], "size": int(line[1]) * 1024, "used": int(line[2]) * 1024, "avail": int(line[3]) * 1024}

v = json.load(open(os.path.join(tmp, "df-v.json")))
volumes = {x["Name"]: dsize(x["Size"]) for x in v["Volumes"] if x["Name"].startswith("fluxer_")}
totals = {}
for line in read("df.json"):
    if line.strip():
        x = json.loads(line)
        totals[x["Type"]] = x
images = dsize(totals.get("Images", {}).get("Size"))
build_cache = dsize(totals.get("Build Cache", {}).get("Size"))

def dirs(name):
    rows = [l.split("\t") for l in read(name) if l.strip()]
    return len(rows), sum(int(r[0]) * 1024 for r in rows)
auto_n, auto = dirs("auto")
rec_n, rec = dirs("records")

now = int(time.time())
row = [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), now, fs["size"], fs["used"], fs["avail"],
       sum(volumes.values()), auto, rec, images, build_cache]
cols = ["time_utc", "epoch", "fs_size", "fs_used", "fs_avail", "volumes", "backups_scheduled", "backups_installer", "images", "build_cache"]

# Growth against a baseline at least a day old: the oldest line from the last
# 30 days, so a rate reflects recent weeks rather than a year ago; failing that,
# the newest line older than a day.
past = []
if os.path.exists(history):
    for l in open(history):
        if l.startswith("#") or not l.strip():
            continue
        f = l.rstrip("\n").split("\t")
        if len(f) != len(cols):
            continue
        try:
            past.append(dict(zip(cols, [f[0]] + [int(x) for x in f[1:]])))
        except (ValueError, IndexError):
            continue
old = [p for p in past if now - p["epoch"] >= 86400]
recent = [p for p in old if now - p["epoch"] <= 30 * 86400]
base = min(recent, key=lambda p: p["epoch"]) if recent else (max(old, key=lambda p: p["epoch"]) if old else None)

new = not os.path.exists(history) or os.path.getsize(history) == 0
with open(history, "a") as h:
    if new:
        h.write("# " + "\t".join(cols) + "  (sizes in bytes)\n")
    h.write("\t".join(str(x) for x in row) + "\n")
if mode == "record":
    sys.exit(0)

cur = dict(zip(cols, row))
growth = None
if base:
    days = (now - base["epoch"]) / 86400
    rate = lambda k: (cur[k] - base[k]) / days
    per_day = {"fs_used": rate("fs_used"), "volumes": rate("volumes"),
               "backups": rate("backups_scheduled") + rate("backups_installer"), "images": rate("images")}
    full = fs["avail"] / per_day["fs_used"] if per_day["fs_used"] > 0 else None
    growth = {"since": base["time_utc"], "days": round(days, 2),
              "per_day": {k: int(x) for k, x in per_day.items()},
              "days_until_full": None if full is None else round(full, 1)}

if mode == "json":
    print(json.dumps({"time": row[0], "filesystem": fs, "docker_filesystem": dockerfs, "volumes": volumes,
                      "backups": {"scheduled": {"count": auto_n, "bytes": auto}, "installer": {"count": rec_n, "bytes": rec}},
                      "docker": {"images": images, "images_reclaimable_docker": totals.get("Images", {}).get("Reclaimable"),
                                 "build_cache": build_cache},
                      "growth": growth, "history": history}, indent=2))
    sys.exit(0)

pct = fs["used"] * 100 // fs["size"] if fs["size"] else 0
print(f"filesystem  {fs['device']} on {fs['mount']}: {human(fs['avail'])} free of {human(fs['size'])} ({pct}% used)")
if dockerfs:
    print(f"docker fs   {dockerfs['device']} on {dockerfs['mount']}: {human(dockerfs['avail'])} free of {human(dockerfs['size'])}")
print(f"volumes     {human(sum(volumes.values()))}")
for name, b in sorted(volumes.items(), key=lambda kv: -kv[1]):
    print(f"  {name:<26} {human(b):>8}")
print(f"backups     {human(auto + rec)}")
print(f"  {'scheduled (auto-*)':<26} {human(auto):>8}  {auto_n} dirs")
print(f"  {'installer (record-*)':<26} {human(rec):>8}  {rec_n} dirs")
print(f"docker      images {human(images)}, build cache {human(build_cache)}")
print("  (docker calls rollback images reclaimable; they are not. `fluxer prune` shows what really is.)")
if growth:
    p = growth["per_day"]
    print(f"growth      since {growth['since']} ({growth['days']:.1f} days), per day:")
    print(f"  disk used {human(p['fs_used'])}, volumes {human(p['volumes'])}, backups {human(p['backups'])}, images {human(p['images'])}")
    if growth["days_until_full"] is None:
        print("  disk use is not growing, so no fill date.")
    else:
        print(f"  at that rate the disk is full in ~{growth['days_until_full']:.0f} days (naive: linear, whole filesystem).")
else:
    print(f"growth      needs a history line at least a day old ({len(past)} earlier line(s) in {history}).")
PY
