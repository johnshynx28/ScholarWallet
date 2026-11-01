// Data models shared across the app.
// All map to Supabase Postgres tables.
//
// NOTE (v2): the cash-out / GCash withdrawal flow was removed. Allowance is
// released by the ADMIN at ONE fixed amount for every scholar, and a scholar
// confirms receipt by scanning the QR code the admin issues for that payout.

import 'dart:convert';

enum UserRole { scholar, admin }

enum VerificationStatus { pending, underReview, needsInfo, approved, rejected }

extension VerificationStatusLabel on VerificationStatus {
  String get label => switch (this) {
        VerificationStatus.pending => 'Pending verification',
        VerificationStatus.underReview => 'Under review',
        VerificationStatus.needsInfo => 'Information required',
        VerificationStatus.approved => 'Verified scholar',
        VerificationStatus.rejected => 'Registration rejected',
      };
  String get databaseValue => switch (this) {
        VerificationStatus.underReview => 'under_review',
        VerificationStatus.needsInfo => 'needs_info',
        _ => name,
      };
}

VerificationStatus verificationStatusFrom(Object? value) =>
    VerificationStatus.values.firstWhere(
      (s) => s.databaseValue == value,
      orElse: () => VerificationStatus.pending,
    );

class AppUser {
  final String id; // Firebase UID == Supabase profiles.id
  final String fullName;
  final String email;
  final UserRole role;
  final String? studentNumber;
  final String? university;
  final String? program;
  final String? yearLevel;
  final bool declaredScholar;
  final String scholarshipName;
  final String scholarshipReference;
  final VerificationStatus verificationStatus;
  final String reviewNotes;
  final bool isActive;

  bool get canReceiveAllowance =>
      role == UserRole.scholar &&
      verificationStatus == VerificationStatus.approved &&
      isActive;

  /// Fingerprint was registered on a device for this account.
  final bool biometricRegistered;
  final DateTime? biometricEnrolledAt;

  AppUser({
    required this.id,
    required this.fullName,
    required this.email,
    this.role = UserRole.scholar,
    this.studentNumber,
    this.university,
    this.program,
    this.yearLevel,
    this.declaredScholar = false,
    this.scholarshipName = '',
    this.scholarshipReference = '',
    this.verificationStatus = VerificationStatus.pending,
    this.reviewNotes = '',
    this.isActive = false,
    this.biometricRegistered = false,
    this.biometricEnrolledAt,
  });

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  factory AppUser.fromMap(Map<String, dynamic> m) => AppUser(
        id: m['id'] as String,
        fullName: (m['full_name'] ?? '') as String,
        email: (m['email'] ?? '') as String,
        role: m['role'] == 'admin' ? UserRole.admin : UserRole.scholar,
        studentNumber: m['student_number'] as String?,
        university: m['university'] as String?,
        program: m['program'] as String?,
        yearLevel: m['year_level'] as String?,
        declaredScholar: m['declared_scholar'] == true,
        scholarshipName: (m['scholarship_name'] ?? '') as String,
        scholarshipReference: (m['scholarship_reference'] ?? '') as String,
        verificationStatus: verificationStatusFrom(m['verification_status']),
        reviewNotes: (m['review_notes'] ?? '') as String,
        isActive: m['is_active'] == true,
        biometricRegistered: (m['biometric_registered'] as bool?) ?? false,
        biometricEnrolledAt: m['biometric_enrolled_at'] is String
            ? DateTime.tryParse(m['biometric_enrolled_at'] as String)
            : null,
      );
}

// ---------------------------------------------------------------- allowance

/// One global allowance setting controlled by the admin.
/// The amount is the SAME for every scholar — it can never be set per user.
class AllowanceSettings {
  final double allowanceAmount;
  final String label;
  final DateTime? updatedAt;

  const AllowanceSettings({
    required this.allowanceAmount,
    this.label = 'Monthly Allowance',
    this.updatedAt,
  });

  static const AllowanceSettings fallback =
      AllowanceSettings(allowanceAmount: 5000, label: 'Monthly Allowance');

  factory AllowanceSettings.fromMap(Map<String, dynamic> m) =>
      AllowanceSettings(
        allowanceAmount: ((m['allowance_amount'] ?? 5000) as num).toDouble(),
        label: (m['label'] ?? 'Monthly Allowance') as String,
        updatedAt: m['updated_at'] is String
            ? DateTime.tryParse(m['updated_at'] as String)
            : null,
      );
}

enum ClaimStatus { issued, received, voided }

/// One QR-coded allowance claim: created by the admin for a single scholar,
/// redeemed by that scholar scanning the QR (single use).
class AllowanceClaim {
  final String id;
  final String batchId;
  final String batchTitle;
  final String scholarId;
  final String scholarName;
  final double amount;
  final String token; // what the QR actually carries
  final ClaimStatus status;
  final DateTime? issuedAt;
  final DateTime? claimedAt;

  AllowanceClaim({
    required this.id,
    required this.batchId,
    required this.batchTitle,
    required this.scholarId,
    required this.scholarName,
    required this.amount,
    required this.token,
    this.status = ClaimStatus.issued,
    this.issuedAt,
    this.claimedAt,
  });

  bool get isReceived => status == ClaimStatus.received;
  bool get isVoided => status == ClaimStatus.voided;
  bool get isPending => status == ClaimStatus.issued;

  /// Payload rendered into the QR the admin shows to the scholar.
  String get qrPayload => jsonEncode({
        't': 'scholar_wallet_claim_v1',
        'tok': token,
        'cid': id,
        'sid': scholarId,
        'amt': amount,
      });

  factory AllowanceClaim.fromMap(Map<String, dynamic> m) {
    final profile = m['profiles'];
    return AllowanceClaim(
      id: m['id'].toString(),
      batchId: (m['batch_id'] ?? '') as String,
      batchTitle: (m['batch_title'] ?? 'Allowance') as String,
      scholarId: (m['scholar_id'] ?? '') as String,
      scholarName: profile is Map
          ? ((profile['full_name'] ?? 'Scholar') as String)
          : ((m['scholar_name'] ?? 'Scholar') as String),
      amount: ((m['amount'] ?? 0) as num).toDouble(),
      token: (m['token'] ?? '') as String,
      status: ClaimStatus.values.firstWhere(
        (s) => s.name == m['status'],
        orElse: () => ClaimStatus.issued,
      ),
      issuedAt: m['issued_at'] is String
          ? DateTime.tryParse(m['issued_at'] as String)
          : null,
      claimedAt: m['claimed_at'] is String
          ? DateTime.tryParse(m['claimed_at'] as String)
          : null,
    );
  }
}

// ------------------------------------------------------------------- ledger

enum TxType { credit, debit }

enum TxStatus { completed, pending, rejected }

class WalletTransaction {
  final String id;
  final String title;
  final String subtitle;
  final double amount; // negative = debit
  final TxType type;
  final TxStatus status;
  final DateTime createdAt;

  WalletTransaction({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.type,
    required this.status,
    required this.createdAt,
  });

  factory WalletTransaction.fromMap(Map<String, dynamic> m) =>
      WalletTransaction(
        id: m['id'].toString(),
        title: (m['title'] ?? '') as String,
        subtitle: (m['subtitle'] ?? '') as String,
        amount: (m['amount'] as num).toDouble(),
        type: m['type'] == 'credit' ? TxType.credit : TxType.debit,
        status: TxStatus.values.firstWhere(
          (s) => s.name == m['status'],
          orElse: () => TxStatus.completed,
        ),
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}

class ExpenseReport {
  final String? id;
  final String scholarId;
  final String title;
  final double amount;
  final String category;
  final String? description;
  final String? receiptUrl;
  final TxStatus status;
  final String scholarName;
  final DateTime? createdAt;

  ExpenseReport({
    this.id,
    required this.scholarId,
    required this.title,
    required this.amount,
    required this.category,
    this.description,
    this.receiptUrl,
    this.status = TxStatus.pending,
    this.scholarName = '',
    this.createdAt,
  });

  factory ExpenseReport.fromMap(Map<String, dynamic> m) {
    final profile = m['profiles'];
    final raw = m['status'];
    return ExpenseReport(
      id: m['id']?.toString(),
      scholarId: (m['scholar_id'] ?? '') as String,
      title: (m['title'] ?? '') as String,
      amount: ((m['amount'] ?? 0) as num).toDouble(),
      category: (m['category'] ?? '') as String,
      description: m['description'] as String?,
      receiptUrl: m['receipt_url'] as String?,
      status: raw == 'approved'
          ? TxStatus.completed
          : TxStatus.values.firstWhere(
              (s) => s.name == raw,
              orElse: () => TxStatus.pending,
            ),
      scholarName: profile is Map
          ? ((profile['full_name'] ?? 'Scholar') as String)
          : 'Scholar',
      createdAt: m['created_at'] is String
          ? DateTime.tryParse(m['created_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toInsert() => {
        'scholar_id': scholarId,
        'title': title,
        'amount': amount,
        'category': category,
        'description': description,
        'receipt_url': receiptUrl,
        'status': status.name,
      };
}

class Scholar {
  final String id;
  final String studentId;
  final String name;
  final double balance;
  bool active;
  bool selected;
  final bool fingerprintRegistered;
  final VerificationStatus verificationStatus;

  Scholar({
    required this.id,
    required this.studentId,
    required this.name,
    required this.balance,
    this.active = true,
    this.selected = false,
    this.fingerprintRegistered = false,
    this.verificationStatus = VerificationStatus.pending,
  });

  factory Scholar.fromMap(Map<String, dynamic> m) => Scholar(
        id: m['id'] as String,
        studentId: (m['student_number'] ?? m['student_id'] ?? '') as String,
        name: (m['full_name'] ?? '') as String,
        balance: ((m['balance'] ?? 0) as num).toDouble(),
        active: m['is_active'] == true,
        verificationStatus: verificationStatusFrom(m['verification_status']),
        fingerprintRegistered: (m['biometric_registered'] as bool?) ?? false,
      );
}

/// One row in the admin "System Activities" feed.
class ActivityItem {
  final String title;
  final String subtitle;
  final String status;
  final DateTime time;

  ActivityItem({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.time,
  });
}
