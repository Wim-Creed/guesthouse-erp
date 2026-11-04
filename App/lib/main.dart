import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Which of the two separate apps (manager / receptionist) this is
import 'app_edition.dart';

// Makes the on-screen keyboard appear the moment a text field is focused
import 'widgets/keyboard_guardian.dart';

// This shift's bookings and sales, shown to the receptionist
import 'widgets/shift_activity_bar.dart';

// The soft black shared by running-total boxes and banners
import 'widgets/status_colors.dart';

// The one name rule, used to show the logged-in name tidily
import 'widgets/capitalize_words_formatter.dart';

// The colour constants shared with the splash and login backdrop
import 'widgets/champagne_backdrop.dart' show kDeepNavy;

// Links to the network tool file that coordinates data tracking
import 'services/api_service.dart';

// Rings the Time's Up alarm while nobody is logged in on the tablet
import 'services/room_alarm_watcher.dart';

// Makes the whole app fit the screen it runs on
import 'widgets/screen_scaler.dart';

// Links to the launch badge screen shown before login
import 'views/splash_screen.dart';

// Links to the staff entry welcome screen file
import 'views/login_screen.dart';

// Links to the manager's Dashboard screen file
import 'views/manager/dashboard_view.dart';

// Links to the daily expense dashboard screen file
import 'views/manager/daily_costs_view.dart';

// Links to the financial analytics chart screen file
import 'views/manager/business_summary_view.dart';

// Links to the employee profile tracking screen file
import 'views/manager/employee_management_view.dart';

// Links to the property assets configuration screen file
import 'views/manager/room_management_view.dart';

// Links to the login-editing screen file
import 'views/manager/change_login_view.dart';

// Links to the Records tab (Guest Log and Staff Earnings)
import 'views/manager/records_view.dart';

// Links to the receptionist's live room grid and booking flow
import 'views/reception/room_matrix_grid.dart';

// Links to the receptionist's counter shop sales screen
import 'views/reception/counter_shop_pos.dart';

// Links to the shared offline pending-actions indicator
import 'widgets/sync_status_indicator.dart';

/// The primary execution gateway that turns on the application.
///
/// There are TWO separate apps built from this one code base: the manager
/// app and the receptionist app. They are built with their own entry file
/// (main_manager.dart and main_receptionist.dart), or, from this file, by
/// naming the edition when building:
///     flutter run --dart-define=APP_EDITION=manager
/// With nothing named, this file starts the receptionist app.
void main() {
  const String editionName = String.fromEnvironment('APP_EDITION', defaultValue: 'receptionist');
  runGracelandApp(editionName == 'manager' ? AppEdition.manager : AppEdition.receptionist);
}

/// Starts the given edition of the app. Called by main() above and by the
/// two small entry files, so all three behave identically.
void runGracelandApp(AppEdition edition) {
  WidgetsFlutterBinding.ensureInitialized();
  activeEdition = edition;
  // Only the front-desk tablet rings for rooms; the manager's phone never does.
  RoomAlarmWatcher.instance.enabled = edition == AppEdition.receptionist;
  RoomAlarmWatcher.instance.start();
  runApp(const GracelandGatewayApp());
}

/// The top bar's gold: a warm, lively gold between the brand gold used for
/// buttons and accents and a pale champagne, so the wide bar is rich without
/// being harsh.
const Color kTopBarGold = Color(0xffd1ae55);

/// "Move to the previous or next field", sent by the Up and Down arrow keys.
class _MoveBetweenFieldsIntent extends Intent {
  final bool forward;

  const _MoveBetweenFieldsIntent.next() : forward = true;
  const _MoveBetweenFieldsIntent.previous() : forward = false;
}

/// Carries out the move above, but only while the cursor is in a
/// single-line text field. In a multi-line box Up and Down must keep moving
/// the cursor between lines, and on buttons, chips, dropdowns and date
/// pickers the app's normal arrow-key navigation already does the right
/// thing, so in all those places this stands aside and the key is handled
/// as it always was.
class _MoveBetweenFieldsAction extends Action<_MoveBetweenFieldsIntent> {
  @override
  bool isEnabled(_MoveBetweenFieldsIntent intent, [BuildContext? context]) {
    final BuildContext? focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext == null) return false;
    final EditableText? editable = focusedContext.findAncestorWidgetOfExactType<EditableText>();
    return editable != null && editable.maxLines == 1;
  }

  @override
  Object? invoke(_MoveBetweenFieldsIntent intent, [BuildContext? context]) {
    final FocusNode? focused = FocusManager.instance.primaryFocus;
    if (focused == null) return null;
    if (intent.forward) {
      focused.nextFocus();
    } else {
      focused.previousFocus();
    }
    return null;
  }
}

/// This block configures the app's name, visual themes, and startup screen.
class GracelandGatewayApp extends StatelessWidget {
  // Creates a unique identity key for this block of code
  const GracelandGatewayApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Configures the baseline framework rules for the entire interface
    return MaterialApp(
      // Sets the title name displayed by the operating system tab
      title: activeEdition == AppEdition.manager ? 'Graceland Guest House — Manager' : 'Graceland Guest House',
      // Removes the diagnostic debug ribbon banner from the top corner
      debugShowCheckedModeBanner: false,
      // Sets the color palette rules used uniformly across all windows:
      // the deep navy of the badge's lettering as the night-time canvas,
      // with the brand gold as the accent that lights it.
      theme: ThemeData(
        // Forces the application layout to use comfortable night-mode colors
        brightness: Brightness.dark,
        // Assigns our premium corporate gold brand accent color
        primaryColor: const Color(0xffd4af37),
        // Paints the background canvas of all screens a deep midnight navy
        scaffoldBackgroundColor: const Color(0xff0a1426),
        // Pairs specific colors together for validation states and buttons
        colorScheme: const ColorScheme.dark(
          // Binds the gold color theme to primary buttons and highlighted text
          primary: Color(0xffd4af37),
          // GOLD, not green. The theme's "secondary" colour is what Flutter
          // paints behind the selected tab and in other selection highlights
          // (the circle around the chosen Rooms / Shop Sale icon). Green,
          // red, grey and amber belong to STATES only (room status, shift
          // state, profit and loss, success and error messages); they are
          // never reused for design. Design colours are gold, navy, black
          // and white.
          secondary: Color(0xffd4af37),
          secondaryContainer: Color(0xffd4af37),
          onSecondaryContainer: Color(0xff0b1a33),
          // Binds a bright crimson red to errors and blocked alerts
          error: Color(0xffc0392b),
          // Dialogs, menus and sheets sit on the same navy as the cards
          surface: Color(0xff111f3a),
        ),
        // THE TOP BAR, ON EVERY SCREEN OF BOTH APPS: muted champagne gold
        // with deep navy lettering and icons, rounded along its lower edge,
        // with the monogram (a transparent image) sitting on it as if
        // printed there. A soft shadow underneath lifts it off the navy
        // canvas. This is the app-wide theme, so every screen's title bar
        // (booking, extension and so on) has the same bar automatically.
        appBarTheme: const AppBarTheme(
          backgroundColor: kTopBarGold,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(bottom: Radius.circular(14))),
          foregroundColor: kDeepNavy,
          iconTheme: IconThemeData(color: kDeepNavy),
          actionsIconTheme: IconThemeData(color: kDeepNavy),
          titleTextStyle: TextStyle(color: kDeepNavy, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1.0),
          elevation: 3,
          shadowColor: Color(0x66000000),
          scrolledUnderElevation: 3,
          surfaceTintColor: Colors.transparent,
          systemOverlayStyle: SystemUiOverlayStyle.dark,
        ),
        // A gold edge and cursor on whichever field is being typed into,
        // so it is always obvious where the keyboard is pointing
        inputDecorationTheme: const InputDecorationTheme(
          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xffd4af37), width: 1.6)),
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Color(0xffd4af37),
          selectionHandleColor: Color(0xffd4af37),
        ),
        // The receptionist's bottom bar: a gold circle behind the chosen
        // tab, with the icon in navy on top of it.
        navigationBarTheme: NavigationBarThemeData(
          indicatorColor: const Color(0xffd4af37),
          iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
                color: states.contains(WidgetState.selected) ? const Color(0xff0b1a33) : Colors.white70,
              )),
          labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
                fontSize: 12,
                fontWeight: states.contains(WidgetState.selected) ? FontWeight.bold : FontWeight.normal,
                color: states.contains(WidgetState.selected) ? const Color(0xffd4af37) : Colors.white70,
              )),
        ),
        // A thin gold-tinted divider in place of the default grey line
        dividerColor: const Color(0x33d4af37),
      ),
      // Keyboard navigation for the whole app, so nobody has to reach for
      // the mouse: in any single-line text field, Up and Down move to the
      // previous and next field (Left and Right keep moving the cursor,
      // and Enter already moves forward on every form). Everywhere else
      // the built-in arrow-key navigation between buttons, chips and
      // lists is left exactly as it is.
      //
      // The KeyboardGuardian around it all is what makes the on-screen
      // keyboard appear at once whenever a text field gets the cursor,
      // including a field focused automatically when a screen opens.
      //
      // The IdleSplashGuard covers the app with the splash screen after
      // five minutes without a touch or key press; a tap uncovers it and
      // the lock screen asks for the password. After an hour without a
      // touch the person is signed out.
      //
      // The ScreenScaler is outermost: on a screen smaller than the design
      // (a phone) it shrinks the whole app to fit; on a tablet or laptop it
      // does nothing and the app shows at its natural size.
      builder: (context, child) => ScreenScaler(
        child: KeyboardGuardian(
          child: IdleSplashGuard(
            child: Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.arrowDown): _MoveBetweenFieldsIntent.next(),
                SingleActivator(LogicalKeyboardKey.arrowUp): _MoveBetweenFieldsIntent.previous(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _MoveBetweenFieldsIntent: _MoveBetweenFieldsAction(),
                },
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
      // Directs the system to load the launch badge screen on initial startup
      navigatorKey: kAppNavigatorKey,
      home: const SplashScreen(),
    );
  }
}

/// Sends the person back to the login screen, with the given message shown
/// once they arrive. Used both for an explicit Log Out and for a session
/// that the server says has ended.
void _returnToLoginScreen(BuildContext context, {String? message}) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (context) => const LoginScreen()),
    (route) => false,
  );
  if (message != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The title shown on the top bar of both apps: the badge and the one line
/// "Graceland Guest House — Manager Portal" (or "Receptionist Portal"), all
/// in one font and one size. The line shrinks to fit a narrow screen and is
/// never cut off or wrapped; on a wide screen it keeps its normal size.
class _PortalTitle extends StatelessWidget {
  final String portalName;

  const _PortalTitle({required this.portalName});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Image.asset('lib/branding/graceland_monogram.png', width: 32, height: 32, filterQuality: FilterQuality.high),
        const SizedBox(width: 10),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              "Graceland Guest House — $portalName",
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.0),
            ),
          ),
        ),
      ],
    );
  }
}

/// The exchange rate shown on the top bar. It shrinks to fit when the bar is
/// crowded, so it never pushes the Log Out button off a small screen.
class _RateText extends StatelessWidget {
  final double rate;

  const _RateText({required this.rate});

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        "1 USD = ${rate.toStringAsFixed(2)} GHS",
        maxLines: 1,
        style: const TextStyle(fontSize: 12, fontFamily: 'Courier', fontWeight: FontWeight.bold, color: kDeepNavy),
      ),
    );
  }
}

/// The exchange rate with, optionally, a small icon showing whether the
/// server can be reached. On a narrow screen it sits on a line of its own
/// under the title instead of crowding the top bar.
class _RateBadge extends StatelessWidget {
  final double rate;

  /// Null leaves the connection icon out.
  final bool? isOnline;

  const _RateBadge({required this.rate, this.isOnline});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: kDeepNavy.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kDeepNavy.withValues(alpha: 0.55), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isOnline != null) ...[
            Icon(
              isOnline! ? Icons.g_translate : Icons.cloud_off,
              size: 14,
              // Deep green when connected, deep red when not: both chosen to stay readable on gold
              color: isOnline! ? const Color(0xff0c5c34) : const Color(0xff8c1d12),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(child: _RateText(rate: rate)),
        ],
      ),
    );
  }
}

/// This block builds the structural framework shell that holds the top header
/// banner, the adaptive side menu, and the central focus view window.
class MainNavigationShell extends StatefulWidget {
  /// Holds the active network communication engine instance passed from the login screen.
  final ApiService apiService;

  // Receives the required network engine instance during initialization
  const MainNavigationShell({super.key, required this.apiService});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  /// Tracks the currently active menu selection index number. Order:
  /// 0 Dashboard (which also holds the shift bar), 1 Daily Costs,
  /// 2 Business Summary, 3 Records, then the less-used group: 4 Employees,
  /// 5 Rooms, 6 Change Login.
  late int _activeManagerTabIndex;

  /// Controls whether the side menu displays full text labels or clean icons only.
  bool _isSidebarCollapsed = false;

  /// Changed every time a shift closes, so Business Summary is rebuilt
  /// fresh (opening back on "Daily") rather than keeping whatever period
  /// the manager had it on before.
  Key _businessSummaryKey = UniqueKey();

  @override
  void initState() {
    // Runs the standard system setup routine first
    super.initState();
    // A session that has expired or been removed sends the person back to
    // the login screen from wherever they are in the app.
    widget.apiService.onSessionEnded = (message) {
      if (mounted) _returnToLoginScreen(context, message: message);
    };
    // Checks for a live internet connection to sync currency metrics right away
    _syncLiveExchangeRate();
    _activeManagerTabIndex = 0;
  }

  /// Refreshes the system by fetching active exchange rates over the network.
  Future<void> _syncLiveExchangeRate() async {
    // Orders the shared network engine to run its background banking check
    await widget.apiService.syncSharedExchangeRate();
    // Refreshes the on-screen display widgets once the data responds
    if (mounted) {
      // Tells the user interface to redraw itself with the new numbers
      setState(() {});
    }
  }

  /// Called when the Dashboard's shift bar confirms a shift has
  /// actually closed (not merely queued offline). Jumps across to Business Summary, freshly
  /// reset to show "Daily", rather than leaving the manager to find it
  /// themselves.
  void _jumpToBusinessSummaryAfterClose() {
    if (!mounted) return;
    setState(() {
      _activeManagerTabIndex = 2; // Business Summary
      _businessSummaryKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Measures the current physical width of the terminal display screen
    final double screenWidth = MediaQuery.of(context).size.width;
    // Determines if the app is running on a larger monitor or administrative tablet
    final bool isTabletOrDesktop = screenWidth > 768;
    // On a narrow screen (a phone) the exchange rate moves under the title.
    final bool isNarrow = screenWidth < 600;

    // Builds the primary structural layout frame for the active workplace
    return Scaffold(
      // On a narrow screen (a phone) the menu opens from the top bar's menu
      // button; on a wide screen it stays open down the left side.
      drawer: isTabletOrDesktop
          ? null
          : Drawer(
              backgroundColor: const Color(0xff111f3a),
              child: SafeArea(child: ListView(children: _buildNavigationMenuItems(closeDrawerOnTap: true))),
            ),
      // Configures the fixed administrative top banner bar across the screen
      appBar: AppBar(
        // The badge and the one-line title (see _PortalTitle). The monogram
        // is recognizable even this small, unlike the ring of text around
        // the full badge, which the login and launch screens use.
        title: const _PortalTitle(portalName: "Manager Portal"),
        // On a narrow screen the rate has a line of its own under the title.
        bottom: isNarrow
            ? PreferredSize(
                preferredSize: const Size.fromHeight(34),
                child: SizedBox(
                  height: 34,
                  child: Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 6),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _RateBadge(rate: widget.apiService.activeExchangeRate, isOnline: widget.apiService.isSystemOnline),
                  ),
                  ),
                ),
              )
            : null,
        // Arranges informational status indicators on the right side of the header
        actions: [
          // Shows anything still waiting to be sent to the server, or
          // anything the server rejected and needs a person's review.
          const SyncStatusIndicator(),
          // The exchange rate in a small capsule, with an icon showing whether
          // the server can be reached. On a narrow screen it moves to a line
          // under the title (see the bar's bottom).
          if (!isNarrow)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: _RateBadge(rate: widget.apiService.activeExchangeRate, isOnline: widget.apiService.isSystemOnline),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Log Out",
            onPressed: () {
              widget.apiService.logOut();
              _returnToLoginScreen(context);
            },
          ),
        ],
      ),
      // Integrates a horizontal layout split separating the menu and workspace
      body: Row(
        children: [
          // Only draws the side tracking drawer panel if the screen is wide enough
          if (isTabletOrDesktop)
            // Creates a smoothly animating width box to open and close the menu
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _isSidebarCollapsed ? 72 : 240,
              // The navy is painted by a Material, not by the container's
              // own colour. A coloured box sitting between the menu rows
              // (ListTiles) and their Material is exactly what made Flutter
              // print "ListTile background color or ink splashes may be
              // invisible" in the console; with the colour on the Material
              // itself the rows draw and ripple properly, so the warning
              // does not appear.
              child: Material(
                color: const Color(0xff111f3a),
                child: Column(
                children: [
                  // Toggles the collapse true/false state value when clicked
                  IconButton(
                    icon: Icon(_isSidebarCollapsed ? Icons.chevron_right : Icons.chevron_left),
                    onPressed: () => setState(() => _isSidebarCollapsed = !_isSidebarCollapsed),
                  ),
                  // Draws a crisp, thin partition divider line across the list column
                  const Divider(height: 1),
                  // Expands the remaining vertical space to fit all selection triggers
                  Expanded(
                    // Implements a clean scrolling column container tracking active buttons
                    child: ListView(
                      // Feeds our array generation code block to construct list tiles
                      children: _buildNavigationMenuItems(),
                    ),
                  ),
                ],
              ),
              ),
            ),
          // Allocates all remaining viewport space to show the active work screen
          Expanded(
            // Wraps the inner working canvas frame with padding boundaries
            child: Container(
              // Injects uniform structural grid cushioning padding on all sides
              padding: EdgeInsets.all(isTabletOrDesktop ? 24.0 : 12.0),
              // Injects the function that draws the chosen management workspace widget
              child: _renderActiveManagerView(),
            ),
          ),
        ],
      ),
    );
  }

  /// Generates the menu item row elements, in the agreed order: the four
  /// daily-use screens first, then a divider, then the three rarely-used
  /// setup screens grouped together at the bottom.
  List<Widget> _buildNavigationMenuItems({bool closeDrawerOnTap = false}) {
    final List<Map<String, dynamic>> menuItems = [
      {"title": "Dashboard", "icon": Icons.dashboard},
      {"title": "Daily Costs", "icon": Icons.monetization_on},
      {"title": "Business Summary", "icon": Icons.bar_chart},
      {"title": "Records", "icon": Icons.fact_check},
      {"title": "Employees", "icon": Icons.badge, "dividerBefore": true},
      {"title": "Rooms", "icon": Icons.bed},
      {"title": "Change Login", "icon": Icons.lock_reset},
    ];

    final List<Widget> tiles = [];
    for (int index = 0; index < menuItems.length; index++) {
      final item = menuItems[index];
      final bool isSelected = _activeManagerTabIndex == index;

      if (item["dividerBefore"] == true) {
        tiles.add(const Divider(height: 16));
      }

      tiles.add(ListTile(
        selected: isSelected,
        selectedTileColor: Colors.black12,
        leading: Icon(item["icon"], color: isSelected ? const Color(0xffd4af37) : Colors.white70),
        title: (_isSidebarCollapsed && !closeDrawerOnTap) ? null : Text(item["title"]),
        onTap: () {
          if (closeDrawerOnTap) Navigator.of(context).pop();
          setState(() => _activeManagerTabIndex = index);
        },
      ));
    }
    return tiles;
  }

  /// Mounts and runs the active workspace view for the current tab index,
  /// in the same order as the menu above.
  Widget _renderActiveManagerView() {
    switch (_activeManagerTabIndex) {
      case 0:
        return DashboardView(
          apiService: widget.apiService,
          onShiftClosed: _jumpToBusinessSummaryAfterClose,
        );

      case 1:
        return DailyCostsView(apiService: widget.apiService);

      case 2:
        return BusinessSummaryView(key: _businessSummaryKey, apiService: widget.apiService);

      case 3:
        return RecordsView(apiService: widget.apiService);

      case 4:
        return EmployeeManagementView(apiService: widget.apiService);

      case 5:
        return RoomManagementView(apiService: widget.apiService);

      case 6:
        return ChangeLoginView(apiService: widget.apiService);

      default:
        return const Center(
          child: Text(
            "Error: Operational Interface Workspace Disconnect.",
            style: TextStyle(color: Color(0xffe0584a), fontWeight: FontWeight.bold),
          ),
        );
    }
  }
}

/// The receptionist's home screen after logging in. Keeps things simple:
/// just the live room grid and the shop sale screen, nothing else.
class ReceptionistNavigationShell extends StatefulWidget {
  final ApiService apiService;

  const ReceptionistNavigationShell({super.key, required this.apiService});

  @override
  State<ReceptionistNavigationShell> createState() => _ReceptionistNavigationShellState();
}

class _ReceptionistNavigationShellState extends State<ReceptionistNavigationShell> {
  int _activeTabIndex = 0;

  // Asks the server every so often whether an official shift is open, so the
  // "Buffer period" banner below is right on either tab.
  Timer? _shiftCheckTimer;

  @override
  void initState() {
    super.initState();
    widget.apiService.onSessionEnded = (message) {
      if (mounted) _returnToLoginScreen(context, message: message);
    };
    _syncLiveExchangeRate();
    _refreshShiftFlag();
    widget.apiService.refreshShiftActivity();
    _shiftCheckTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _refreshShiftFlag();
      // Keeps the bookings / sales boxes current, including work done by
      // another person on another device. Doing something on THIS tablet
      // updates them at once on its own.
      widget.apiService.refreshShiftActivity();
    });
  }

  @override
  void dispose() {
    _shiftCheckTimer?.cancel();
    super.dispose();
  }

  /// Reading the live feed also updates apiService.officialShiftActive. If
  /// the server cannot be reached the last known answer simply stays.
  Future<void> _refreshShiftFlag() async {
    try {
      await widget.apiService.fetchLiveOperationalSummary();
    } catch (_) {}
  }

  Future<void> _syncLiveExchangeRate() async {
    await widget.apiService.syncSharedExchangeRate();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Both screens stay built, with only one shown, so the room countdowns
    // and their Time's Up warnings keep running while the Shop Sale tab is
    // open.
    // On a narrow screen (a phone) the exchange rate moves under the title.
    final bool isNarrow = MediaQuery.of(context).size.width < 600;

    final Widget activeScreen = IndexedStack(
      index: _activeTabIndex,
      children: [
        RoomMatrixGrid(apiService: widget.apiService),
        CounterShopPos(apiService: widget.apiService),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const _PortalTitle(portalName: "Receptionist Portal"),
        bottom: isNarrow
            ? PreferredSize(
                preferredSize: const Size.fromHeight(34),
                child: SizedBox(
                  height: 34,
                  child: Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 6),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _RateBadge(rate: widget.apiService.activeExchangeRate),
                  ),
                  ),
                ),
              )
            : null,
        actions: [
          const SyncStatusIndicator(),
          if (!isNarrow)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: _RateBadge(rate: widget.apiService.activeExchangeRate),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Log Out",
            onPressed: () {
              widget.apiService.logOut();
              _returnToLoginScreen(context);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // BUFFER PERIOD BANNER. While no official shift is open, the
          // server has automatically switched to the buffer shift. Anything
          // booked or sold now is credited to whoever is logged in on this
          // tablet, so the banner says plainly who that is. If it is the
          // wrong person, they log out and the right one logs in.
          ValueListenableBuilder<bool?>(
            valueListenable: widget.apiService.officialShiftActive,
            builder: (context, isActive, _) {
              if (isActive != false) return const SizedBox.shrink();
              final String name = canonicalName(widget.apiService.currentUsername ?? "", keepAbbreviations: false);
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: StatusColors.softBlack,
                child: Row(
                  children: [
                    const Icon(Icons.schedule, size: 16, color: kTopBarGold),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Buffer period — no official shift is open. Bookings and sales are credited to $name.",
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // This shift's bookings and shop sales as two small chips at the
          // left, each opening a short list (no names).
          ShiftActivityBar(apiService: widget.apiService),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: activeScreen,
            ),
          ),
        ],
      ),
      // A simple bottom bar is enough for two destinations, and keeps the
      // front desk interface plain and quick to learn.
      bottomNavigationBar: NavigationBar(
        selectedIndex: _activeTabIndex,
        onDestinationSelected: (index) => setState(() => _activeTabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bed), label: "Rooms"),
          NavigationDestination(icon: Icon(Icons.point_of_sale), label: "Shop Sale"),
        ],
      ),
    );
  }
}
