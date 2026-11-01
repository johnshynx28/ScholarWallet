import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';

/// Thrown for expected, user-facing failures (unknown QR, already received...).
class WalletException implements Exception {
  final String message;
  WalletException(this.message);
  @override
  String toString() => message;
}

/// ALL money movement lives here.
///
/// v2 rules (scholar wallet only):
///  * The admin sets ONE standard allowance amount. Every scholar receives
///    exactly that amount — there is no per-scholar amount anywhere.
///  * A payout batch creates one single-use QR claim per scholar.
///  * The scholar confirms receipt by scanning that QR; the claim flips to
///    `received`, the balance is credited and a ledger entry is written.
///  * There is NO withdrawal / cash-out / GCash request flow at all.
class WalletService {
  final SupabaseClient _db = Supabase.instance.client;

  final Random _rng = Random.secure();

  /// 32-char URL-safe random token embedded in the QR image.
  String newToken() {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    return List.generate(32, (_) => alphabet[_rng.nextInt(alphabet.length)])
        .join();
  }

  // ------------------------------------------------- allowance (admin-owned)
  Future<AllowanceSettings> getAllowanceSettings() async {
    try {
      final row = await _db
          .from('allowance_settings')
          .select()
          .eq('id', 1)
          .maybeSingle();
      if (row == null) return AllowanceSettings.fallback;
      return AllowanceSettings.fromMap(Map<String, dynamic>.from(row));
    } catch (_) {
      // Table not migrated yet / offline: fall back to the fixed default so
      // the UI never shows a broken screen.
      return AllowanceSettings.fallback;
    }
  }

  /// Sets the single, uniform allowance. Applies to every scholar at once.
  Future<void> setAllowanceAmount(double amount, {String? label}) async {
    if (amount <= 0) {
      throw WalletException('Allowance amount must be greater than zero.');
    }
    await _db.from('allowance_settings').upsert({
      'id': 1,
      'allowance_amount': amount,
      if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ------------------------------------------------------------------ wallet
  Future<double> getBalance(String scholarId) async {
    final row = await _db
        .from('profiles')
        .select('balance')
        .eq('id', scholarId)
        .maybeSingle();
    if (row == null) return 0;
    return ((row['balance'] ?? 0) as num).toDouble();
  }

  Future<List<WalletTransaction>> getTransactions(String scholarId,
      {int limit = 50}) async {
    final rows = await _db
        .from('transactions')
        .select()
        .eq('scholar_id', scholarId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((m) => WalletTransaction.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  // -------------------------------------------------------- payout batches
  /// Admin: create a payout batch. The amount is NOT an argument — it is
  /// always the single global allowance, so one scholar can never be paid
  /// more or less than another. Returns the generated claims (each carrying
  /// its own single-use QR token).
  Future<List<AllowanceClaim>> generatePayoutBatch({
    required String batchTitle,
    required List<Scholar> recipients,
  }) async {
    if (recipients.isEmpty ||
        recipients.any((s) =>
            !s.active || s.verificationStatus != VerificationStatus.approved)) {
      throw WalletException('Select only active, verified scholars.');
    }
    final result = await _db.rpc('issue_verified_payout', params: {
      'p_title': batchTitle.trim(),
      'p_recipients': recipients.map((s) => s.id).toList(),
    });
    return (result as List)
        .map((row) =>
            AllowanceClaim.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  /// Claims that are still waiting for the scholar to scan their QR.
  Future<List<AllowanceClaim>> getPendingClaims(String scholarId) async {
    try {
      final rows = await _db
          .from('allowance_claims')
          .select()
          .eq('scholar_id', scholarId)
          .eq('status', 'issued')
          .order('issued_at', ascending: false);
      return (rows as List)
          .map((m) =>
              AllowanceClaim.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<AllowanceClaim>> getMyClaims(String scholarId,
      {int limit = 60}) async {
    try {
      final rows = await _db
          .from('allowance_claims')
          .select()
          .eq('scholar_id', scholarId)
          .order('issued_at', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((m) =>
              AllowanceClaim.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<AllowanceClaim>> getClaimsForBatch(String batchId) async {
    final rows = await _db
        .from('allowance_claims')
        .select('*, profiles(full_name)')
        .eq('batch_id', batchId)
        .order('id');
    return (rows as List)
        .map((m) => AllowanceClaim.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
  }

  /// Admin: every claim ever issued, newest first (status oversight).
  Future<List<AllowanceClaim>> getAllClaims({int limit = 200}) async {
    try {
      final rows = await _db
          .from('allowance_claims')
          .select('*, profiles(full_name)')
          .order('issued_at', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((m) =>
              AllowanceClaim.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
    } catch (_) {
      final rows = await _db
          .from('allowance_claims')
          .select()
          .order('issued_at', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((m) =>
              AllowanceClaim.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList();
    }
  }

  /// Admin: cancel a claim that was never scanned.
  Future<void> voidClaim(String claimId) async {
    await _db
        .from('allowance_claims')
        .update({'status': 'voided'})
        .eq('id', claimId)
        .eq('status', 'issued');
  }

  /// Read the claim behind a scanned token without redeeming it, so the
  /// scholar can see the amount before confirming with a fingerprint.
  Future<AllowanceClaim?> previewClaim(String token) async {
    try {
      final row = await _db
          .from('allowance_claims')
          .select('*, profiles(full_name)')
          .eq('token', token)
          .maybeSingle();
      if (row == null) return null;
      return AllowanceClaim.fromMap(Map<String, dynamic>.from(row));
    } catch (_) {
      return null;
    }
  }

  /// Admin: how much money is reserved but not yet received (issued claims).
  Future<double> getReservedTotal(String scholarId) async {
    final claims = await getPendingClaims(scholarId);
    return claims.fold<double>(0, (sum, c) => sum + c.amount);
  }

  /// Scholar: confirm receipt of the payout encoded in [token].
  ///
  /// Validation is done server-side inside the `claim_allowance` RPC
  /// (single use, right scholar, not voided) so the balance can never be
  /// credited twice. The lookup below only exists to produce a clear message.
  Future<double> claimAllowance({
    required String token,
    required String scholarId,
  }) async {
    Map<String, dynamic>? row;
    try {
      row = await _db
          .from('allowance_claims')
          .select()
          .eq('token', token)
          .maybeSingle();
    } catch (_) {
      row = null;
    }

    if (row != null) {
      final claim = AllowanceClaim.fromMap(Map<String, dynamic>.from(row));
      if (claim.scholarId != scholarId) {
        throw WalletException(
            'This QR code was issued to another scholar (${claim.scholarName}).');
      }
      if (claim.status == ClaimStatus.received) {
        throw WalletException(
            'Already received on ${_fmt(claim.claimedAt)} — the QR is single use.');
      }
      if (claim.status == ClaimStatus.voided) {
        throw WalletException('This payout was cancelled by the admin.');
      }
    }

    try {
      final res = await _db.rpc('claim_allowance', params: {
        'p_token': token,
        'p_scholar_id': scholarId,
      });
      if (res is num) return res.toDouble();
      if (row != null) return ((row['amount'] ?? 0) as num).toDouble();
      return 0;
    } on PostgrestException catch (e) {
      throw WalletException(_friendlyRpc(e.message));
    } catch (e) {
      throw WalletException(
          'Could not confirm receipt. Check your connection and try again. ($e)');
    }
  }

  String _friendlyRpc(String raw) {
    if (raw.contains('SCHOLAR_NOT_VERIFIED')) {
      return 'Only active, admin-verified scholars can receive allowance.';
    }
    if (raw.contains('CLAIM_ALREADY_RECEIVED')) {
      return 'This payout was already confirmed — each QR can only be used once.';
    }
    if (raw.contains('CLAIM_NOT_FOUND')) {
      return 'This QR code is not a valid Scholar Wallet payout.';
    }
    if (raw.contains('CLAIM_WRONG_SCHOLAR')) {
      return 'This QR code belongs to another scholar.';
    }
    if (raw.contains('CLAIM_VOIDED')) {
      return 'This payout was cancelled by the admin.';
    }
    return 'Could not confirm receipt: $raw';
  }

  String _fmt(DateTime? d) {
    if (d == null) return 'an earlier date';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  // ---------------------------------------------------------------- admin
  Future<int> getActiveScholarCount() async {
    final rows = await _db
        .from('profiles')
        .select('id')
        .eq('role', 'scholar')
        .eq('is_active', true)
        .eq('verification_status', 'approved');
    return (rows as List).length;
  }

  Future<int> getPendingClaimCount() async {
    try {
      final rows = await _db
          .from('allowance_claims')
          .select('id')
          .eq('status', 'issued');
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> getReceivedClaimCount() async {
    try {
      final rows = await _db
          .from('allowance_claims')
          .select('id')
          .eq('status', 'received');
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  Future<List<Scholar>> getScholars() async {
    final rows = await _db
        .from('profiles')
        .select()
        .eq('role', 'scholar')
        .order('full_name');
    return (rows as List)
        .map((m) => Scholar.fromMap(m as Map<String, dynamic>))
        .toList();
  }

  Future<void> setScholarActive(String id, bool active) =>
      _db.rpc('set_verified_scholar_active',
          params: {'p_scholar_id': id, 'p_active': active});

  Future<List<Map<String, dynamic>>> getDisbursements() async {
    final rows = await _db
        .from('disbursements')
        .select()
        .order('created_at', ascending: false)
        .limit(50);
    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Admin overview numbers for the dashboard.
  Future<Map<String, num>> getAllowanceSummary() async {
    final settings = await getAllowanceSettings();
    final pending = await getPendingClaimCount();
    final received = await getReceivedClaimCount();
    return {
      'amount': settings.allowanceAmount,
      'pending': pending,
      'received': received,
    };
  }
}