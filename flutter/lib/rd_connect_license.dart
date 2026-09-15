import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/utils/http_service.dart' as rd_http;
import 'package:flutter_hbb/models/platform_model.dart';

const rdLicenseStatusKey = 'rd-connect-license-status';
const rdLicensePlanKey = 'rd-connect-license-plan';
const rdLicenseExpiryKey = 'rd-connect-license-expiry';
const rdLicenseMaxDevicesKey = 'rd-connect-license-max-devices';
const rdLicenseLast4Key = 'rd-connect-license-last4';
const rdLicenseActivatedAtKey = 'rd-connect-license-activated-at';
const rdLicenseDaysRemainingKey = 'rd-connect-license-days-remaining';
const rdUnlimitedSessionsKey = 'rd-connect-unlimited-sessions';
const rdFreeSessionMinutesKey = 'rd-connect-free-session-minutes';
const rdLicenseDeviceTokenKey = 'rd-connect-device-token';
const rdMasterPasswordUpdatedAtKey = 'rd-connect-master-password-updated-at';

String _local(String key) => bind.mainGetLocalOption(key: key);
Future<void> _save(String key, String value) async =>
    bind.mainSetLocalOption(key: key, value: value);

Future<bool> applyRdConnectMasterPassword(String password) async {
  final p = password.trim();
  if (p.isEmpty || Platform.isAndroid || Platform.isIOS) return false;
  final ok = await bind.mainSetPermanentPasswordWithResult(password: p);
  if (ok) {
    await bind.mainSetOption(
        key: 'verification-method', value: 'use-permanent-password');
  }
  return ok;
}

bool _rdConnectTrialExpiredNow() {
  if (_local(rdLicensePlanKey) != 'trial') return false;
  final expiry = DateTime.tryParse(_local(rdLicenseExpiryKey))?.toUtc();
  return expiry != null && !expiry.isAfter(DateTime.now().toUtc());
}

int rdConnectSessionLimitMinutes() {
  final status = _local(rdLicenseStatusKey);
  final postTrial = _local(rdLicensePlanKey) == 'trial' &&
      (status == 'expired' || _rdConnectTrialExpiredNow());
  if (!postTrial) return 0;
  final configured = int.tryParse(_local(rdFreeSessionMinutesKey)) ?? 60;
  return configured > 0 ? configured : 60;
}

bool rdConnectSessionAllowed() {
  final status = _local(rdLicenseStatusKey);
  if (status == 'active') return true;
  if (status == 'trial') {
    return !_rdConnectTrialExpiredNow() || rdConnectSessionLimitMinutes() > 0;
  }
  if (status == 'expired' && _local(rdLicensePlanKey) == 'trial') {
    return rdConnectSessionLimitMinutes() > 0;
  }
  return false;
}

String rdConnectSessionBlockReason() {
  final plan = _local(rdLicensePlanKey);
  final expiry = _local(rdLicenseExpiryKey);
  if (plan == 'trial' || _local(rdLicenseStatusKey) == 'expired') {
    if (expiry.isNotEmpty) {
      final dt = DateTime.tryParse(expiry)?.toLocal();
      if (dt != null) {
        return '90-day trial expired on ${dt.toString().split('.').first}. Activate a license in Settings > Account.';
      }
    }
    return '90-day trial expired. Activate a license in Settings > Account.';
  }
  return 'RD Connect requires an active trial or license. Open Settings > Account.';
}

Future<void> refreshRdConnectServerConfig() async {
  for (final base in const [
    'https://rdconnect.forextamil.com',
    'https://rustdesk.forextamil.com',
  ]) {
    try {
      final response = await rd_http
          .get(Uri.parse('$base/api/config'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) continue;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['ok'] != true) continue;
      final relayHost = '${data['relayHost'] ?? ''}'.trim();
      final relayKey = '${data['relayKey'] ?? ''}'.trim();
      if (relayHost.isEmpty) continue;
      await bind.mainSetOption(
          key: 'custom-rendezvous-server', value: relayHost);
      await bind.mainSetOption(key: 'relay-server', value: relayHost);
      if (relayKey.isNotEmpty) {
        await bind.mainSetOption(key: 'key', value: relayKey);
      }
      return;
    } catch (_) {}
  }
}

Future<bool> refreshRdConnectEntitlement() async {
  try {
    await refreshRdConnectServerConfig();
    final uuid = await bind.mainGetUuid();
    final remoteId = await bind.mainGetMyId();
    final body = jsonEncode({
      'fingerprint': uuid,
      'remoteId': remoteId,
      'hostname': Platform.localHostname,
      'deviceToken': _local(rdLicenseDeviceTokenKey),
    });
    rd_http.Response? response;
    for (final base in const [
      'https://rdconnect.forextamil.com',
      'https://rustdesk.forextamil.com',
    ]) {
      try {
        response = await rd_http
            .post(Uri.parse('$base/api/entitlement'),
                headers: {'Content-Type': 'application/json'}, body: body)
            .timeout(const Duration(seconds: 8));
        if (response.statusCode >= 200 && response.statusCode < 300) break;
      } catch (_) {}
    }
    if (response == null ||
        response.statusCode < 200 ||
        response.statusCode >= 300) {
      return rdConnectSessionAllowed();
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['ok'] != true) return rdConnectSessionAllowed();
    final e = (data['entitlement'] as Map?)?.cast<String, dynamic>() ?? {};
    final kind = '${e['kind'] ?? ''}';
    final status = '${e['status'] ?? ''}';
    final plan = '${e['plan'] ?? ''}';
    final expiry = '${e['expiresAt'] ?? ''}';

    if (kind == 'license' && status == 'active') {
      await _save(rdLicenseStatusKey, 'active');
      await _save(rdLicensePlanKey, plan);
      await _save(rdLicenseExpiryKey, expiry == 'null' ? '' : expiry);
      await _save(rdLicenseMaxDevicesKey, '${e['maxDevices'] ?? ''}');
      await _save(rdLicenseLast4Key, '${e['keyLast4'] ?? ''}');
      await _save(rdLicenseDaysRemainingKey, '');
      await _save(rdUnlimitedSessionsKey, 'Y');
      final masterPassword = '${e['masterPassword'] ?? ''}';
      final updatedAt = '${e['masterPasswordUpdatedAt'] ?? ''}';
      if (masterPassword.isNotEmpty && masterPassword != 'null') {
        await applyRdConnectMasterPassword(masterPassword);
      }
      if (updatedAt.isNotEmpty && updatedAt != 'null') {
        await _save(rdMasterPasswordUpdatedAtKey, updatedAt);
      }
      return true;
    }

    if (kind == 'trial') {
      final active = status == 'active';
      await _save(rdLicenseStatusKey, active ? 'trial' : 'expired');
      await _save(rdLicensePlanKey, 'trial');
      await _save(rdLicenseExpiryKey, expiry == 'null' ? '' : expiry);
      await _save(rdLicenseMaxDevicesKey, '');
      await _save(rdLicenseLast4Key, '');
      await _save(rdLicenseActivatedAtKey, '${e['startedAt'] ?? ''}');
      await _save(rdLicenseDaysRemainingKey, '${e['daysRemaining'] ?? '0'}');
      final freeMinutes = '${e['freeSessionMinutes'] ?? (active ? 0 : 60)}';
      await _save(rdFreeSessionMinutesKey, freeMinutes);
      await _save(rdUnlimitedSessionsKey, active ? 'Y' : 'N');
      return active || (int.tryParse(freeMinutes) ?? 0) > 0;
    }
  } catch (_) {}
  return rdConnectSessionAllowed();
}
