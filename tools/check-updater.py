#!/usr/bin/env python3
"""Create hostile/valid ZIP fixtures and exercise the real KOReader archiver."""
import argparse
import re
import subprocess
import shlex
import tarfile
import warnings
import tempfile
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parents[1]


def fixtures(destination):
    base={"notebook.koplugin/": b"", "notebook.koplugin/locale/": b"",
          "notebook.koplugin/icons/": b"", "notebook.koplugin/main.lua": b"return {}\n",
          "notebook.koplugin/_meta.lua": b'return {version = "v9.9.9"}\n'}
    for case in ("valid", "traversal", "symlink", "duplicate", "invalid-lua", "missing-main", "oversize"):
        entries=dict(base)
        if case=="traversal": entries["notebook.koplugin/../escaped"]=b"bad"
        if case=="invalid-lua": entries["notebook.koplugin/main.lua"]=b"not valid lua ???"
        if case=="missing-main": del entries["notebook.koplugin/main.lua"]
        if case=="oversize": entries["notebook.koplugin/bomb"]=b"x"*(33*1024*1024)
        with zipfile.ZipFile(destination/f"{case}.zip","w",compression=zipfile.ZIP_DEFLATED) as archive:
            for name,data in entries.items(): archive.writestr(name,data)
            if case=="duplicate":
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore",UserWarning)
                    archive.writestr("notebook.koplugin/main.lua",b"return {}")
            if case=="symlink":
                entry=zipfile.ZipInfo("notebook.koplugin/link")
                entry.create_system=3;entry.external_attr=0o120777 << 16
                archive.writestr(entry,b"/etc/passwd")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime",type=Path,default=ROOT.parent/"koreader-src/koreader-emulator-x86_64-pc-linux-gnu-debug/koreader")
    parser.add_argument("--ssh")
    parser.add_argument("--port",type=int,default=22)
    parser.add_argument("--ui",action="store_true",help="Also check the native Updates/page selection layout")
    parser.add_argument("--network",action="store_true")
    parser.add_argument("--from-version", default="1.4.0", help="Older official stable release used by the network replacement test")
    args=parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.from_version):
        parser.error("--from-version must be a stable version such as 1.5.0")
    with tempfile.TemporaryDirectory(prefix="notebook-updater-test-") as directory:
        fixtures(Path(directory))
        if args.ssh:
            ssh=["ssh","-p",str(args.port),"-o","BatchMode=yes","-o","ConnectTimeout=10",args.ssh]
            stage=subprocess.run(ssh+["mktemp -d /tmp/notebook-updater-test.XXXXXX"],capture_output=True,text=True,check=True,timeout=20).stdout.strip()
            if not stage.startswith("/tmp/notebook-updater-test.") or any(c.isspace() for c in stage): raise RuntimeError("Invalid remote directory")
            try:
                with tempfile.TemporaryFile() as payload:
                    with tarfile.open(fileobj=payload,mode="w:gz") as tar:
                        tar.add(ROOT/"lua",arcname="lua",filter=lambda info: None if "/spec" in info.name else info)
                        tar.add(ROOT/"tools/check-updater.lua",arcname="check-updater.lua")
                        if args.ui: tar.add(ROOT/"tools/check-updates-ui.lua",arcname="check-updates-ui.lua")
                        for file in Path(directory).glob("*.zip"): tar.add(file,arcname=file.name)
                    payload.seek(0)
                    subprocess.run(ssh+["tar -xzf - -C "+shlex.quote(stage)],stdin=payload,check=True,timeout=60)
                command="cd /mnt/us/koreader && ./luajit "+shlex.join([stage+"/check-updater.lua",stage+"/lua",stage]+(["--network", "v"+args.from_version] if args.network else []))
                subprocess.run(ssh+[command],check=True,timeout=180)
                if args.ui:
                    ui="cd /mnt/us/koreader && ./luajit "+shlex.join([stage+"/check-updates-ui.lua",stage+"/lua",stage])
                    subprocess.run(ssh+[ui],check=True,timeout=60)
                    for name in ("updates-gallery.png","updates-menu.png","export-pages.png"):
                        data=subprocess.run(ssh+["cat "+shlex.quote(stage+"/"+name)],capture_output=True,check=True,timeout=20).stdout
                        (ROOT/"build").mkdir(exist_ok=True)
                        (ROOT/"build"/("kindle-"+name)).write_bytes(data)
            finally: subprocess.run(ssh+["rm -rf -- "+shlex.quote(stage)],check=True,timeout=30)
            return
        command=[str(args.runtime.resolve()/"luajit"),str(ROOT/"tools/check-updater.lua"),str(ROOT/"lua"),directory]
        if args.network: command.extend(["--network", "v"+args.from_version])
        subprocess.run(command,cwd=args.runtime,check=True,timeout=180)
        if args.ui:
            subprocess.run([str(args.runtime.resolve()/"luajit"),str(ROOT/"tools/check-updates-ui.lua"),str(ROOT/"lua"),directory],cwd=args.runtime,check=True,timeout=60)
            (ROOT/"build").mkdir(exist_ok=True)
            for name in ("updates-gallery.png","updates-menu.png","export-pages.png"):
                (ROOT/"build"/("desktop-"+name)).write_bytes((Path(directory)/name).read_bytes())


if __name__=="__main__":main()
