#!/usr/bin/env python3
"""Regenerates QLSupportedContentTypes in Extension/Info.plist.

macOS prefers a Quick Look extension that names a file's exact type (e.g. public.c-source) over one that only
claims a parent type (public.source-code), so every installed type conforming to source code or script is listed.
"""
import plistlib, re, subprocess, os, json
LSR = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
dump = subprocess.run([LSR, '-dump'], capture_output=True, text=True, errors='ignore').stdout
types = {}
for block in re.split(r'\n-{20,}\n', dump):
    m = re.search(r'^uti:\s+(\S+)', block, re.M)
    if m:
        c = re.search(r'^conforms to:\s+(.*)$', block, re.M)
        types[m.group(1)] = [x.strip() for x in c.group(1).split(',')] if c else []

def conforms(t, target, seen=()):
    if t == target: return True
    return t not in seen and any(conforms(p, target, seen + (t,)) for p in types.get(t, []))

BASE = ['public.source-code', 'public.script', 'public.shell-script', 'public.text', 'public.plain-text', 'public.json',
        'public.xml', 'public.yaml', 'public.toml', 'public.ini', 'public.conf', 'public.properties', 'public.typescript',
        'public.make-source', 'public.diff', 'public.patch-file', 'com.apple.property-list', 'com.apple.xml-property-list',
        'public.mpeg-2-transport-stream',  # .ts is TypeScript far more often than video
        'public.data', 'public.item']
found = [t for t in types if not t.startswith('dyn.') and (conforms(t, 'public.source-code') or conforms(t, 'public.script'))]

# Everything the Syntax Highlight app handled (snapshot taken from its Info.plists), so replacing it loses nothing.
here = os.path.dirname(os.path.abspath(__file__))
snap = json.load(open(os.path.join(here, 'syntax-highlight-snapshot.json')))

# Extra types of our own: ".env" files (extension-based; the bare ".env" dotfile is covered by public.data).
OWN_EXPORTS = [{
    'UTTypeIdentifier': 'com.martin.squint.dotenv', 'UTTypeDescription': 'Environment Variables File',
    'UTTypeConformsTo': ['public.source-code'], 'UTTypeTagSpecification': {'public.filename-extension': ['env']},
}]
# Exports in Apple's/system namespaces can't be re-declared by a third-party app.
exported = [e for e in snap['exported'] if not e['UTTypeIdentifier'].startswith(('com.apple.', 'public.'))] + OWN_EXPORTS
# Other editors' code types (tools/editor-types.json "exported"), declared here too so Squint can claim them as Owner.
editor_kinds = json.load(open(os.path.join(here, 'editor-types.json')))
known = {e['UTTypeIdentifier'] for e in exported}
exported += [e for e in editor_kinds['exported'] if e['UTTypeIdentifier'] not in known]
exported_ids = [e['UTTypeIdentifier'] for e in exported]

ordered = list(dict.fromkeys(BASE + sorted(found) + snap['supported'] + exported_ids))

# The app edits everything the preview shows (except public.item: folders, apps, …) plus the text types other editors
# claim (editor-types.json "extra"). LaunchServices honours rank Owner only for types the app declares, so those (and
# public.data) are Owner and win over apps claiming them at the usual Default rank; the rest are Default. TeX files
# (editor-types.json "tex") are Alternate, so a TeX app keeps them.
def document_types(types, own):
    tex = set(editor_kinds['tex'])
    own = set(own) | {'public.data'}
    types = list(dict.fromkeys([t for t in types if t != 'public.item'] + editor_kinds['extra']))
    return [
        {'CFBundleTypeName': 'Source Code', 'CFBundleTypeRole': 'Editor', 'LSHandlerRank': 'Owner',
         'LSItemContentTypes': [t for t in types if t in own and t not in tex]},
        {'CFBundleTypeName': 'Text and Code', 'CFBundleTypeRole': 'Editor', 'LSHandlerRank': 'Default',
         'LSItemContentTypes': [t for t in types if t not in own and t not in tex]},
        {'CFBundleTypeName': 'TeX Document', 'CFBundleTypeRole': 'Editor', 'LSHandlerRank': 'Alternate',
         'LSItemContentTypes': [t for t in types if t in tex] + [t for t in editor_kinds['tex'] if t not in types]},
    ]

def update(path, fn):
    with open(path, 'rb') as f: plist = plistlib.load(f)
    fn(plist)
    with open(path, 'wb') as f: plistlib.dump(plist, f)

def ext(plist): plist['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes'] = ordered
def app(plist):
    plist['UTExportedTypeDeclarations'] = exported
    plist['UTImportedTypeDeclarations'] = snap['imported']
    plist['CFBundleDocumentTypes'] = document_types(ordered, set(exported_ids))

update(os.path.join(here, '..', 'Extension', 'Info.plist'), ext)
update(os.path.join(here, '..', 'App', 'Info.plist'), app)
print(len(ordered), 'content types;', len(exported), 'exported and', len(snap['imported']), 'imported declarations')
