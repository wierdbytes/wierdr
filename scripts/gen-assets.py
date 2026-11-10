#!/usr/bin/env python3
"""Generate App/Resources/Icons.xcassets from Design/icons.

  Design/icons/*.svg            -> "ui.<name>"        (template: tinted by the UI)
  Design/icons/programs/*.svg   -> "program.<name>"   (template unless programs.json says tint:false)
  Design/icons/providers/*.svg  -> "provider.<name>"  (template)

SVGs keep their vector data, so they stay sharp at any size.
"""
import json, os, shutil, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Design", "icons")
OUT = os.path.join(ROOT, "App", "Resources", "Icons.xcassets")
programs = json.load(open(os.path.join(ROOT, "App", "Resources", "programs.json")))["programs"]
untinted = {os.path.basename(v.get("icon", "")) for v in programs.values() if v.get("tint") is False}

shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(OUT)
json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, "Contents.json"), "w"))

def add(prefix, path, template):
    name = os.path.splitext(os.path.basename(path))[0]
    d = os.path.join(OUT, f"{prefix}.{name}.imageset")
    os.makedirs(d)
    shutil.copy(path, os.path.join(d, os.path.basename(path)))
    contents = {
        "images": [{"filename": os.path.basename(path), "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True,
                       "template-rendering-intent": "template" if template else "original"},
    }
    json.dump(contents, open(os.path.join(d, "Contents.json"), "w"), indent=1)

n = 0
for f in sorted(os.listdir(SRC)):
    if f.endswith(".svg"):
        add("ui", os.path.join(SRC, f), True); n += 1
for f in sorted(os.listdir(os.path.join(SRC, "programs"))):
    if f.endswith(".svg"):
        add("program", os.path.join(SRC, "programs", f), f not in untinted); n += 1
for f in sorted(os.listdir(os.path.join(SRC, "providers"))):
    if f.endswith(".svg"):
        add("provider", os.path.join(SRC, "providers", f), True); n += 1
print(f"{n} icons -> {OUT}")
