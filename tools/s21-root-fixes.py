#!/usr/bin/env python3
"""S21 root fixes found from the kernel's "crash:" keep log (runs 172-174). Idempotent.

  s21-root-fixes.py MOUNTED_ROOT

- /private/var/mobile/tmp (1777, mobile): app extensions get /private/var/mobile as their container (sandbox op 4,
  patch 0129), so their tmp dir is /private/var/mobile/tmp. Without it the wallpaper poster extensions abort in
  BaseBoard: "unexpected mkdtemp result with errno=2 ... /private/var/mobile/tmp/com.apple.posterkit.provider".
- launchd jobs removed (crash loops, not needed on this port):
    com.apple.remotemanagementd  NSFileManager createDirectoryAtURL: nil (no system group container), every few s
    com.apple.progressd          "BUG IN CLIENT OF LIBPLATFORM: Trying to recursively lock an os_unfair_lock"
"""
import os, plistlib, sys

MOBILE = 501
REMOVE = {'com.apple.remotemanagementd', 'com.apple.progressd'}


def main(root):
    t = os.path.join(root, 'private/var/mobile/tmp')
    os.makedirs(t, exist_ok=True)
    os.chmod(t, 0o1777)
    try:
        os.chown(t, MOBILE, MOBILE)
    except PermissionError:
        pass
    print('tmp:', oct(os.stat(t).st_mode & 0o7777), os.stat(t).st_uid)
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    with open(path, 'rb') as f:
        pl = plistlib.load(f)
    removed = []
    for sect in ('LaunchDaemons', 'LaunchAgents'):
        jobs = pl.get(sect, {})
        for k in [k for k, j in jobs.items() if isinstance(j, dict) and j.get('Label') in REMOVE]:
            removed.append(jobs[k].get('Label'))
            del jobs[k]
    if removed:
        st = os.stat(path)
        with open(path, 'wb') as f:
            plistlib.dump(pl, f, fmt=plistlib.FMT_BINARY)
        os.chmod(path, st.st_mode & 0o7777)
    print('launchd.plist removed:', removed or 'nothing (already done)')


if __name__ == '__main__':
    main(sys.argv[1])
