#!/usr/bin/env python3
"""S21 root fixes found from the kernel's "crash:" keep log (runs 172-174). Idempotent.

  s21-root-fixes.py MOUNTED_ROOT

- /private/var/mobile/tmp (1777, mobile): app extensions get /private/var/mobile as their container (sandbox op 4,
  patch 0129), so their tmp dir is /private/var/mobile/tmp. Without it the wallpaper poster extensions abort in
  BaseBoard: "unexpected mkdtemp result with errno=2 ... /private/var/mobile/tmp/com.apple.posterkit.provider".
- launchd jobs removed (crash loops, not needed on this port):
    com.apple.remotemanagementd  NSFileManager createDirectoryAtURL: nil (no system group container), every few s
    com.apple.progressd          "BUG IN CLIENT OF LIBPLATFORM: Trying to recursively lock an os_unfair_lock"
- time zone Asia/Seoul (/private/var/db/timezone/localtime pointed at US/Pacific: the clock read 5:11 at 22:36 KST).
- /private/var/mobile/Library/Health/Client made in advance (healthappd: "Error creating core data store directory",
  NSPOSIXErrorDomain 5 creating it at run time).
- Safari "Fraudulent Website Warning" off: the SafeBrowsing XPC service dereferences a null
  Backend::Google::DeviceIdentificationTokenFetcher (SafariSafeBrowsing+0x519d0, far 0x78) in handleGetDatabases.
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
    tz = os.path.join(root, 'private/var/db/timezone/localtime')
    want = '/var/db/timezone/zoneinfo/Asia/Seoul'
    if os.path.islink(tz) and os.readlink(tz) != want:
        os.unlink(tz)
        os.symlink(want, tz)
        print('timezone ->', want)
    h = root
    for part in ('private/var/mobile/Library/Health', 'private/var/mobile/Library/Health/Client'):
        d = os.path.join(root, part)
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o755)
        try:
            os.chown(d, MOBILE, MOBILE)
        except PermissionError:
            pass
    print('health dirs ready')
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
    pref = os.path.join(root, 'private/var/mobile/Library/Preferences/com.apple.mobilesafari.plist')
    d = {}
    if os.path.exists(pref):
        with open(pref, 'rb') as f:
            d = plistlib.load(f)
    if d.get('WarnAboutFraudulentWebsites') is not False:
        d['WarnAboutFraudulentWebsites'] = False
        os.makedirs(os.path.dirname(pref), exist_ok=True)
        with open(pref, 'wb') as f:
            plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
        os.chmod(pref, 0o600)
        try:
            os.chown(pref, MOBILE, MOBILE)
        except PermissionError:
            pass
        print('safari: fraudulent website warning off')


if __name__ == '__main__':
    main(sys.argv[1])
