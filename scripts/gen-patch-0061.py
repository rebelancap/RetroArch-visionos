#!/usr/bin/env python3
"""Generate overlay/patches/0061-cores-mesen-hdpack-loader-robust.patch.

SUPERSEDES overlay 0058 (`0058-cores-mesen-hdpack-beacon.patch`), which is
deleted in the same commit — 0061 must add lines *inside* 0058's hunks (the
`HdPacks holds:` line, the archive scan, the missing-file line), and the overlay
rules forbid one patch editing inside another's hunks. Same relationship 0058
had to 0023. See (and for 0058, for 0023).

The tester, on the headset: "I couldn't get hdpacks to work on NES
games. I tried all 3 games I have hdpacks for." — with the beacon log, which is
what 0058 was for. What that log says (`launch-beacon.log`, 2026-09-06):

  16:52:58 rom="Super Mario Bros (E)"
           want ".../HdPacks/Super Mario Bros (E)/hires.txt" -> FOUND
           file "editorGenImage0.png" NOT FOUND -> whole pack REJECTED
  (The tester re-copies the packs)
  17:15:54 rom="Super Mario Bros. (World)"  -> MISSING
  17:16:12 rom="Contra (U)"                 -> MISSING
  17:16:42 rom="Zelda - Legend of Zelda, The (USA)" -> MISSING
           HdPacks holds: <UNREADABLE ...>       (all three)
           archives scanned=0                    (all three)

Three separate faults, and 0058 could only name the first:

  1. the SMB pack really is missing a PNG (16:52 — answered, line did
     its job);
  2. after the re-copy, `opendir()` on the very path a file was read from 23
     minutes earlier fails — and 0058 prints no errno, so "does not exist" and
     "exists but could not be read" are indistinguishable;
  3. the ROM filenames changed between the two sessions ("Super Mario Bros (E)"
     -> "Super Mario Bros. (World)"), so even a correctly-copied pack folder
     named for the *old* dump would now miss. Third-party packs are named for
     whichever dump their author had.

`archives scanned=0` is not a fourth fault, it is a dead code path:
`FolderUtilities::GetFilesInFolder()` is `{ return vector<string>(); }` in the
libretro build (`Utilities/FolderUtilities.cpp:105`), so upstream's `.hdn`/`.zip`
route — the one that matches by SHA1 rather than by name — has never been able
to find a single archive on this platform. The advice "use a .hdn to dodge the
naming rule" was wrong for this build, and 0061 makes it true by scanning the
directory itself.

WHAT 0061 CHANGES (0058's semantics are kept in full):

  a. the `HdPacks holds:` listing is printed on EVERY load, the FOUND path
     included — a half-finished copy (folder there, PNGs still arriving) now
     shows itself instead of looking like a working pack that renders nothing;
  b. `opendir()` failure prints `errno` text, so ENOENT (the folder is gone)
     reads differently from EACCES/EIO (it is there and unreadable);
  c. fallback 1, SHA1: any pack folder whose `hires.txt` carries a
     `<supportedRom>` line with THIS dump's hash wins regardless of folder name.
     Upstream had this for archives only, and only through the dead stub;
  d. fallback 2, tolerant name: folder names are compared to the ROM name
     case-folded, with `(...)`/`[...]` tags dropped and punctuation removed, so
     `Super Mario Bros. (World)` finds `super mario bros (e)`;
  e. fallback 3, unique containment: one normalized name containing the other
     (>= 8 chars, exactly one candidate) — this is what reaches
     `Legend of Zelda, The (U) (PRG1)` from `Zelda - Legend of Zelda, The (USA)`;
  f. every fallback beacons which rule fired and which folder it chose, so the
     log never leaves it ambiguous which pack was loaded;
  g. a missing referenced file lists the PNGs that ARE present next to it.

 deliberately refused tolerance ("a fuzzy matcher silently loads the wrong
pack"). reverses that on evidence: the strict rule cost two device rounds
and still has not loaded a pack, the hash route that was supposed to be the
principled escape hatch does not run at all on this build, and every fallback
here is (1) tried only after the exact name misses, (2) required to be unique,
and (3) named in the log. The risk it was protecting against — loading a pack
authored for a different dump — is exactly what the tester's three packs need, since
his ROMs and his packs come from different sites.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mesen/Core/HdPackLoader.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0061-cores-mesen-hdpack-loader-robust.patch"
OLD = ROOT / "overlay/patches/0058-cores-mesen-hdpack-beacon.patch"

# --- the includes the helpers need ---------------------------------------------
A_INC = """#include "Console.h"
#include "HdPackLoader.h"
#include "HdPackConditions.h"
#include "HdNesPack.h"
"""
R_INC = """#include "Console.h"
#include "HdPackLoader.h"
#include "HdPackConditions.h"
#include "HdNesPack.h"
/* 0061 (was 0058): HD-pack load beacon + tolerant lookup. */
#include <string>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <ctime>
#include <cerrno>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#if !defined(_WIN32)
#include <dirent.h>
#endif
"""

# --- helpers + the whole of InitializeLoader ------------------------------------
A_INIT = """HdPackLoader::HdPackLoader()
{
}

bool HdPackLoader::InitializeLoader(VirtualFile &romFile, HdPackData *data)
{
	_data = data;

	string romName = FolderUtilities::GetFilename(romFile.GetFileName(), false);
	string hdPackFolder = FolderUtilities::GetHdPackFolder();
	string zipName = romName + ".hdn";
	string definitionPath = FolderUtilities::CombinePath(romName, "hires.txt");

	string legacyPath = FolderUtilities::CombinePath(hdPackFolder, definitionPath);
	if(ifstream(legacyPath)) {
		_loadFromZip = false;
		_hdPackFolder = FolderUtilities::GetFolderName(legacyPath);
		return true;
	} else {
		vector<string> hdnPackages = FolderUtilities::GetFilesInFolder(romFile.GetFolderPath(), { ".hdn" }, false);
		vector<string> more = FolderUtilities::GetFilesInFolder(hdPackFolder, { ".hdn", ".zip" }, false);
		hdnPackages.insert(hdnPackages.end(), more.begin(), more.end());

		string sha1Hash = romFile.GetSha1Hash();
		for(string path : hdnPackages) {
			_reader.LoadArchive(path);

			vector<uint8_t> hdDefinition;
			if(_reader.ExtractFile("hires.txt", hdDefinition)) {
				if(FolderUtilities::GetFilename(path, false) == romName) {
					_loadFromZip = true;
					_hdPackFolder = path;
					return true;
				} else {
					for(string line : StringUtilities::Split(string(hdDefinition.data(), hdDefinition.data() + hdDefinition.size()), '\\n')) {
						std::transform(line.begin(), line.end(), line.begin(), ::tolower);
						if(line.find("<supportedrom>") != string::npos && line.find(sha1Hash) != string::npos) {
							_loadFromZip = true;
							_hdPackFolder = path;
							return true;
						}
					}
				}
			}
		}
	}
	return false;
}
"""

R_INIT = """/* ---- 0061 (was 0058): HD-pack load beacon + tolerant lookup ---------------
 * Every HD-pack failure in this file is silent — no MessageManager calls, and
 * the checkConstraint() macro at the top of the file compiles its message
 * argument away. Say what was tried, where, and what is actually on disk, into
 * the port's beacon sink. The frontend exports RA_BeaconMark, but it is built
 * with ThinLTO, which internalizes it — so the direct write to
 * Documents/launch-beacon.log is the path that really runs on device. Shape
 * copied from overlay 0049's gliden64_blit_beacon. ROM load only, never a frame
 * path. */
static void hdpack_beacon(const std::string &msg)
{
	static void (*ra_beacon)(const char *) = nullptr;
	static bool looked_up = false;
	if(!looked_up) {
		looked_up = true;
		ra_beacon = (void (*)(const char *))dlsym(RTLD_DEFAULT, "RA_BeaconMark");
	}
	if(ra_beacon != nullptr) {
		ra_beacon(msg.c_str());
		return;
	}
	const char *home = getenv("HOME");
	if(home == nullptr) {
		return;
	}
	char path[1024];
	snprintf(path, sizeof(path), "%s/Documents/launch-beacon.log", home);
	int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if(fd < 0) {
		return;
	}
	time_t tt = time(nullptr);
	struct tm tmv;
	localtime_r(&tt, &tmv);
	char line[2048];
	int n = snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d  %s\\n",
		tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
		tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.c_str());
	if(n > 0) {
		(void)write(fd, line, (size_t)n);
	}
	close(fd);
}

/* 0061: read a directory. FolderUtilities::GetFolders/GetFilesInFolder are
 * `{ return vector<string>(); }` stubs in the libretro build, which is why
 * upstream's archive (and therefore SHA1) route has never found anything here.
 * Returns false and sets `err` to errno on failure — "the folder is gone"
 * (ENOENT) and "the folder is there and unreadable" (EACCES/EIO) are different
 * problems with different fixes, and 0058 printed neither. */
static bool hdpack_read_dir(const std::string &folder, std::vector<std::string> &out, int &err)
{
	err = 0;
#if defined(_WIN32)
	err = ENOSYS;
	return false;
#else
	DIR *d = opendir(folder.c_str());
	if(d == nullptr) {
		err = errno;
		return false;
	}
	struct dirent *e;
	while((e = readdir(d)) != nullptr) {
		if(e->d_name[0] == '.') {
			continue;
		}
		out.push_back(std::string(e->d_name));
	}
	closedir(d);
	std::sort(out.begin(), out.end());
	return true;
#endif
}

/* The names actually present in HdPacks/, so the log carries the tester's folder
 * names and the name Mesen wanted in the same place. Capped — a large HdPacks
 * folder is not worth an unbounded log line. */
static std::string hdpack_list_folder(const std::string &folder)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(folder, names, err)) {
		return " <UNREADABLE: " + std::string(strerror(err))
			+ " — wrong system directory, or HdPacks does not exist>";
	}
	if(names.empty()) {
		return " <EMPTY>";
	}
	std::string out;
	int shown = 0;
	for(const std::string &n : names) {
		if(shown++ >= 24) {
			out += " ...";
			break;
		}
		out += " \\"" + n + "\\"";
	}
	return out;
}

/* 0061: the PNGs that ARE next to hires.txt. Printed when a referenced one is
 * missing — a mis-cased or half-copied image names itself against this list. */
static std::string hdpack_list_pngs(const std::string &folder)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(folder, names, err)) {
		return " <UNREADABLE: " + std::string(strerror(err)) + ">";
	}
	std::string out;
	int shown = 0;
	for(const std::string &n : names) {
		if(n.size() < 4 || strcasecmp(n.c_str() + n.size() - 4, ".png") != 0) {
			continue;
		}
		if(shown++ >= 24) {
			out += " ...";
			break;
		}
		out += " \\"" + n + "\\"";
	}
	return shown == 0 ? std::string(" <no .png files in this folder>") : out;
}

/* 0061: fold a ROM/folder name to what a human means by it — case-folded,
 * `(...)`/`[...]` tags dropped, punctuation and spaces removed. "Super Mario
 * Bros. (World)" and "super mario bros (E)" both become "supermariobros". */
static std::string hdpack_normalize(const std::string &name)
{
	std::string out;
	int depth = 0;
	for(char c : name) {
		if(c == '(' || c == '[') {
			depth++;
			continue;
		}
		if(c == ')' || c == ']') {
			if(depth > 0) {
				depth--;
			}
			continue;
		}
		if(depth > 0) {
			continue;
		}
		if(isalnum((unsigned char)c)) {
			out += (char)tolower((unsigned char)c);
		}
	}
	return out;
}

/* 0061: does this hires.txt claim this dump by hash? Upstream looks for
 * <supportedRom> in archives only. */
static bool hdpack_file_claims_sha1(const std::string &path, const std::string &sha1)
{
	if(sha1.empty()) {
		return false;
	}
	std::string needle = sha1;
	std::transform(needle.begin(), needle.end(), needle.begin(), ::tolower);
	ifstream f(path, ios::in | ios::binary);
	if(!f.good()) {
		return false;
	}
	std::string line;
	int lines = 0;
	while(std::getline(f, line) && lines++ < 4096) {
		std::transform(line.begin(), line.end(), line.begin(), ::tolower);
		if(line.find("<supportedrom>") != std::string::npos && line.find(needle) != std::string::npos) {
			return true;
		}
	}
	return false;
}

/* 0061: the archive scan upstream cannot do here (stubbed GetFilesInFolder). */
static void hdpack_find_archives(const std::string &folder, std::vector<std::string> &out)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(folder, names, err)) {
		return;
	}
	for(const std::string &n : names) {
		size_t dot = n.find_last_of('.');
		if(dot == std::string::npos) {
			continue;
		}
		std::string ext = n.substr(dot);
		if(strcasecmp(ext.c_str(), ".hdn") == 0 || strcasecmp(ext.c_str(), ".zip") == 0) {
			out.push_back(FolderUtilities::CombinePath(folder, n));
		}
	}
}


HdPackLoader::HdPackLoader()
{
}

bool HdPackLoader::InitializeLoader(VirtualFile &romFile, HdPackData *data)
{
	_data = data;

	string romName = FolderUtilities::GetFilename(romFile.GetFileName(), false);
	string hdPackFolder = FolderUtilities::GetHdPackFolder();
	string zipName = romName + ".hdn";
	string definitionPath = FolderUtilities::CombinePath(romName, "hires.txt");

	string legacyPath = FolderUtilities::CombinePath(hdPackFolder, definitionPath);
	if(ifstream(legacyPath)) {
		_loadFromZip = false;
		_hdPackFolder = FolderUtilities::GetFolderName(legacyPath);
		return true;
	} else {
		vector<string> hdnPackages = FolderUtilities::GetFilesInFolder(romFile.GetFolderPath(), { ".hdn" }, false);
		vector<string> more = FolderUtilities::GetFilesInFolder(hdPackFolder, { ".hdn", ".zip" }, false);
		hdnPackages.insert(hdnPackages.end(), more.begin(), more.end());

		string sha1Hash = romFile.GetSha1Hash();
		for(string path : hdnPackages) {
			_reader.LoadArchive(path);

			vector<uint8_t> hdDefinition;
			if(_reader.ExtractFile("hires.txt", hdDefinition)) {
				if(FolderUtilities::GetFilename(path, false) == romName) {
					_loadFromZip = true;
					_hdPackFolder = path;
					return true;
				} else {
					for(string line : StringUtilities::Split(string(hdDefinition.data(), hdDefinition.data() + hdDefinition.size()), '\\n')) {
						std::transform(line.begin(), line.end(), line.begin(), ::tolower);
						if(line.find("<supportedrom>") != string::npos && line.find(sha1Hash) != string::npos) {
							_loadFromZip = true;
							_hdPackFolder = path;
							return true;
						}
					}
				}
			}
		}
	}
	return false;
}
"""

R_INIT = """/* ---- 0061 (was 0058): HD-pack load beacon + tolerant lookup ---------------
 * Every HD-pack failure in this file is silent — no MessageManager calls, and
 * the checkConstraint() macro at the top of the file compiles its message
 * argument away. Say what was tried, where, and what is actually on disk, into
 * the port's beacon sink. The frontend exports RA_BeaconMark, but it is built
 * with ThinLTO, which internalizes it — so the direct write to
 * Documents/launch-beacon.log is the path that really runs on device. Shape
 * copied from overlay 0049's gliden64_blit_beacon. ROM load only, never a frame
 * path. */
static void hdpack_beacon(const std::string &msg)
{
	static void (*ra_beacon)(const char *) = nullptr;
	static bool looked_up = false;
	if(!looked_up) {
		looked_up = true;
		ra_beacon = (void (*)(const char *))dlsym(RTLD_DEFAULT, "RA_BeaconMark");
	}
	if(ra_beacon != nullptr) {
		ra_beacon(msg.c_str());
		return;
	}
	const char *home = getenv("HOME");
	if(home == nullptr) {
		return;
	}
	char path[1024];
	snprintf(path, sizeof(path), "%s/Documents/launch-beacon.log", home);
	int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if(fd < 0) {
		return;
	}
	time_t tt = time(nullptr);
	struct tm tmv;
	localtime_r(&tt, &tmv);
	char line[2048];
	int n = snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d  %s\\n",
		tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
		tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.c_str());
	if(n > 0) {
		(void)write(fd, line, (size_t)n);
	}
	close(fd);
}

/* 0061: read a directory. FolderUtilities::GetFolders/GetFilesInFolder are
 * `{ return vector<string>(); }` stubs in the libretro build, which is why
 * upstream's archive (and therefore SHA1) route has never found anything here.
 * Returns false and sets `err` to errno on failure — "the folder is gone"
 * (ENOENT) and "the folder is there and unreadable" (EACCES/EIO) are different
 * problems with different fixes, and 0058 printed neither. */
static bool hdpack_read_dir(const std::string &folder, std::vector<std::string> &out, int &err)
{
	err = 0;
#if defined(_WIN32)
	err = ENOSYS;
	return false;
#else
	DIR *d = opendir(folder.c_str());
	if(d == nullptr) {
		err = errno;
		return false;
	}
	struct dirent *e;
	while((e = readdir(d)) != nullptr) {
		if(e->d_name[0] == '.') {
			continue;
		}
		out.push_back(std::string(e->d_name));
	}
	closedir(d);
	std::sort(out.begin(), out.end());
	return true;
#endif
}

/* The names actually present in HdPacks/, so the log carries the tester's folder
 * names and the name Mesen wanted in the same place. Capped — a large HdPacks
 * folder is not worth an unbounded log line. */
static std::string hdpack_list_folder(const std::string &folder)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(folder, names, err)) {
		return " <UNREADABLE: " + std::string(strerror(err))
			+ " — wrong system directory, or HdPacks does not exist>";
	}
	if(names.empty()) {
		return " <EMPTY>";
	}
	std::string out;
	int shown = 0;
	for(const std::string &n : names) {
		if(shown++ >= 24) {
			out += " ...";
			break;
		}
		out += " \\"" + n + "\\"";
	}
	return out;
}

/* 0061: the PNGs that ARE next to hires.txt. Printed when a referenced one is
 * missing — a mis-cased or half-copied image names itself against this list. */
static std::string hdpack_list_pngs(const std::string &folder)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(folder, names, err)) {
		return " <UNREADABLE: " + std::string(strerror(err)) + ">";
	}
	std::string out;
	int shown = 0;
	for(const std::string &n : names) {
		if(n.size() < 4 || strcasecmp(n.c_str() + n.size() - 4, ".png") != 0) {
			continue;
		}
		if(shown++ >= 24) {
			out += " ...";
			break;
		}
		out += " \\"" + n + "\\"";
	}
	return shown == 0 ? std::string(" <no .png files in this folder>") : out;
}

/* 0061: fold a ROM/folder name to what a human means by it — case-folded,
 * `(...)`/`[...]` tags dropped, punctuation and spaces removed. "Super Mario
 * Bros. (World)" and "super mario bros (E)" both become "supermariobros". */
static std::string hdpack_normalize(const std::string &name)
{
	std::string out;
	int depth = 0;
	for(char c : name) {
		if(c == '(' || c == '[') {
			depth++;
			continue;
		}
		if(c == ')' || c == ']') {
			if(depth > 0) {
				depth--;
			}
			continue;
		}
		if(depth > 0) {
			continue;
		}
		if(isalnum((unsigned char)c)) {
			out += (char)tolower((unsigned char)c);
		}
	}
	return out;
}

/* 0061: does this hires.txt claim this dump by hash? Upstream looks for
 * <supportedRom> in archives only. */
static bool hdpack_file_claims_sha1(const std::string &path, const std::string &sha1)
{
	if(sha1.empty()) {
		return false;
	}
	std::string needle = sha1;
	std::transform(needle.begin(), needle.end(), needle.begin(), ::tolower);
	ifstream f(path, ios::in | ios::binary);
	if(!f.good()) {
		return false;
	}
	std::string line;
	int lines = 0;
	while(std::getline(f, line) && lines++ < 4096) {
		std::transform(line.begin(), line.end(), line.begin(), ::tolower);
		if(line.find("<supportedrom>") != std::string::npos && line.find(needle) != std::string::npos) {
			return true;
		}
	}
	return false;
}

/* 0061: the archive scan upstream cannot do here (stubbed GetFilesInFolder). */
static void hdpack_find_archives(const std::string &folder, std::vector<std::string> &out)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(folder, names, err)) {
		return;
	}
	for(const std::string &n : names) {
		size_t dot = n.find_last_of('.');
		if(dot == std::string::npos) {
			continue;
		}
		std::string ext = n.substr(dot);
		if(strcasecmp(ext.c_str(), ".hdn") == 0 || strcasecmp(ext.c_str(), ".zip") == 0) {
			out.push_back(FolderUtilities::CombinePath(folder, n));
		}
	}
}


/* 0061: one path, one line: does it exist, is it a directory, and if not, why
 * not (errno). Walked from $HOME down, this says at WHICH level the tree stops
 * — which is the difference between "the tester put the pack somewhere else" and
 * "the core is looking inside a container that no longer exists". */
static std::string hdpack_stat_line(const std::string &path)
{
	struct stat st;
	if(stat(path.c_str(), &st) != 0) {
		return "ABSENT (" + std::string(strerror(errno)) + ")";
	}
	std::string kind = S_ISDIR(st.st_mode) ? "dir" : (S_ISREG(st.st_mode) ? "FILE-not-dir" : "other");
	char buf[64];
	snprintf(buf, sizeof(buf), " mode=%04o size=%lld", (unsigned)(st.st_mode & 07777), (long long)st.st_size);
	return kind + std::string(buf);
}

/* 0061: the exact bytes of a name, so a trailing space, a non-breaking space or
 * an NFD-vs-NFC accent shows itself instead of looking identical in the log. */
static std::string hdpack_hex(const std::string &s)
{
	std::string out;
	char b[8];
	for(size_t i = 0; i < s.size() && i < 96; i++) {
		snprintf(b, sizeof(b), "%02x ", (unsigned char)s[i]);
		out += b;
	}
	return out;
}

static bool hdpack_iequals(const std::string &a, const std::string &b)
{
	return a.size() == b.size() && strcasecmp(a.c_str(), b.c_str()) == 0;
}

/* 0061: a readable directory named "hdpacks" in any casing, inside `parent`. */
static std::string hdpack_find_in(const std::string &parent)
{
	std::vector<std::string> names;
	int err = 0;
	if(!hdpack_read_dir(parent, names, err)) {
		return std::string();
	}
	for(const std::string &n : names) {
		if(hdpack_iequals(n, "HdPacks")) {
			std::string cand = FolderUtilities::CombinePath(parent, n);
			std::vector<std::string> probe;
			int e2 = 0;
			if(hdpack_read_dir(cand, probe, e2)) {
				return cand;
			}
		}
	}
	return std::string();
}

/* 0061: when the configured <system>/HdPacks cannot be read, say why in full and
 * then look for a real one.
 *
 * WHY THIS EXISTS (and (d) which predicted it): the data container
 * is RELOCATED to a new UUID on every install, `retroarch.cfg` persists
 * `system_directory` as an ABSOLUTE path, and upstream existence-checks
 * screenshot/savefile/savestate directories but NOT system_directory
 * (`configuration.c:1691`, `:6516-6522`, `:6717`). So one install after the tester
 * last saved his config, the core is handed a path inside a container that no
 * longer exists — while $HOME is always the live container, and the user's files
 * are exactly where he put them. That is what the tester's 2026-09-06 log shows: the
 * same absolute path served a hires.txt at 16:52 and was ENOENT at 17:15, across
 * a relaunch, with the folders demonstrably still on the device.
 *
 * The proper fix is in the frontend (reset a dead system_directory the way
 * screenshot_directory is reset) and is recommended; this makes HD
 * packs work anyway, and names the condition in the log either way. */
static std::string hdpack_resolve_folder(const std::string &configured)
{
	std::vector<std::string> probe;
	int err = 0;
	if(hdpack_read_dir(configured, probe, err)) {
		return configured;
	}

	const char *home = getenv("HOME");
	std::string h = home ? std::string(home) : std::string();
	hdpack_beacon("hdpack: HdPacks UNREADABLE (" + std::string(strerror(err)) + ") — diagnosing");
	hdpack_beacon("hdpack:   home=\\"" + h + "\\"");
	if(!h.empty() && configured.find(h) != 0
		&& configured.find("/Containers/Data/Application/") != std::string::npos) {
		hdpack_beacon("hdpack:   *** the configured system directory is NOT under $HOME — "
			"retroarch.cfg's system_directory points into a DEAD container. "
			"Fix: RetroArch menu -> Settings -> Directory -> System/BIOS, re-pick it; "
			"or delete Documents/RetroArch/config/retroarch.cfg's system_directory line.");
	}
	std::string walk = configured;
	std::vector<std::string> parts;
	while(walk.size() > 1) {
		parts.push_back(walk);
		std::string up = FolderUtilities::GetFolderName(walk);
		if(up == walk || up.empty()) {
			break;
		}
		walk = up;
	}
	for(size_t i = parts.size(); i-- > 0 && parts.size() - i <= 6; ) {
		hdpack_beacon("hdpack:   " + parts[i] + " -> " + hdpack_stat_line(parts[i]));
	}

	std::vector<std::string> candidates;
	candidates.push_back(FolderUtilities::GetFolderName(configured));   /* <system> */
	if(!h.empty()) {
		candidates.push_back(h + "/Documents/RetroArch/system");
		candidates.push_back(h + "/Documents/RetroArch");
		candidates.push_back(h + "/Documents");
	}
	for(const std::string &parent : candidates) {
		std::string found = hdpack_find_in(parent);
		if(!found.empty()) {
			hdpack_beacon("hdpack: FALLBACK hdpacks-dir -> \\"" + found
				+ "\\" (the configured one could not be read)");
			return found;
		}
		hdpack_beacon("hdpack:   no readable HdPacks in \\"" + parent + "\\" ("
			+ hdpack_stat_line(parent) + ")");
	}
	return configured;
}

HdPackLoader::HdPackLoader()
{
}

bool HdPackLoader::InitializeLoader(VirtualFile &romFile, HdPackData *data)
{
	_data = data;

	string romName = FolderUtilities::GetFilename(romFile.GetFileName(), false);
	string configuredFolder = FolderUtilities::GetHdPackFolder();
	string zipName = romName + ".hdn";

	/* 0061 (was 0058, was 0023 — which wrote this into the system directory, the
	 * one directory can make unreachable, and was never collected). */
	hdpack_beacon("hdpack: rom=\\"" + romName + "\\" hdpacks=\\"" + configuredFolder + "\\"");

	/* 0061: if the configured folder cannot be read, diagnose it in full and look
	 * for the real one under the LIVE container ($HOME) — see the comment on
	 * hdpack_resolve_folder(). Cheap: one opendir on the happy path. */
	string hdPackFolder = hdpack_resolve_folder(configuredFolder);
	string definitionPath = FolderUtilities::CombinePath(romName, "hires.txt");
	string legacyPath = FolderUtilities::CombinePath(hdPackFolder, definitionPath);

	/* 0061: listed on EVERY load, the FOUND path included — a half-finished copy
	 * (folder present, PNGs still arriving) is otherwise invisible until it
	 * fails on a name deep inside hires.txt. */
	hdpack_beacon("hdpack: HdPacks holds:" + hdpack_list_folder(hdPackFolder));

	if(ifstream(legacyPath)) {
		hdpack_beacon("hdpack: want \\"" + legacyPath + "\\" -> FOUND (exact folder name)");
		_loadFromZip = false;
		_hdPackFolder = FolderUtilities::GetFolderName(legacyPath);
		return true;
	} else {
		/* Upstream requires the folder name to equal the ROM's filename without
		 * its extension, character for character — case and region tag included.
		 * Print both sides of that comparison, then try the fallbacks below. */
		hdpack_beacon("hdpack: want \\"" + legacyPath + "\\" -> MISSING");
		/* 0061: the exact bytes wanted. A trailing space, a non-breaking space or
		 * an NFD-composed accent is invisible in the text above and obvious here. */
		hdpack_beacon("hdpack: wanted folder name bytes: " + hdpack_hex(romName));

		string sha1Hash = romFile.GetSha1Hash();
		std::vector<std::string> entries;
		int listErr = 0;
		bool listed = hdpack_read_dir(hdPackFolder, entries, listErr);

		/* --- 0061 fallback 1: SHA1 ---------------------------------------
		 * A pack folder whose hires.txt claims THIS dump by hash wins whatever
		 * it is called. Authoritative, so it is tried before any name rule. */
		if(listed) {
			for(const std::string &name : entries) {
				std::string cand = FolderUtilities::CombinePath(
					FolderUtilities::CombinePath(hdPackFolder, name), "hires.txt");
				if(!ifstream(cand)) {
					continue;
				}
				if(hdpack_file_claims_sha1(cand, sha1Hash)) {
					hdpack_beacon("hdpack: FALLBACK sha1 -> folder \\"" + name
						+ "\\" (<supportedRom> " + sha1Hash + ")");
					_loadFromZip = false;
					_hdPackFolder = FolderUtilities::GetFolderName(cand);
					return true;
				}
			}
		}

		/* --- 0061 fallback 2: tolerant name ------------------------------
		 * Case, punctuation and the region/version tag are dropped from both
		 * sides. Must be unique: two folders that fold to the same name is a
		 * genuine ambiguity and is reported rather than guessed. */
		std::string wanted = hdpack_normalize(romName);
		std::vector<std::string> matches;
		std::vector<std::string> packs;
		if(listed) {
			for(const std::string &name : entries) {
				std::string cand = FolderUtilities::CombinePath(
					FolderUtilities::CombinePath(hdPackFolder, name), "hires.txt");
				if(!ifstream(cand)) {
					continue;
				}
				packs.push_back(name);
				if(hdpack_normalize(name) == wanted) {
					matches.push_back(name);
				}
			}
		}
		/* --- 0061 fallback 3: unique containment -------------------------
		 * "Zelda - Legend of Zelda, The (USA)" vs a pack folder called
		 * "Legend of Zelda, The (U) (PRG1)". Only when nothing matched
		 * outright, only when exactly one candidate contains or is contained
		 * by the ROM name, and only for names long enough to mean something. */
		bool loose = false;
		if(matches.empty() && wanted.size() >= 8) {
			for(const std::string &name : packs) {
				std::string n = hdpack_normalize(name);
				if(n.size() < 8) {
					continue;
				}
				if(n.find(wanted) != std::string::npos || wanted.find(n) != std::string::npos) {
					matches.push_back(name);
				}
			}
			loose = true;
		}
		if(matches.size() == 1) {
			std::string chosen = FolderUtilities::CombinePath(hdPackFolder, matches[0]);
			hdpack_beacon(std::string("hdpack: FALLBACK ") + (loose ? "loose-name" : "tolerant-name")
				+ " -> folder \\"" + matches[0] + "\\" (rom folds to \\"" + wanted + "\\")");
			_loadFromZip = false;
			_hdPackFolder = chosen;
			return true;
		} else if(matches.size() > 1) {
			std::string all;
			for(const std::string &m : matches) {
				all += " \\"" + m + "\\"";
			}
			hdpack_beacon("hdpack: AMBIGUOUS — " + std::to_string(matches.size())
				+ " folders match rom \\"" + romName + "\\" loosely:" + all
				+ " — rename the right one to \\"" + romName + "\\" and none will be guessed");
		} else if(listed) {
			hdpack_beacon("hdpack: no folder matches rom \\"" + romName
				+ "\\" (folds to \\"" + wanted + "\\"); "
				+ std::to_string(packs.size()) + " folder(s) here carry a hires.txt");
			int dumped = 0;
			for(const std::string &name : packs) {
				if(dumped++ >= 4) {
					break;
				}
				hdpack_beacon("hdpack:   have \\"" + name + "\\" bytes: " + hdpack_hex(name));
			}
		}

		/* 0061: our own archive scan. FolderUtilities::GetFilesInFolder is a
		 * stub in the libretro build, so upstream's .hdn/.zip route — the one
		 * that matches by SHA1 — has never found a single archive here. */
		vector<string> hdnPackages;
		hdpack_find_archives(romFile.GetFolderPath(), hdnPackages);
		hdpack_find_archives(hdPackFolder, hdnPackages);

		hdpack_beacon("hdpack: archives scanned=" + std::to_string(hdnPackages.size())
			+ " sha1=" + sha1Hash);
		for(string path : hdnPackages) {
			_reader.LoadArchive(path);

			vector<uint8_t> hdDefinition;
			if(_reader.ExtractFile("hires.txt", hdDefinition)) {
				if(FolderUtilities::GetFilename(path, false) == romName) {
					hdpack_beacon("hdpack: archive \\"" + path + "\\" matched by name");
					_loadFromZip = true;
					_hdPackFolder = path;
					return true;
				} else {
					for(string line : StringUtilities::Split(string(hdDefinition.data(), hdDefinition.data() + hdDefinition.size()), '\\n')) {
						std::transform(line.begin(), line.end(), line.begin(), ::tolower);
						if(line.find("<supportedrom>") != string::npos && line.find(sha1Hash) != string::npos) {
							hdpack_beacon("hdpack: archive \\"" + path + "\\" matched by <supportedRom> sha1");
							_loadFromZip = true;
							_hdPackFolder = path;
							return true;
						}
					}
				}
			}
		}
	}
	/* 0061: the lines above say which of the failures this was. */
	hdpack_beacon("hdpack: NO PACK for this ROM");
	return false;
}
"""

# --- a file the pack asked for is not there (hires.txt, or ANY of its PNGs) -----
A_FILE = """			return true;
		}
	}

	return false;
}

bool HdPackLoader::LoadPack()
{
	string currentLine;
	try {
		vector<uint8_t> hdDefinition;
		if(!LoadFile("hires.txt", hdDefinition)) {
			return false;
		}
"""
R_FILE = """			return true;
		}
	}

	/* 0061 (was 0058): names the missing file, and lists the PNGs that ARE
	 * there. This is the ONE line that catches the "correct folder, valid
	 * <ver>, one PNG missing" case, which kills the whole pack and is otherwise
	 * indistinguishable from having no pack at all. */
	if(filename != "palette.dat") {
		/* palette.dat is optional and most packs do not carry one; every other
		 * missing file is fatal to the whole pack. */
		hdpack_beacon("hdpack: file \\"" + filename + "\\" NOT FOUND in \\"" + _hdPackFolder + "\\"");
		if(!_loadFromZip) {
			hdpack_beacon("hdpack: that folder holds these PNGs:" + hdpack_list_pngs(_hdPackFolder));
		}
	}
	return false;
}

bool HdPackLoader::LoadPack()
{
	string currentLine;
	try {
		vector<uint8_t> hdDefinition;
		if(!LoadFile("hires.txt", hdDefinition)) {
			/* 0061: located by InitializeLoader, unreadable here. */
			hdpack_beacon("hdpack: hires.txt located but could NOT be read -> pack REJECTED");
			return false;
		}
"""

# --- the version gate: found, valid, and simply too new -------------------------
A_VER = """				_data->Version = stoi(lineContent.substr(5));
				if(_data->Version > HdNesPack::CurrentVersion)
					return false;
"""
R_VER = """				_data->Version = stoi(lineContent.substr(5));
				if(_data->Version > HdNesPack::CurrentVersion) {
					/* 0061: the pack WAS found and is simply authored for a newer
					 * Mesen (packs for Mesen 2 are <ver>107+). Without this line
					 * it is indistinguishable from "no pack at all". */
					hdpack_beacon("hdpack: hires.txt is <ver>" + std::to_string(_data->Version)
						+ ", this core supports up to " + std::to_string(HdNesPack::CurrentVersion)
						+ " -> pack REJECTED");
					return false;
				}
"""

# --- one bad PNG kills the whole pack -------------------------------------------
A_IMG = """				if(!ProcessImgTag(lineContent)) {
					return false;
				}
"""
R_IMG = """				if(!ProcessImgTag(lineContent)) {
					/* 0061: a single missing or unreadable PNG fails the ENTIRE
					 * pack, and looks exactly like no pack at all. Name the file. */
					hdpack_beacon("hdpack: <img> \\"" + lineContent
						+ "\\" missing or not a readable PNG -> whole pack REJECTED");
					return false;
				}
"""

# --- the catch-all, which currently throws away everything it knows -------------
A_CATCH = """		LoadCustomPalette();
		InitializeHdPack();

		return true;
	} catch(std::exception &ex) {
		return false;
	}
"""
R_CATCH = """		LoadCustomPalette();
		InitializeHdPack();

		/* 0061: the success line. Console::LoadHdPack only swaps in HdPpu when
		 * at least one of these two is non-empty, so a pack that parses fine and
		 * still shows nothing is visible here as 0 tiles and 0 backgrounds. */
		hdpack_beacon("hdpack: LOADED <ver>" + std::to_string(_data->Version)
			+ " scale=" + std::to_string(_data->Scale)
			+ " tiles=" + std::to_string(_data->Tiles.size())
			+ " backgrounds=" + std::to_string(_data->Backgrounds.size())
			+ " from \\"" + _hdPackFolder + "\\"");

		return true;
	} catch(std::exception &ex) {
		/* 0061: currentLine is maintained a few lines up for exactly this, and
		 * upstream then discards it along with the exception. */
		hdpack_beacon(std::string("hdpack: hires.txt parse threw \\"") + ex.what()
			+ "\\" on line \\"" + currentLine + "\\" -> pack REJECTED");
		return false;
	}
"""

text = SRC.read_text()
if "hdpack_beacon" in text:
    sys.exit("0058/0061 already applied to vendor — reverse it out before regenerating")
if "hdpack-debug" in text:
    sys.exit("vendor still carries overlay 0023 — reverse it out first")

hunks = []
for anchor, repl in ((A_INC, R_INC), (A_INIT, R_INIT),
                     (A_FILE, R_FILE), (A_VER, R_VER), (A_IMG, R_IMG), (A_CATCH, R_CATCH)):
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

if OLD.exists():
    print(f"NOTE: {OLD.name} is superseded by 0061 and must be deleted "
          "(git rm) before scripts/apply-overlay.sh runs — both target the same region.")

subprocess.run(
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/mesen"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
