import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';

// Shared name capitalization and password-visibility helpers
import '../../widgets/capitalize_words_formatter.dart';
import '../../widgets/password_field.dart';

/// Models an employee record as it actually exists on the server. The id
/// is always the real numeric identifier assigned by the database.
class EmployeeRecord {
  final int id;
  final String fullName;
  final String role;
  final double monthlySalary;
  final String? photoUrl;

  EmployeeRecord({
    required this.id,
    required this.fullName,
    required this.role,
    required this.monthlySalary,
    this.photoUrl,
  });

  factory EmployeeRecord.fromJson(Map<String, dynamic> json) {
    return EmployeeRecord(
      id: json['id'],
      fullName: json['employee_name'],
      role: json['role'],
      monthlySalary: (json['monthly_salary'] as num).toDouble(),
      photoUrl: json['photo_url'],
    );
  }
}

/// Manages employee records, salaries, logins, and passport photos. The
/// staff list always reflects what is actually stored on the server.
/// Every write action here still works even if the router is briefly
/// down — it is saved and synced automatically once the connection
/// returns. "Money brought in" is in the Records tab, under Staff
/// Earnings.
class EmployeeManagementView extends StatefulWidget {
  final ApiService apiService;

  const EmployeeManagementView({super.key, required this.apiService});

  @override
  State<EmployeeManagementView> createState() => _EmployeeManagementViewState();
}

class _EmployeeManagementViewState extends State<EmployeeManagementView> {
  final _formKey = GlobalKey<FormState>();
  final _editFormKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _salaryController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _editSalaryController = TextEditingController();
  final TextEditingController _editUsernameController = TextEditingController();
  final TextEditingController _editPasswordController = TextEditingController();

  String _selectedRole = "Receptionist";
  String _editSelectedRole = "Receptionist";
  Uint8List? _capturedPhotoBytes;
  bool _isProcessingNetworkCall = false;
  bool _isUploadingEditPhoto = false;
  String? _editPhotoUrl;

  bool _isLoadingStaff = true;
  String? _loadErrorMessage;
  List<EmployeeRecord> _staffRoster = [];

  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadStaffFromServer();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _salaryController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _editSalaryController.dispose();
    _editUsernameController.dispose();
    _editPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadStaffFromServer() async {
    setState(() {
      _isLoadingStaff = true;
      _loadErrorMessage = null;
    });

    try {
      final rawStaff = await widget.apiService.fetchAllEmployees();
      final staff = rawStaff.map((e) => EmployeeRecord.fromJson(e)).toList();
      staff.sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));

      setState(() {
        _staffRoster = staff;
        _isLoadingStaff = false;
      });
    } catch (e) {
      setState(() {
        _loadErrorMessage = e.toString().replaceAll("Exception: ", "");
        _isLoadingStaff = false;
      });
    }
  }

  /// Shows the right confirmation depending on whether the action reached
  /// the server immediately or was saved offline to sync automatically.
  void _showActionResultSnackBar(Map<String, dynamic> result, String onlineMessage) {
    if (!mounted) return;
    final bool wasQueuedOffline = result['queued_offline'] == true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: wasQueuedOffline ? const Color(0xffc9971f) : const Color(0xff14703f),
        content: Text(wasQueuedOffline ? "Saved. Pending, will be sent when the connection returns." : onlineMessage),
      ),
    );
  }

  /// Lets the manager pick a passport photo from the device's own photo
  /// library and frame it. A camera capture option isn't offered: this app
  /// runs on front-desk hardware where staff are uploading an existing
  /// photo rather than taking one on the spot. The picture is first
  /// brought down to a sensible size, then shown in a framing screen where
  /// it can be moved and zoomed inside a circle. What comes back is a new,
  /// square picture containing exactly what was framed, or null when the
  /// manager cancels.
  Future<Uint8List?> _pickAndFramePhoto() async {
    try {
      final XFile? pickedImage = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (pickedImage == null) return null;

      final Uint8List original = await pickedImage.readAsBytes();
      if (!mounted) return null;
      return await showDialog<Uint8List>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _PhotoFramingDialog(imageBytes: original),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not access the photo library: ${e.toString()}")),
        );
      }
      return null;
    }
  }

  Future<void> _capturePhotoForNewEmployee(StateSetter setDialogState) async {
    final Uint8List? framed = await _pickAndFramePhoto();
    if (framed == null) return;
    setDialogState(() => _capturedPhotoBytes = framed);
  }

  /// Frames and uploads a new passport photo for an employee who already
  /// exists (has a real id), from inside the Edit dialog. Uploaded right
  /// away rather than waiting for "Save Changes", since the photo has
  /// nothing to do with the role/salary fields also on this dialog and a
  /// real employee id is already available to attach it to.
  Future<void> _capturePhotoForExistingEmployee(EmployeeRecord staff, StateSetter setDialogState) async {
    final Uint8List? framed = await _pickAndFramePhoto();
    if (framed == null) return;

    try {
      setDialogState(() => _isUploadingEditPhoto = true);

      final result = await widget.apiService.uploadEmployeePhoto(
        employeeId: staff.id,
        photoBytes: framed,
        fileName: "photo.png",
      );

      setDialogState(() {
        _isUploadingEditPhoto = false;
        _editPhotoUrl = result['photo_url'] as String?;
      });
      await _loadStaffFromServer();
    } catch (e) {
      if (mounted) {
        setDialogState(() => _isUploadingEditPhoto = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not upload the photo right now: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    }
  }

  /// The round photo slot shown in the Add and Edit dialogs. Shows either
  /// a freshly framed picture ([bytes]) or the saved one ([url]).
  Widget _photoSlot({
    required Uint8List? bytes,
    required String? url,
    required bool busy,
    required VoidCallback? onTap,
  }) {
    const double size = 140;
    final bool hasPhoto = bytes != null || url != null;

    Widget content;
    if (busy) {
      content = const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)));
    } else if (bytes != null) {
      content = Image.memory(bytes, fit: BoxFit.cover, width: size, height: size);
    } else if (url != null) {
      content = Image.network(
        "${ApiService.baseUrl}$url",
        fit: BoxFit.cover,
        width: size,
        height: size,
        errorBuilder: (context, error, stackTrace) => const Icon(Icons.person, size: 64, color: Colors.white38),
      );
    } else {
      content = const Icon(Icons.add_a_photo, color: Color(0xffd4af37), size: 36);
    }

    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black26,
              border: Border.all(
                color: bytes != null ? const Color(0xff1e9e5a) : const Color(0xffd4af37),
                width: 1,
              ),
            ),
            child: ClipOval(child: content),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          hasPhoto ? "Tap to change the photo" : "Tap to add a passport photo",
          style: const TextStyle(fontSize: 12, color: Colors.white54),
        ),
      ],
    );
  }

  /// The salary check shared by Add and Edit, so the same amount is accepted
  /// or refused in both: a plain number, zero or more.
  String? _validateSalary(String? value) {
    if (value == null || value.trim().isEmpty) return "Salary is required";
    final double? amount = double.tryParse(value.trim());
    if (amount == null || amount < 0) return "Enter a valid amount";
    return null;
  }

  void _showAddEmployeeDialog() {
    _nameController.clear();
    _salaryController.clear();
    _usernameController.clear();
    _passwordController.clear();
    _selectedRole = "Receptionist";
    _capturedPhotoBytes = null;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final bool isReceptionist = _selectedRole == "Receptionist";
            return AlertDialog(
              title: const Text("Add New Employee"),
              content: SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                        // A person's name: each word capitalised, KOFI becomes Kofi.
                        inputFormatters: [CapitalizeWordsFormatter(keepAbbreviations: false)],
                        decoration: const InputDecoration(labelText: "Full Name", border: OutlineInputBorder()),
                        validator: (val) => val == null || val.isEmpty ? "Name is required" : null,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _selectedRole,
                        decoration: const InputDecoration(labelText: "Role", border: OutlineInputBorder()),
                        items: ["Receptionist", "Manager", "Cleaner", "Security"]
                            .map((role) => DropdownMenuItem(value: role, child: Text(role)))
                            .toList(),
                        onChanged: (val) => setDialogState(() => _selectedRole = val!),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _salaryController,
                        keyboardType: TextInputType.number,
                        // Salary is the last field unless a login is being created
                        // too; if it is the last, Enter saves the employee.
                        textInputAction: isReceptionist ? TextInputAction.next : TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (isReceptionist) {
                            FocusScope.of(context).nextFocus();
                          } else if (!_isProcessingNetworkCall) {
                            _handleOnboardStaff();
                          }
                        },
                        decoration: const InputDecoration(labelText: "Monthly Salary (GHS)", border: OutlineInputBorder(), prefixText: "₵ "),
                        validator: _validateSalary,
                      ),

                      // A Receptionist gets a login created right here, at
                      // the same time as their staff record — this is what
                      // makes Staff Earnings possible per person.
                      if (isReceptionist) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _usernameController,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                          decoration: const InputDecoration(labelText: "Login Username", border: OutlineInputBorder()),
                          validator: (val) {
                            if (!isReceptionist) return null;
                            if (val == null || val.trim().length < 3) return "At least 3 characters";
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        PasswordField(
                          controller: _passwordController,
                          labelText: "Login Password",
                          textInputAction: TextInputAction.done,
                          // Last field: Enter saves the employee.
                          onFieldSubmitted: (_) {
                            if (!_isProcessingNetworkCall) _handleOnboardStaff();
                          },
                          validator: (val) {
                            if (!isReceptionist) return null;
                            if (val == null || val.length < 8) return "At least 8 characters";
                            return null;
                          },
                        ),
                      ],
                      const SizedBox(height: 16),

                      _photoSlot(
                        bytes: _capturedPhotoBytes,
                        url: null,
                        busy: false,
                        onTap: () => _capturePhotoForNewEmployee(setDialogState),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xff1e9e5a)),
                  onPressed: _isProcessingNetworkCall ? null : _handleOnboardStaff,
                  child: _isProcessingNetworkCall
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text("Save Employee", style: TextStyle(color: Colors.black)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showEditEmployeeDialog(EmployeeRecord staff) {
    _editSalaryController.text = staff.monthlySalary.toStringAsFixed(2);
    _editSelectedRole = staff.role;
    _editUsernameController.clear();
    _editPasswordController.clear();
    _isUploadingEditPhoto = false;
    _editPhotoUrl = staff.photoUrl;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Only relevant the moment this role change actually crosses
            // INTO Receptionist from something else — this is what the
            // server itself requires a fresh login for (see edit_existing_employee).
            final bool becomingReceptionist = _editSelectedRole == "Receptionist" && staff.role != "Receptionist";
            final bool leavingReceptionist = staff.role == "Receptionist" && _editSelectedRole != "Receptionist";

            return AlertDialog(
              title: const Text("Edit Employee"),
              content: SingleChildScrollView(
                child: Form(
                  key: _editFormKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        initialValue: staff.fullName,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: "Full Name (locked)",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _editSelectedRole,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: "Role", border: OutlineInputBorder()),
                        items: ["Receptionist", "Manager", "Cleaner", "Security"]
                            .map((role) => DropdownMenuItem(value: role, child: Text(role)))
                            .toList(),
                        onChanged: (val) => setDialogState(() => _editSelectedRole = val!),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _editSalaryController,
                        keyboardType: TextInputType.number,
                        // Last field unless a new login is being created; then Enter saves.
                        textInputAction: becomingReceptionist ? TextInputAction.next : TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (becomingReceptionist) {
                            FocusScope.of(context).nextFocus();
                          } else if (!_isProcessingNetworkCall) {
                            _handleEditStaff(staff, becomingReceptionist: becomingReceptionist);
                          }
                        },
                        decoration: const InputDecoration(labelText: "Monthly Salary (GHS)", border: OutlineInputBorder(), prefixText: "₵ "),
                        validator: _validateSalary,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "Changing the salary starts a fresh payroll record from today; "
                        "everything already paid stays exactly as it was.",
                        style: TextStyle(fontSize: 11, color: Colors.white54, fontStyle: FontStyle.italic),
                      ),

                      if (leavingReceptionist) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(6)),
                          child: const Text(
                            "Their front-desk login will be closed immediately and cannot be used again until they are made a receptionist again.",
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ),
                      ],

                      // Moving TO Receptionist always needs a fresh
                      // username and password right here — the server
                      // either creates a brand-new login or reactivates
                      // this same person's own retired one, but either
                      // way it needs these two fields to do it.
                      if (becomingReceptionist) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _editUsernameController,
                          textInputAction: TextInputAction.next,
                          onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                          decoration: const InputDecoration(labelText: "Login Username", border: OutlineInputBorder()),
                          validator: (val) {
                            if (!becomingReceptionist) return null;
                            if (val == null || val.trim().length < 3) return "At least 3 characters";
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        PasswordField(
                          controller: _editPasswordController,
                          labelText: "Login Password",
                          textInputAction: TextInputAction.done,
                          // Last field: Enter saves the changes.
                          onFieldSubmitted: (_) {
                            if (!_isProcessingNetworkCall) _handleEditStaff(staff, becomingReceptionist: becomingReceptionist);
                          },
                          validator: (val) {
                            if (!becomingReceptionist) return null;
                            if (val == null || val.length < 8) return "At least 8 characters";
                            return null;
                          },
                        ),
                      ],

                      const SizedBox(height: 16),
                      _photoSlot(
                        bytes: null,
                        url: _editPhotoUrl,
                        busy: _isUploadingEditPhoto,
                        onTap: _isUploadingEditPhoto ? null : () => _capturePhotoForExistingEmployee(staff, setDialogState),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xff1e9e5a)),
                  onPressed: _isProcessingNetworkCall ? null : () => _handleEditStaff(staff, becomingReceptionist: becomingReceptionist),
                  child: _isProcessingNetworkCall
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text("Save Changes", style: TextStyle(color: Colors.black)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Employee Management",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
            ),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffd4af37), foregroundColor: Colors.black),
                  icon: const Icon(Icons.add),
                  label: const Text("Add Employee", style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _showAddEmployeeDialog,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        Expanded(child: _buildStaffList()),
      ],
    );
  }

  Widget _buildStaffList() {
    if (_isLoadingStaff) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)));
    }

    if (_loadErrorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Could not load staff: $_loadErrorMessage",
              style: const TextStyle(color: Color(0xffe0584a)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadStaffFromServer, child: const Text("Try Again")),
          ],
        ),
      );
    }

    if (_staffRoster.isEmpty) {
      return const Center(
        child: Text("No employees have been onboarded yet.", style: TextStyle(color: Colors.white54)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadStaffFromServer,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _staffRoster.length,
        itemBuilder: (context, index) {
          final staff = _staffRoster[index];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: const Color(0xff111f3a),
            child: ListTile(
              onTap: () => _showProfileCard(staff),
              leading: CircleAvatar(
                backgroundColor: const Color(0xff2d2d2d),
                foregroundColor: const Color(0xffd4af37),
                backgroundImage: staff.photoUrl != null ? NetworkImage("${ApiService.baseUrl}${staff.photoUrl}") : null,
                onBackgroundImageError: staff.photoUrl != null ? (error, stackTrace) {} : null,
                child: staff.photoUrl == null ? const Icon(Icons.person) : null,
              ),
              title: Text(staff.fullName, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text("Role: ${staff.role}  |  Salary: ₵ ${staff.monthlySalary.toStringAsFixed(2)}"),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
                    onPressed: () => _showEditEmployeeDialog(staff),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Color(0xffc0392b), size: 20),
                    onPressed: () => _handleDeleteStaff(staff),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Adds up one list of server amounts (bookings, extensions or shop
  /// sales) into a single figure.
  double _sumAmounts(dynamic entries) {
    double total = 0;
    for (final entry in List<Map<String, dynamic>>.from(entries ?? [])) {
      total += (entry['amount'] as num?)?.toDouble() ?? 0.0;
    }
    return total;
  }

  String _cedis(double amount) => "₵ ${amount.toStringAsFixed(2)}";

  /// A pop-up over the list showing one employee: a large photo, the name,
  /// role and salary and, for a receptionist, a short overview of the money
  /// brought in since they started. The figures come from the same
  /// server records as the Records tab and are added up here. Tapping
  /// outside the card or pressing Close dismisses it.
  void _showProfileCard(EmployeeRecord staff) {
    final bool takesPayments = staff.role == "Receptionist";
    final String today = DateTime.now().toIso8601String().split('T').first;
    final Future<Map<String, dynamic>>? figuresFuture = takesPayments
        ? widget.apiService.fetchMoneyBroughtIn(employeeId: staff.id, startDate: "2020-01-01", endDate: today)
        : null;

    Widget bigPhoto() {
      final Widget placeholder = Container(
        color: const Color(0xff2d2d2d),
        child: const Center(child: Icon(Icons.person, size: 110, color: Color(0xffd4af37))),
      );
      if (staff.photoUrl == null) return placeholder;
      return Image.network(
        "${ApiService.baseUrl}${staff.photoUrl}",
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
    }

    Widget figureRow(String label, double amount, {bool highlighted = false}) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: highlighted ? const Color(0xff14703f) : Colors.black26,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontWeight: highlighted ? FontWeight.bold : FontWeight.normal, color: Colors.white)),
            Text(_cedis(amount), style: TextStyle(fontWeight: highlighted ? FontWeight.bold : FontWeight.normal, color: Colors.white)),
          ],
        ),
      );
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xff111f3a),
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(aspectRatio: 1, child: bigPhoto()),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(staff.fullName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xffd4af37))),
                        const SizedBox(height: 4),
                        Text(staff.role, style: const TextStyle(fontSize: 15, color: Colors.white70)),
                        const SizedBox(height: 2),
                        Text("Salary: ${_cedis(staff.monthlySalary)}", style: const TextStyle(fontSize: 15, color: Colors.white70)),
                        if (figuresFuture != null) ...[
                          const SizedBox(height: 16),
                          const Text("Money Brought In", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
                          FutureBuilder<Map<String, dynamic>>(
                            future: figuresFuture,
                            builder: (context, snapshot) {
                              if (snapshot.connectionState == ConnectionState.waiting) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)))),
                                );
                              }
                              if (snapshot.hasError || snapshot.data == null) {
                                return const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Text("Could not load the figures right now.", style: TextStyle(color: Color(0xffe0584a), fontSize: 13)),
                                );
                              }
                              final data = snapshot.data!;
                              // An extension counts as a booking.
                              final double bookings = _sumAmounts(data['bookings']) + _sumAmounts(data['extensions']);
                              final double sales = _sumAmounts(data['shop_sales']);
                              return Column(
                                children: [
                                  figureRow("Total", bookings + sales, highlighted: true),
                                  figureRow("Bookings", bookings),
                                  figureRow("Shop Sales", sales),
                                ],
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Close"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleOnboardStaff() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isProcessingNetworkCall = true);

    try {
      final bool isReceptionist = _selectedRole == "Receptionist";
      final result = await widget.apiService.addEmployee(
        employeeName: canonicalName(_nameController.text, keepAbbreviations: false),
        role: _selectedRole,
        monthlySalary: double.parse(_salaryController.text),
        username: isReceptionist ? _usernameController.text.trim() : null,
        password: isReceptionist ? _passwordController.text : null,
      );

      // The photo is only uploaded if the employee record reached the
      // server right away and returned a real ID. If this action was
      // queued offline instead, the photo cannot be attached yet — the
      // manager can add it once the employee record has actually synced.
      final int? newEmployeeId = result['id'];
      if (_capturedPhotoBytes != null && newEmployeeId != null) {
        try {
          await widget.apiService.uploadEmployeePhoto(
            employeeId: newEmployeeId,
            photoBytes: _capturedPhotoBytes!,
            fileName: "photo.png",
          );
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Employee saved, but the photo could not be uploaded right now.")),
            );
          }
        }
      }

      if (mounted) {
        Navigator.pop(context);
        _showActionResultSnackBar(result, "Employee onboarded.");
      }
      await _loadStaffFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Onboarding failed: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingNetworkCall = false);
    }
  }

  Future<void> _handleEditStaff(EmployeeRecord staff, {required bool becomingReceptionist}) async {
    if (!_editFormKey.currentState!.validate()) return;
    setState(() => _isProcessingNetworkCall = true);

    try {
      final result = await widget.apiService.editEmployee(
        employeeId: staff.id,
        role: _editSelectedRole,
        monthlySalary: double.parse(_editSalaryController.text),
        username: becomingReceptionist ? _editUsernameController.text.trim() : null,
        password: becomingReceptionist ? _editPasswordController.text : null,
      );
      if (mounted) {
        Navigator.pop(context);
        _showActionResultSnackBar(result, "Employee updated.");
      }
      await _loadStaffFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Employee could not be updated: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingNetworkCall = false);
    }
  }

  Future<void> _handleDeleteStaff(EmployeeRecord staff) async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Remove Employee"),
            content: Text(
              "Remove ${staff.fullName}? ${staff.role == "Receptionist" ? "Their login will stop working immediately. " : ""}"
              "Their past records stay on file.",
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffc0392b)),
                onPressed: () => Navigator.pop(context, true),
                child: const Text("Remove"),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    try {
      final result = await widget.apiService.deleteEmployee(employeeId: staff.id);
      _showActionResultSnackBar(result, "Employee removed.");
      await _loadStaffFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not remove employee: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    }
  }
}


/// The framing screen for a passport photo. The picture starts filling the
/// square (a portrait picture starts at the top so the head is in view, a
/// landscape picture starts centred). It can be dragged and pinched inside
/// the square, and the circle shows what the round photo will display.
/// Pressing "Use Photo" returns a new square picture holding exactly what
/// sits inside the frame.
class _PhotoFramingDialog extends StatefulWidget {
  final Uint8List imageBytes;

  const _PhotoFramingDialog({required this.imageBytes});

  @override
  State<_PhotoFramingDialog> createState() => _PhotoFramingDialogState();
}

class _PhotoFramingDialogState extends State<_PhotoFramingDialog> {
  static const double _side = 280;
  static const int _outputPixels = 500;

  final GlobalKey _frameKey = GlobalKey();
  final TransformationController _transform = TransformationController();
  Size? _fittedSize;
  bool _loadFailed = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _measurePicture();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// Reads the picture's size and works out how large it must be drawn so
  /// that its shorter side exactly fills the square.
  Future<void> _measurePicture() async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(widget.imageBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final double width = frame.image.width.toDouble();
      final double height = frame.image.height.toDouble();
      frame.image.dispose();
      codec.dispose();

      final double scale = _side / (width < height ? width : height);
      final Size fitted = Size(width * scale, height * scale);
      if (!mounted) return;
      setState(() {
        _fittedSize = fitted;
        _transform.value = Matrix4.translationValues(-(fitted.width - _side) / 2, 0, 0);
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _useFramedPhoto() async {
    setState(() => _isSaving = true);
    try {
      final RenderRepaintBoundary boundary = _frameKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: _outputPixels / _side);
      final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw Exception("The framed picture was empty.");
      if (mounted) Navigator.pop(context, data.buffer.asUint8List());
    } catch (_) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not prepare the photo. Please try again.")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loadFailed) {
      body = const SizedBox(
        height: _side,
        child: Center(child: Text("This picture could not be opened.", textAlign: TextAlign.center)),
      );
    } else if (_fittedSize == null) {
      body = const SizedBox(
        height: _side,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37))),
      );
    } else {
      body = SizedBox(
        width: _side,
        height: _side,
        child: Stack(
          children: [
            RepaintBoundary(
              key: _frameKey,
              child: ColoredBox(
                color: Colors.black,
                child: SizedBox(
                  width: _side,
                  height: _side,
                  child: InteractiveViewer(
                    transformationController: _transform,
                    constrained: false,
                    minScale: 1,
                    maxScale: 6,
                    boundaryMargin: EdgeInsets.zero,
                    child: SizedBox(
                      width: _fittedSize!.width,
                      height: _fittedSize!.height,
                      child: Image.memory(widget.imageBytes, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                    ),
                  ),
                ),
              ),
            ),
            const IgnorePointer(
              child: CustomPaint(size: Size(_side, _side), painter: _CircleMaskPainter()),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: const Text("Position the Photo"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          body,
          const SizedBox(height: 12),
          const Text(
            "Drag to move and pinch to zoom. The circle is what will show.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _isSaving ? null : () => Navigator.pop(context), child: const Text("Cancel")),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xff1e9e5a)),
          onPressed: (_isSaving || _fittedSize == null) ? null : _useFramedPhoto,
          child: _isSaving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
              : const Text("Use Photo", style: TextStyle(color: Colors.black)),
        ),
      ],
    );
  }
}

/// Darkens everything outside the circle so the part of the picture that
/// will be shown stands out.
class _CircleMaskPainter extends CustomPainter {
  const _CircleMaskPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Path mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2));
    canvas.drawPath(mask, Paint()..color = const Color(0xAA000000));
    canvas.drawCircle(
      size.center(Offset.zero),
      size.width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xffd4af37),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
