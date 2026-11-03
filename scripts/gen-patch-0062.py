#!/usr/bin/env python3
"""Generate overlay/patches/0062-cores-mesen-hdpack-case-insensitive.patch.

Applies ON TOP of overlay 0061 (which stays; 0062 touches none of 0061's hunks).

WHY. The tester's device log for build (`launch-beacon.log`,
2026-09-06 17:56-17:57, three loads) ends every one of his three packs the same
way:

    hdpack: FALLBACK tolerant-name -> folder "super mario bros. (world)"
    hdpack: file "editorGenImage0.png" NOT FOUND in ".../super mario bros. (world)"
    hdpack: that folder holds these PNGs: ... "editorgenimage0.png" ...
    hdpack: <img> "editorGenImage0.png" missing or not a readable PNG -> whole pack REJECTED

and for Contra/Zelda the same with `Chr_0.png` vs `chr_0.png`.

FIRST QUESTION ANSWERED: that listing is NOT our own lower-casing. 0061's
`hdpack_read_dir()` pushes `dirent::d_name` verbatim and `hdpack_list_folder()` /
`hdpack_list_pngs()` print it verbatim; nothing on that path calls `tolower`
(the only `tolower` calls in 0061 are inside `hdpack_normalize()` and the SHA1
line matcher, neither of which feeds the listing or an `open()`). The names on
The tester's device really ARE lower-case — folder names, PNG names, and the
`HdPacks` directory itself (the configured `.../system/HdPacks` is ENOENT while
`.../system/hdpacks` reads fine). His copy path folded them; the pack authors'
`hires.txt` still refers to `editorGenImage0.png` / `Chr_0.png`, and an iOS /
visionOS data container is case-SENSITIVE, so the first `<img>` line kills the
whole pack.

WHAT 0062 DOES: every filename a pack refers to is resolved against the REAL
directory listing, case-insensitively, one path component at a time, and the
real on-disk name is what gets opened. A path is never lower-cased before
opening — the resolved path is built out of actual `readdir()` entries only. It
covers `hires.txt`, every `<img>`, `<background>`, `<patch>`, `<bgm>`/`<sfx>`
and `palette.dat`, because upstream funnels all of them through
`HdPackLoader::LoadFile()` / `CheckFile()`, plus the three places that STORE an
absolute path for later opening (patch, bgm, sfx).

Not touched, deliberately: the `HdPacks` directory and the pack folder itself.
0061 already resolves both case-insensitively (`hdpack_find_in()` compares with
`hdpack_iequals`, and the tolerant-name fallback case-folds), and the tester's log
proves both fire correctly on his device — the `FALLBACK hdpacks-dir` and
`FALLBACK tolerant-name` / `FALLBACK sha1` lines above. Editing
`InitializeLoader` would mean superseding 0061 wholesale for no behaviour change.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mesen/Core/HdPackLoader.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0062-cores-mesen-hdpack-case-insensitive.patch"

# --- helpers + CheckFile + the head of LoadFile ---------------------------------
A_MAIN = """bool HdPackLoader::CheckFile(string filename)
{
	if(_loadFromZip) {
		return _reader.CheckFile(filename);
	} else {
		ifstream file(FolderUtilities::CombinePath(_hdPackFolder, filename), ios::in | ios::binary);
		if(file.good()) {
			return true;
		}
	}

	return false;
}

bool HdPackLoader::LoadFile(string filename, vector<uint8_t> &fileData)
{
	fileData.clear();

	if(_loadFromZip) {
		if(_reader.ExtractFile(filename, fileData)) {
			return true;
		}
	} else {
		ifstream file(FolderUtilities::CombinePath(_hdPackFolder, filename), ios::in | ios::binary);
		if(file.good()) {
"""

R_MAIN = r'''/* --- 0062: case-insensitive filename resolution ----------------------
 *
 * HD packs are authored on Windows and macOS, where the filesystem is
 * case-INSENSITIVE, so nothing ever forced an author's `hires.txt` to agree
 * with their own filenames. An iOS/visionOS data container is case-SENSITIVE,
 * and any copy path that folds names (the tester's did — folders, PNGs and the
 * `HdPacks` directory all arrived lower-case) then makes the FIRST `<img>` line
 * fail, which rejects the WHOLE pack.
 *
 * Every name a pack refers to is therefore resolved against the real directory
 * listing before it is opened. Note what this does NOT do: it never lower-cases
 * a path and opens that. The resolved path is assembled out of actual
 * `readdir()` entries, so the name that reaches `open()` is a name that exists.
 */
static std::string hdpack_resolve_component(const std::string &parent, const std::string &name)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(parent, names, err)) {
		return name;
	}
	for(const std::string &n : names) {
		if(hdpack_iequals(n, name)) {
			return n;
		}
	}
	return name;
}

/* One line per file that actually needed correcting, and only for the first
 * few: a 300-image pack must not write 300 log lines. Reset per pack folder. */
static void hdpack_case_note(const std::string &folder, const std::string &wanted, const std::string &got)
{
	static std::string lastFolder;
	static int shown = 0;
	if(folder != lastFolder) {
		lastFolder = folder;
		shown = 0;
	}
	if(shown < 6) {
		hdpack_beacon("hdpack: case-resolved \"" + wanted + "\" -> \"" + got + "\"");
	} else if(shown == 6) {
		hdpack_beacon("hdpack: (more names needed the same correction; not logging each one)");
	}
	shown++;
}

/* The on-disk path for a name out of hires.txt. Exact match is the fast path
 * (one stat, no readdir); only a miss costs a directory read. Subdirectories
 * are resolved component by component, and a Windows-authored `a\dir\b.png`
 * separator is accepted. Returns the unresolved path when nothing matches, so
 * the caller's existing "NOT FOUND" beacon still reports the name as written. */
static std::string hdpack_resolve_path(const std::string &folder, const std::string &filename)
{
	std::string direct = FolderUtilities::CombinePath(folder, filename);
	struct stat st;
	if(filename.empty() || stat(direct.c_str(), &st) == 0) {
		return direct;
	}

	std::string rest = filename;
	for(size_t i = 0; i < rest.size(); i++) {
		if(rest[i] == '\\') {
			rest[i] = '/';
		}
	}

	std::string cur = folder;
	size_t pos = 0;
	for(;;) {
		size_t slash = rest.find('/', pos);
		std::string comp = (slash == std::string::npos) ? rest.substr(pos) : rest.substr(pos, slash - pos);
		if(!comp.empty() && comp != ".") {
			cur = FolderUtilities::CombinePath(cur, hdpack_resolve_component(cur, comp));
		}
		if(slash == std::string::npos) {
			break;
		}
		pos = slash + 1;
	}

	if(cur != direct && stat(cur.c_str(), &st) == 0) {
		hdpack_case_note(folder, filename, cur);
	}
	return cur;
}

bool HdPackLoader::CheckFile(string filename)
{
	if(_loadFromZip) {
		return _reader.CheckFile(filename);
	} else {
		/* 0062: open the name that is really on disk, whatever its casing. */
		ifstream file(hdpack_resolve_path(_hdPackFolder, filename), ios::in | ios::binary);
		if(file.good()) {
			return true;
		}
	}

	return false;
}

bool HdPackLoader::LoadFile(string filename, vector<uint8_t> &fileData)
{
	fileData.clear();

	if(_loadFromZip) {
		if(_reader.ExtractFile(filename, fileData)) {
			return true;
		}
	} else {
		/* 0062: ditto — this is the call every <img>, <background>, <patch>,
		 * <bgm>/<sfx>, palette.dat and hires.txt itself goes through. */
		ifstream file(hdpack_resolve_path(_hdPackFolder, filename), ios::in | ios::binary);
		if(file.good()) {
'''

# --- the three places that STORE a path to be opened later ----------------------
A_PATCH = """		_data->PatchesByHash[tokens[1]] = FolderUtilities::CombinePath(_hdPackFolder, tokens[0]);
"""
R_PATCH = """		/* 0062: store the real on-disk name, not the one hires.txt wrote. */
		_data->PatchesByHash[tokens[1]] = hdpack_resolve_path(_hdPackFolder, tokens[0]);
"""

A_BGM = """			_data->BgmFilesById[trackId] = FolderUtilities::CombinePath(_hdPackFolder, tokens[2]);
"""
R_BGM = """			/* 0062: as above — CheckFile() already found it case-insensitively. */
			_data->BgmFilesById[trackId] = hdpack_resolve_path(_hdPackFolder, tokens[2]);
"""

A_SFX = """			_data->SfxFilesById[trackId] = FolderUtilities::CombinePath(_hdPackFolder, tokens[2]);
"""
R_SFX = """			/* 0062: as above. */
			_data->SfxFilesById[trackId] = hdpack_resolve_path(_hdPackFolder, tokens[2]);
"""

text = SRC.read_text()
if "hdpack_beacon" not in text:
    sys.exit("overlay 0061 is NOT applied to vendor — 0062 builds on it; apply the series first")
if "hdpack_resolve_path" in text:
    sys.exit("0062 already applied to vendor — reverse it out before regenerating")

hunks = []
for anchor, repl in ((A_MAIN, R_MAIN), (A_PATCH, R_PATCH), (A_BGM, R_BGM), (A_SFX, R_SFX)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"anchor matched {n} times in {SRC} (want 1):\n{anchor[:90]}")
    start = text.index(anchor)
    line_no = text[:start].count("\n") + 1
    old_lines = anchor.rstrip("\n").split("\n")
    new_lines = repl.rstrip("\n").split("\n")
    LEAD = TRAIL = 3
    lead = text[:start].split("\n")[:-1][-LEAD:] if start else []
    rest = text[start + len(anchor):].split("\n")[:TRAIL]
    while rest and rest[-1] == "":
        rest.pop()

    body = [" " + l if l else " " for l in lead]
    body += ["-" + l if l else "-" for l in old_lines]
    body += ["+" + l if l else "+" for l in new_lines]
    body += [" " + l if l else " " for l in rest]
    old_count = len(lead) + len(old_lines) + len(rest)
    new_count = len(lead) + len(new_lines) + len(rest)
    hunk_start = line_no - len(lead)
    hunks.append((hunk_start, hunk_start + old_count,
                  f"@@ -{hunk_start},{old_count} +{hunk_start},{new_count} @@\n"
                  + "\n".join(body) + "\n"))

hunks.sort()
for (s0, e0, _), (s1, _e1, _b) in zip(hunks, hunks[1:]):
    if e0 > s1:
        sys.exit(f"hunks overlap: one ends at line {e0}, the next starts at {s1}")

OUT.write_text(
    f"diff --git a/{REL} b/{REL}\n"
    f"--- a/{REL}\n"
    f"+++ b/{REL}\n"
    + "".join(h[2] for h in hunks)
)
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/mesen"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
