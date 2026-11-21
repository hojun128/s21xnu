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
REMOVE = {'com.apple.remotemanagementd', 'com.apple.progressd',
          # CPU hogs on this phone (kernel cputop, run190: vmd 96 %, launchd 95 %, mediaserverd 50 %, logd 20 % of a
          # core with the home screen idle). Same set PixOS drops (sweet-root-tweaks.py DROPPED_JOBS): visual voicemail
          # retries a missing telephony service forever; fairplayd relaunches forever; the crash/diagnostics daemons cost
          # CPU on every crash (the kernel keeps its own crash log).
          'com.apple.voicemail.vmd', 'com.apple.fairplayd.H2', 'com.apple.ReportCrash', 'com.apple.spindump',
          'com.apple.tailspind', 'com.apple.aggregated', 'com.apple.aggregated.addaily'}


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
    # mediaserverd spun at ~50 % of a core: the virtual audio HAL plug-in cannot load without an audio device, and the
    # MediaToolbox recorder server keeps retrying (as PixOS: plug-in moved aside, recorder server off)
    import glob, shutil
    hal = os.path.join(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin')
    if os.path.exists(hal):
        dst = os.path.join(root, 'Library/Audio/Plug-Ins/HAL.disabled')
        os.makedirs(dst, exist_ok=True)
        shutil.move(hal, os.path.join(dst, 'VirtualAudio.plugin'))
        print('VirtualAudio.plugin moved aside')
    # The CPU hog itself (plugin hog sampler, run200): BTAudioHALPlugin inside mediaserverd reconnects to the Bluetooth
    # daemon's XPC service from its connection-invalidated handler at once; there is no Bluetooth stack here, so each
    # lookup fails and the next starts immediately: mediaserverd ~50 % + launchd ~65 % of a core answering the lookups.
    bt = os.path.join(root, 'System/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver')
    if os.path.exists(bt):
        dst = os.path.join(root, 'System/Library/Audio/Plug-Ins/HAL.disabled')
        os.makedirs(dst, exist_ok=True)
        shutil.move(bt, os.path.join(dst, 'BTAudioHALPlugin.driver'))
        print('BTAudioHALPlugin.driver moved aside')
    for cfg in glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')) + \
            glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/SubServerConfiguration.plist')):
        with open(cfg, 'rb') as f:
            pl = plistlib.load(f)
        if pl.get('StartRecorderServer') is not False:
            pl['StartRecorderServer'] = False
            st = os.stat(cfg)
            with open(cfg, 'wb') as f:
                plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
            os.chmod(cfg, st.st_mode & 0o7777)
            print('recorder server off:', os.path.relpath(cfg, root))
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    with open(path, 'rb') as f:
        pl = plistlib.load(f)
    removed = []
    for sect in ('LaunchDaemons', 'LaunchAgents'):
        jobs = pl.get(sect, {})
        for k in [k for k, j in jobs.items() if isinstance(j, dict) and j.get('Label') in REMOVE]:
            removed.append(jobs[k].get('Label'))
            del jobs[k]
    # S21_CA_VSYNC=1: CA_FORCE_TIMER=1 in backboardd's job (as PixOS and z3sios). Despite the name, QuartzCore then
    # follows the display's vsync notifications (IOMobileFramebufferEnableVSyncNotifications, selector 72, type 5)
    # instead of its own CADisplayTimer, which on every iOS 16 chip id runs out of phase with the panel.
    # S21_CA_VSYNC=0 takes it out again; unset leaves the job as it is.
    cav = os.environ.get('S21_CA_VSYNC')
    changed = bool(removed)
    if cav in ('0', '1'):
        for j in pl.get('LaunchDaemons', {}).values():
            if not (isinstance(j, dict) and j.get('Label') == 'com.apple.backboardd'):
                continue
            env = j.setdefault('EnvironmentVariables', {})
            if cav == '1' and env.get('CA_FORCE_TIMER') != '1':
                env['CA_FORCE_TIMER'] = '1'
                changed = True
            elif cav == '0' and 'CA_FORCE_TIMER' in env:
                del env['CA_FORCE_TIMER']
                if not env:
                    del j['EnvironmentVariables']
                changed = True
            print('backboardd CA_FORCE_TIMER:', j.get('EnvironmentVariables', {}).get('CA_FORCE_TIMER'))
    # Wi-Fi (kernel sweetwifi=4): wifid's job is limited to device trees with a 'wlan' or 'marconi-wifi' node, which
    # ours has not, so launchd never started it and Settings showed Wi-Fi off (run215; z3sios drops the key too). Without
    # a radio it comes up, finds no interface and idles (z3sios measured no cost).
    for j in pl.get('LaunchDaemons', {}).values():
        if isinstance(j, dict) and j.get('Label') == 'com.apple.wifid' and '_LimitLoadToDeviceTree' in j:
            del j['_LimitLoadToDeviceTree']
            changed = True
            print('wifid: device tree limit removed')
    # mediaserverd dies with an uncaught NSException when AVPlayer starts (run230: -[__NSCFNumber objectForKey:]); the
    # crash note has no stack. CoreFoundation prints "First throw call stack" to stderr with CFLOG_FORCE_STDERR, so the
    # job's stderr goes to a file vtprobe reads back.
    for j in pl.get('LaunchDaemons', {}).values():
        if isinstance(j, dict) and j.get('Label') == 'com.apple.mediaserverd':
            env = j.setdefault('EnvironmentVariables', {})
            if env.get('CFLOG_FORCE_STDERR') != '1' or j.get('StandardErrorPath') != '/private/var/tmp/mediaserverd.err':
                env['CFLOG_FORCE_STDERR'] = '1'
                j['StandardErrorPath'] = '/private/var/tmp/mediaserverd.err'
                changed = True
            print('mediaserverd stderr:', j.get('StandardErrorPath'))
    if changed:
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
