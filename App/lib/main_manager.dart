import 'app_edition.dart';
import 'main.dart';

/// Entry point of the MANAGER app, installed only on the manager's phone.
///
/// Build it with:
///     flutter build apk -t lib/main_manager.dart
/// It opens on "Manager Login" (password only) and contains only the
/// manager's screens.
void main() => runGracelandApp(AppEdition.manager);
