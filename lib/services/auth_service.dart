import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../models/models.dart';

/// AUTHENTICATION: Firebase Auth (email + password).
/// PROFILE DATA: Supabase `profiles` table keyed by Firebase UID.
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final SupabaseClient _db = Supabase.instance.client;

  Stream<User?> get authState => _auth.authStateChanges();
  User? get currentFirebaseUser => _auth.currentUser;

  /// Sign in, then load the matching profile row from Supabase.
  Future<AppUser> signIn({
    required String email,
    required String password,
  }) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return _loadProfile(cred.user!);
  }

  // Completes when the profile row of a brand-new account is inserted, so the
  // AuthGate never loads the profile before it exists (race on sign up).
  Future<void>? _pendingSignup;

  /// Create Firebase account + insert a Supabase profile row.
  Future<AppUser> signUp({
    required String fullName,
    required String email,
    required String password,
    required String studentNumber,
    required String university,
    required String program,
    required String yearLevel,
    required bool declaredScholar,
    required String scholarshipName,
    required String scholarshipReference,
  }) async {
    if (declaredScholar && scholarshipName.trim().isEmpty) {
      throw ArgumentError('Enter the scholarship you already belong to.');
    }
    final completer = Completer<void>();
    _pendingSignup = completer.future;
    String? signupUid;
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      signupUid = cred.user!.uid;
      await _ensureDatabaseRole(cred.user!);
      final user = AppUser(
        id: cred.user!.uid,
        fullName: fullName.trim(),
        email: cred.user!.email ?? email.trim(),
        role: UserRole.scholar,
        studentNumber: studentNumber.trim(),
        university: university.trim(),
        program: program.trim(),
        yearLevel: yearLevel,
        declaredScholar: declaredScholar,
        scholarshipName: declaredScholar ? scholarshipName.trim() : '',
        scholarshipReference:
            declaredScholar ? scholarshipReference.trim() : '',
        verificationStatus: VerificationStatus.pending,
        isActive: false,
      );
      await _db.from('profiles').insert({
        'id': user.id,
        'full_name': user.fullName,
        'email': user.email,
        'role': 'scholar',
        'balance': 0,
        'student_number': user.studentNumber,
        'university': user.university,
        'program': user.program,
        'year_level': user.yearLevel,
        'declared_scholar': user.declaredScholar,
        'scholarship_name': user.scholarshipName,
        'scholarship_reference': user.scholarshipReference,
        'verification_status': 'pending',
        'is_active': false,
      });
      return user;
    } catch (_) {
      // Only roll back the account created by this signup attempt.
      // Existing sessions must never be deleted on an email-in-use error.
      if (signupUid != null && _auth.currentUser?.uid == signupUid) {
        try {
          await _auth.currentUser!.delete();
        } catch (_) {
          await _auth.signOut();
        }
      }
      rethrow;
    } finally {
      completer.complete();
      _pendingSignup = null;
    }
  }

  Future<AppUser?> currentAppUser() async {
    final u = _auth.currentUser;
    if (u == null) return null;
    return _loadProfile(u);
  }

  Future<AppUser> _loadProfile(User u) async {
    final pending = _pendingSignup;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    await _ensureDatabaseRole(u);
    Map<String, dynamic>? row;
    for (var attempt = 0;; attempt++) {
      try {
        row =
            await _db.from('profiles').select().eq('id', u.uid).maybeSingle();
        break;
      } on PostgrestException catch (e) {
        // 42501 = the request reached Supabase as `anon` (token without the
        // authenticated claim yet). Refresh the token and try again.
        if (e.code != '42501' || attempt >= 3) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
        await u.getIdToken(true);
      }
    }
    if (row == null) {
      throw StateError(
          'Your registration profile is missing. Contact the administrator.');
    }
    return AppUser.fromMap(row);
  }

  /// onCreate custom claims can take a moment to reach a new account.
  /// The role here is Postgres authentication, NOT the app's admin role.
  Future<void> _ensureDatabaseRole(User user) async {
    var token = await user.getIdTokenResult();
    for (var attempt = 0;
        token.claims?['role'] != 'authenticated' && attempt < 8;
        attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      token = await user.getIdTokenResult(true);
    }
    if (token.claims?['role'] != 'authenticated') {
      throw StateError('Firebase/Supabase authentication is not configured. '
          'The administrator must deploy the authenticated-role claim function.');
    }
  }

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() => _auth.signOut();

  /// Human-readable message for common Firebase errors.
  String friendlyError(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'user-not-found':
          return 'No account found for that email.';
        case 'wrong-password':
          return 'Incorrect password.';
        case 'email-already-in-use':
          return 'That email is already registered.';
        case 'weak-password':
          return 'Password must be at least 6 characters.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        default:
          return e.message ?? 'Authentication failed.';
      }
    }
    return e.toString();
  }
}
