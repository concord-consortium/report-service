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

# Archives holding a symbolic link, which publish refuses: Info-ZIP's zip -y stores the link
# itself, as Go's archive/zip does for a header with os.ModeSymlink.
mkdir "$src/linked"
cat > "$src/linked/manifest.json" <<'JSON'
{"name": "linked", "title": "Linked", "version": "1.0.0", "entrypoint": "run.py", "expected_duration_seconds": 60}
JSON
cp "$src/run.py" "$src/linked/run.py"
ln -s /etc/passwd "$src/linked/passwd"
touch -h -t 202601010000 "$src/linked/manifest.json" "$src/linked/run.py" "$src/linked/passwd"
rm -f symlink-entry.zip symlink-entry-commented.zip symlink-entrypoint.zip symlink-entry-go.zip
(cd "$src/linked" && zip -X -q -y "$OLDPWD/symlink-entry.zip" manifest.json run.py passwd)
# :zip accepts an Info-ZIP archive comment, so the end record is found by searching backward
cp symlink-entry.zip symlink-entry-commented.zip
echo "a package with a link" | zip -q -z symlink-entry-commented.zip

mkdir "$src/entrypoint"
cat > "$src/entrypoint/manifest.json" <<'JSON'
{"name": "linked", "title": "Linked", "version": "1.0.0", "entrypoint": "start.py", "expected_duration_seconds": 60}
JSON
cp "$src/run.py" "$src/entrypoint/run.py"
ln -s run.py "$src/entrypoint/start.py"
touch -h -t 202601010000 "$src/entrypoint/manifest.json" "$src/entrypoint/run.py" "$src/entrypoint/start.py"
(cd "$src/entrypoint" && zip -X -q -y "$OLDPWD/symlink-entrypoint.zip" manifest.json run.py start.py)

mkdir "$src/golink"
cat > "$src/golink/main.go" <<'GO'
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
	h := &zip.FileHeader{Name: "passwd", Method: zip.Store}
	h.SetMode(os.ModeSymlink | 0777)
	f, _ := w.CreateHeader(h)
	f.Write([]byte("/etc/passwd"))
	w.Close()
	out.Close()
}
GO
(cd "$src/golink" && go run main.go "$OLDPWD/symlink-entry-go.zip" "$src/linked")
