import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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
    final plist =
        File('${agentDir.path}/com.forextamil.rdconnect.updater.plist');
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
      await Process.run('/bin/launchctl',
          ['bootout', 'gui/$uid/com.forextamil.rdconnect.updater']);
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

class RdConnectUpdateInfo {
  const RdConnectUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.updateUrl,
    required this.updateSha256,
    required this.updateAvailable,
  });

  final String currentVersion;
  final String latestVersion;
  final String updateUrl;
  final String updateSha256;
  final bool updateAvailable;
}

bool _rdConnectVersionGreater(String latest, String current) {
  List<int> parts(String value) => value
      .split('.')
      .map(
          (part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9].*'), '')) ?? 0)
      .toList();
  final a = parts(latest);
  final b = parts(current);
  for (var i = 0; i < 4; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

Future<RdConnectUpdateInfo> checkRdConnectUpdateNow(
    String currentVersion) async {
  final response = await http
      .get(Uri.parse('https://rdconnect.forextamil.com/api/config'))
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw HttpException('Update server returned HTTP ${response.statusCode}.');
  }
  final data = jsonDecode(response.body) as Map<String, dynamic>;
  String latest = '';
  String url = '';
  String expectedSha256 = '';
  if (Platform.isWindows) {
    latest = '${data['windowsVersion'] ?? ''}'.trim();
    url = '${data['windowsUpdateUrl'] ?? ''}'.trim();
    expectedSha256 =
        '${data['windowsUpdateSha256'] ?? ''}'.trim().toLowerCase();
  } else if (Platform.isMacOS) {
    latest = '${data['macVersion'] ?? ''}'.trim();
    url = '${data['macUpdateUrl'] ?? ''}'.trim();
    expectedSha256 = '${data['macUpdateSha256'] ?? ''}'.trim().toLowerCase();
  } else {
    throw UnsupportedError(
        'Software Update is supported on Windows and macOS.');
  }
  if (latest.isEmpty || url.isEmpty || expectedSha256.isEmpty) {
    throw const FormatException('Update metadata is incomplete.');
  }
  return RdConnectUpdateInfo(
    currentVersion: currentVersion,
    latestVersion: latest,
    updateUrl: url,
    updateSha256: expectedSha256,
    updateAvailable: _rdConnectVersionGreater(latest, currentVersion),
  );
}

Future<void> installRdConnectUpdate(RdConnectUpdateInfo update) async {
  if (!update.updateAvailable) return;
  if (Platform.isWindows) {
    final temp = File(
        '${Directory.systemTemp.path}\\RD-Connect-Update-${update.latestVersion}.exe');
    final request = await HttpClient().getUrl(Uri.parse(update.updateUrl));
    final response = await request.close().timeout(const Duration(minutes: 2));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
          'Update download returned HTTP ${response.statusCode}.');
    }
    final sink = temp.openWrite();
    await response.pipe(sink);
    if (!await temp.exists() || await temp.length() < 32 * 1024) {
      throw const FileSystemException('Downloaded updater is incomplete.');
    }
    final downloadedSha256 =
        sha256.convert(await temp.readAsBytes()).toString();
    if (downloadedSha256 != update.updateSha256) {
      throw const FileSystemException(
          'Downloaded updater SHA-256 verification failed.');
    }
    await Process.start(temp.path, const [], mode: ProcessStartMode.detached);
    return;
  }
  if (Platform.isMacOS) {
    await ensureRdConnectMacAutoUpdater();
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const FileSystemException('Unable to locate the user home folder.');
    }
    final script = '$home/Library/Application Support/RDConnect/updater.sh';
    final result = await Process.run('/bin/zsh', [script]);
    if (result.exitCode != 0) {
      throw ProcessException(
          '/bin/zsh', [script], '${result.stderr}'.trim(), result.exitCode);
    }
    await Process.start(
      '/bin/zsh',
      ['-c', 'sleep 2; /usr/bin/open "/Applications/RD Connect.app"'],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
  throw UnsupportedError('Software Update is supported on Windows and macOS.');
}
