#!/bin/sh
# Rebuild the generated non-Indian rules from tool/world-harvest.json (a clean slate).
cd "$(dirname "$0")/.."
git checkout -- rules/iran/country.json rules/thailand/country.json
for c in rules tests/conformance; do
  for d in $c/*/; do
    n=$(basename "$d")
    case "$n" in india) continue;; esac
    for b in "$d"*/; do
      bn=$(basename "$b")
      case "$n/$bn" in iran/parsian|thailand/bangkok) continue;; esac
      rm -rf "$b"
    done
    [ "$c" = rules ] || continue
    case "$n" in iran|thailand) ;; *) rm -f "$d/country.json"; rmdir "$d" 2>/dev/null;; esac
  done
done
rm -rf distribution/packs/*/
(cd tool && PYTHONIOENCODING=utf-8 python migrate_world.py)
(cd engines/dart && dart run tool/compile_rules.dart ../../distribution/packs ../../rules)
python tool/generate_manifest.py
