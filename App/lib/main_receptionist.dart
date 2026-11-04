import 'app_edition.dart';
import 'main.dart';

/// Entry point of the RECEPTIONIST app, installed on the front-desk tablet(s).
///
/// Build it with:
///     flutter build apk -t lib/main_receptionist.dart
/// It opens on "Staff Login" (username and password) and contains only the
/// receptionist's screens: the room grid and the shop sale.
void main() => runGracelandApp(AppEdition.receptionist);
