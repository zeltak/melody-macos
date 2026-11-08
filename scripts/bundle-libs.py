#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Make an app bundle stand on its own.

    bundle-libs.py APP.app [--check]

Every Mach-O file in Contents/MacOS, Contents/Frameworks and Contents/PlugIns
is examined: each library it loads from outside the system (Homebrew's, in
practice) is copied into Contents/Frameworks and the reference rewritten to
@executable_path/../Frameworks/NAME, and so on for what those libraries load.
Search paths into Homebrew are removed, so nothing can quietly be found there
on a machine that happens to have it.

--check only reports references that would not resolve inside the bundle or
the system, and exits 1 if there are any.
"""

import os
import shutil
import subprocess
import sys

SYSTEM = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    with open(path, "rb") as handle:
        magic = handle.read(4)
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def load_commands(path):
    """(id, dependencies, rpaths) of a Mach-O file."""
    text = run("otool", "-l", path)
    ident, deps, rpaths = None, [], []
    command = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            command = line.split()[1]
        elif line.startswith("name ") and command in (
            "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LAZY_LOAD_DYLIB"
        ):
            deps.append(line[5:].rsplit(" (offset", 1)[0])
        elif line.startswith("name ") and command == "LC_ID_DYLIB":
            ident = line[5:].rsplit(" (offset", 1)[0]
        elif line.startswith("path ") and command == "LC_RPATH":
            rpaths.append(line[5:].rsplit(" (offset", 1)[0])
    return ident, deps, rpaths


def expand(path, loader_dir, executable_dir):
    return os.path.normpath(
        path.replace("@loader_path", loader_dir).replace("@executable_path", executable_dir)
    )


def resolve(dep, loader_dir, executable_dir, rpaths, fallback=()):
    """Where a reference leads, or None. `fallback`: folders to look in for
    an @rpath reference the file's own search paths do not find."""
    if dep.startswith("@rpath/"):
        for rpath in rpaths:
            candidate = os.path.join(expand(rpath, loader_dir, executable_dir), dep[len("@rpath/"):])
            if os.path.exists(candidate):
                return os.path.normpath(candidate)
        for folder in fallback:
            candidate = os.path.join(folder, dep[len("@rpath/"):])
            if os.path.exists(candidate):
                return os.path.normpath(candidate)
        return None
    candidate = expand(dep, loader_dir, executable_dir)
    return candidate if os.path.exists(candidate) else None


def macho_files(contents):
    for folder in ("MacOS", "Frameworks", "PlugIns"):
        top = os.path.join(contents, folder)
        for directory, _, names in os.walk(top):
            for name in names:
                path = os.path.join(directory, name)
                if is_macho(path):
                    yield path


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    app = os.path.abspath(sys.argv[1])
    check_only = "--check" in sys.argv[2:]
    contents = os.path.join(app, "Contents")
    executable_dir = os.path.join(contents, "MacOS")
    frameworks = os.path.join(contents, "Frameworks")
    os.makedirs(frameworks, exist_ok=True)

    # A file copied in still resolves @loader_path and its rpaths as it did
    # where it came from.
    # Where Homebrew keeps libraries, for references that lean on a search
    # path of the program that loads them.
    homebrew = [os.path.join(prefix, "lib") for prefix in ("/opt/homebrew", "/usr/local")]
    for prefix in ("/opt/homebrew/opt", "/usr/local/opt"):
        if os.path.isdir(prefix):
            homebrew += sorted(os.path.join(prefix, name, "lib") for name in os.listdir(prefix))
    origin = {}
    queue = list(macho_files(contents))
    seen = set()
    problems = []
    while queue:
        path = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        source = origin.get(path, path)
        ident, deps, rpaths = load_commands(path)
        source_dir = os.path.dirname(source)
        for dep in deps:
            if dep.startswith(SYSTEM):
                continue
            inside = resolve(dep, os.path.dirname(path), executable_dir, rpaths)
            if inside and inside.startswith(contents + os.sep):
                continue
            if check_only:
                problems.append(f"{os.path.relpath(path, app)}: {dep}")
                continue
            found = resolve(dep, source_dir, executable_dir, rpaths, [frameworks] + homebrew)
            if found is None:
                problems.append(f"{os.path.relpath(path, app)}: cannot find {dep}")
                continue
            if ".framework/" in found:
                problems.append(f"{os.path.relpath(path, app)}: framework {dep} is not bundled")
                continue
            name = os.path.basename(dep)
            target = os.path.join(frameworks, name)
            if found.startswith(contents + os.sep):
                target = found
                name = os.path.relpath(found, frameworks)
            if not os.path.exists(target):
                shutil.copy2(os.path.realpath(found), target)
                os.chmod(target, 0o755)
                run("install_name_tool", "-id", f"@executable_path/../Frameworks/{name}", target)
                origin[target] = os.path.realpath(found)
                queue.append(target)
            run("install_name_tool", "-change", dep, f"@executable_path/../Frameworks/{name}", path)
        if not check_only:
            for rpath in rpaths:
                if rpath.startswith(("/opt/homebrew", "/usr/local")):
                    run("install_name_tool", "-delete_rpath", rpath, path)

    if problems:
        print("\n".join(problems), file=sys.stderr)
        sys.exit(1)
    if check_only:
        print(f"{os.path.basename(app)}: every library resolves inside the bundle or the system")


if __name__ == "__main__":
    main()
