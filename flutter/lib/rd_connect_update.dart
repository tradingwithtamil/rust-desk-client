import 'dart:io';

Future<void> ensureRdConnectMacAutoUpdater() async {
  if (!Platform.isMacOS) return;
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return;
  try {
    final base = Directory('$home/Library/Application Support/RDConnect');
    await base.create(recursive: true);
    final script = File('${base.path}/updater.sh');
    const scriptBody = r'''#!/bin/zsh
set -eu
BASE="$HOME/Library/Application Support/RDConnect"
LOG="$BASE/update.log"
APP="/Applications/RD Connect.app"
MANIFEST="https://rdconnect.forextamil.com/api/update/mac"
mkdir -p "$BASE"
LOCK="/tmp/rdconnect-mac-updater.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
log(){ print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }
[[ -d "$APP" ]] || { log "SKIP app missing"; exit 0; }
DATA="$(/usr/bin/curl -fsSL --connect-timeout 15 --max-time 45 "$MANIFEST")" || { log "ERROR manifest"; exit 1; }
LATEST="$(print -r -- "$DATA" | /usr/bin/sed -n '1p')"
URL="$(print -r -- "$DATA" | /usr/bin/sed -n '2p')"
SHA="$(print -r -- "$DATA" | /usr/bin/sed -n '3p' | /usr/bin/tr '[:lower:]' '[:upper:]')"
CURRENT="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || print 0.0.0)"
ver_gt(){ /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN{split(a,A,".");split(b,B,".");for(i=1;i<=4;i++){x=A[i]+0;y=B[i]+0;if(x>y)exit 0;if(x<y)exit 1}exit 1}'; }
if ! ver_gt "$LATEST" "$CURRENT"; then log "OK current=$CURRENT"; exit 0; fi
TMP="/tmp/RD-Connect-macOS-$LATEST-arm64.dmg"
MNT="/tmp/rdconnect-mac-update-mnt"
/usr/bin/curl -fL --connect-timeout 15 --max-time 300 --retry 3 -o "$TMP" "$URL" || { log "ERROR download"; exit 1; }
GOT="$(/usr/bin/shasum -a 256 "$TMP" | /usr/bin/awk '{print toupper($1)}')"
[[ "$GOT" == "$SHA" ]] || { log "ERROR hash"; /bin/rm -f "$TMP"; exit 1; }
/bin/rm -rf "$MNT"; /bin/mkdir -p "$MNT"
/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$TMP" >/dev/null
SRC="$MNT/RD Connect.app"
[[ -d "$SRC" ]] || { /usr/bin/hdiutil detach "$MNT" -force >/dev/null 2>&1 || true; log "ERROR app missing in dmg"; exit 1; }
NEW="/Applications/RD Connect.app.rdc-new"; OLD="/Applications/RD Connect.app.rdc-old"
/bin/rm -rf "$NEW" "$OLD"
/usr/bin/ditto "$SRC" "$NEW"
/usr/bin/codesign --verify --deep --strict "$NEW" >/dev/null 2>&1 || { /bin/rm -rf "$NEW"; log "ERROR codesign verify"; exit 1; }
/bin/mv "$APP" "$OLD" && /bin/mv "$NEW" "$APP" && /bin/rm -rf "$OLD"
/usr/bin/hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
/bin/rm -f "$TMP"
log "UPDATED $CURRENT -> $LATEST"
exit 0
''';
    if (!await script.exists() || await script.readAsString() != scriptBody) {
      await script.writeAsString(scriptBody);
      await Process.run('/bin/chmod', ['755', script.path]);
    }
    final agentDir = Directory('$home/Library/LaunchAgents');
    await agentDir.create(recursive: true);
    final plist = File('${agentDir.path}/com.forextamil.rdconnect.updater.plist');
    final escaped = script.path
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final plistBody = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.forextamil.rdconnect.updater</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>$escaped</string></array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>21600</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>''';
    if (!await plist.exists() || await plist.readAsString() != plistBody) {
      await plist.writeAsString(plistBody);
    }
    final id = await Process.run('/usr/bin/id', ['-u']);
    final uid = id.stdout.toString().trim();
    if (uid.isNotEmpty) {
      await Process.run('/bin/launchctl', [
        'bootout',
        'gui/$uid/com.forextamil.rdconnect.updater'
      ]);
      await Process.run('/bin/launchctl', [
        'bootstrap',
        'gui/$uid',
        plist.path,
      ]);
    }
  } catch (_) {
    // Updater setup must never block RD Connect startup.
  }
}
