/// Which of the two separate Graceland apps this installation is.
///
/// The receptionist app and the manager app are built from the same code
/// but are two independent apps: the manager app is installed only on the
/// manager's phone, the receptionist app only on the front-desk tablet(s).
/// Each has its own entry file (main_manager.dart / main_receptionist.dart)
/// and its own login screen.
///
///   receptionist -> "Staff Login": username and password. Accepts
///                   Receptionist accounts and the shared Buffer login.
///   manager      -> "Manager Login": password only, because there is only
///                   one manager. Accepts the Owner account, and the
///                   Manager role too, which is kept in the code for
///                   possible future use even though it is not used today.
enum AppEdition { manager, receptionist }

extension AppEditionRules on AppEdition {
  /// The heading shown on the login screen.
  String get loginTitle => this == AppEdition.manager ? "Manager Login" : "Staff Login";

  /// The account name the manager app signs in with. The manager never
  /// types it: the server's stored name for the one manager account is
  /// still "administrator" (the setup script, the recovery code and the
  /// security test all rely on that), but on screen it simply reads
  /// "Manager".
  static const String managerAccountUsername = "administrator";

  /// Whether an account with this role may sign in to this app. Anything
  /// else is turned away with a plain message, so a receptionist can never
  /// get into the manager app (or the other way round) even if they know a
  /// password.
  bool allowsRole(String role) {
    switch (this) {
      case AppEdition.manager:
        return role == "Owner" || role == "Manager";
      case AppEdition.receptionist:
        return role == "Receptionist" || role == "Buffer";
    }
  }
}

/// Which app this installation is. Set once, at the very start, by
/// main_manager.dart or main_receptionist.dart, and read by the login
/// screen and the shells so they never have to be told again.
AppEdition activeEdition = AppEdition.receptionist;
