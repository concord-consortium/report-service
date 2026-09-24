#!/usr/bin/env bash
# Rebuilds the package fixtures byte for byte: fixed mtimes, sorted entries, no extra fields.
# class-counts-1.0.6.zip is written by Info-ZIP; class-counts-go-1.0.6.zip by Go's archive/zip,
# as cc-data-cli writes packages, which sets flag 0x8 and leaves the local header's sizes zero.
set -euo pipefail
export TZ=UTC
cd "$(dirname "$0")"

src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT

cat > "$src/manifest.json" <<'JSON'
{
  "name": "class-counts",
  "title": "Class counts",
  "version": "1.0.6",
  "description": "Counts the students in a class who answered each question.",
  "urls": { "all": [], "any": ["*collaborative-learning/*unit=dataflow*"], "none": [] },
  "clue_prepull": true,
  "entrypoint": "run.py",
  "expected_duration_seconds": 120
}
JSON

cat > "$src/run.py" <<'PY'
print("class counts")
PY

touch -t 202601010000 "$src/manifest.json" "$src/run.py"
rm -f class-counts-1.0.6.zip class-counts-go-1.0.6.zip
(cd "$src" && zip -X -q "$OLDPWD/class-counts-1.0.6.zip" manifest.json run.py)

mkdir "$src/go"
cat > "$src/go/main.go" <<'GO'
package main

import ("archive/zip"; "os")

func main() {
	out, _ := os.Create(os.Args[1])
	w := zip.NewWriter(out)
	for _, name := range []string{"manifest.json", "run.py"} {
		data, _ := os.ReadFile(os.Args[2] + "/" + name)
		f, _ := w.Create(name)
		f.Write(data)
	}
	w.Close()
	out.Close()
}
GO
(cd "$src/go" && go run main.go "$OLDPWD/class-counts-go-1.0.6.zip" "$src")
