import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';
import '../../widgets/capitalize_words_formatter.dart';

/// Models a physical room inventory entity configuration profile. The id
/// here is always the room's real identifier as stored on the server,
/// which for a room is the room's own name.
class RoomConfigRecord {
  final String id;
  final String roomName;
  final String description;

  RoomConfigRecord({
    required this.id,
    required this.roomName,
    required this.description,
  });

  factory RoomConfigRecord.fromJson(Map<String, dynamic> json) {
    return RoomConfigRecord(
      id: json['id'].toString(),
      roomName: json['room_name'],
      description: json['description'] ?? "",
    );
  }
}

/// One approved duration and price combination for a room, as stored on
/// the server. A booking, and any extension of a booking, can only ever
/// be made against one of these exact combinations.
class RoomPriceEntry {
  final int id;
  final int durationHours;
  final double price;

  RoomPriceEntry({required this.id, required this.durationHours, required this.price});

  factory RoomPriceEntry.fromJson(Map<String, dynamic> json) {
    return RoomPriceEntry(
      id: json['id'],
      durationHours: json['duration_hours'],
      price: (json['price'] as num).toDouble(),
    );
  }
}

/// Compares two room names so that numbered rooms sort in true numeric
/// order (Room 1, Room 2, Room 10) instead of alphabetical order.
int _compareRoomNamesNaturally(String left, String right) {
  final leftNumber = RegExp(r'\d+').firstMatch(left);
  final rightNumber = RegExp(r'\d+').firstMatch(right);

  if (leftNumber != null && rightNumber != null) {
    final leftValue = int.parse(leftNumber.group(0)!);
    final rightValue = int.parse(rightNumber.group(0)!);
    if (leftValue != rightValue) return leftValue.compareTo(rightValue);
  }

  return left.compareTo(right);
}

/// Manages interactive data controls to add, edit, and delete physical room
/// assets, and to manage each room's own approved list of duration and
/// price combinations. No booking, and no extension of a booking, can
/// ever succeed for a room until at least one price entry exists for it
/// here. Every write action here still works even if the router is
/// briefly down — it is saved and synced automatically once the
/// connection returns.
class RoomManagementView extends StatefulWidget {
  final ApiService apiService;

  const RoomManagementView({super.key, required this.apiService});

  @override
  State<RoomManagementView> createState() => _RoomManagementViewState();
}

class _RoomManagementViewState extends State<RoomManagementView> {
  final _formKey = GlobalKey<FormState>();
  final _editFormKey = GlobalKey<FormState>();
  final _pricingFormKey = GlobalKey<FormState>();
  final TextEditingController _roomNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _editDescriptionController = TextEditingController();
  final TextEditingController _pricingDurationController = TextEditingController();
  final TextEditingController _pricingPriceController = TextEditingController();

  bool _isProcessingNetworkCall = false;
  bool _isLoadingRooms = true;
  String? _loadErrorMessage;
  List<RoomConfigRecord> _roomInventory = [];

  @override
  void initState() {
    super.initState();
    _loadRoomsFromServer();
  }

  @override
  void dispose() {
    _roomNameController.dispose();
    _descriptionController.dispose();
    _editDescriptionController.dispose();
    _pricingDurationController.dispose();
    _pricingPriceController.dispose();
    super.dispose();
  }

  Future<void> _loadRoomsFromServer() async {
    setState(() {
      _isLoadingRooms = true;
      _loadErrorMessage = null;
    });

    try {
      final rawRooms = await widget.apiService.fetchAllRooms();
      final rooms = rawRooms.map((r) => RoomConfigRecord.fromJson(r)).toList();
      rooms.sort((a, b) => _compareRoomNamesNaturally(a.roomName, b.roomName));

      setState(() {
        _roomInventory = rooms;
        _isLoadingRooms = false;
      });
    } catch (e) {
      setState(() {
        _loadErrorMessage = e.toString().replaceAll("Exception: ", "");
        _isLoadingRooms = false;
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

  /// Sentinel value for the "add a new room type" dropdown entry, kept
  /// distinct from any real description a manager could type.
  static const String _addNewRoomTypeOption = "__ADD_NEW_ROOM_TYPE__";

  void _showAddRoomDialog() {
    _roomNameController.clear();
    _descriptionController.clear();

    // Every distinct description already in use, so a manager picks an
    // exact match instead of retyping it — retyping lets a single extra
    // space or a different capital letter split one room type into two
    // separate, unpriced groups.
    final List<String> existingDescriptions =
        _roomInventory.map((room) => room.description).toSet().toList()..sort();

    // Starts on an existing type when any rooms already exist, since that
    // is the far more common case; only defaults to "new type" when the
    // registry is empty and there is nothing yet to choose from.
    String selectedDescriptionOption =
        existingDescriptions.isNotEmpty ? existingDescriptions.first : _addNewRoomTypeOption;
    if (selectedDescriptionOption != _addNewRoomTypeOption) {
      _descriptionController.text = selectedDescriptionOption;
    }

    showDialog(
      context: context,
      builder: (context) {
        // A StatefulBuilder gives this dialog its own local state, so
        // switching between the dropdown and the "new type" text field
        // can redraw the dialog without touching the rest of the screen.
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final bool isTypingNewDescription = selectedDescriptionOption == _addNewRoomTypeOption;

            return AlertDialog(
              title: const Text("Add Room"),
              content: SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: _roomNameController,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        // Last field when an existing room type is picked from the
                        // list (Enter then adds the room); otherwise it hands on
                        // to the new type's description.
                        textInputAction: isTypingNewDescription ? TextInputAction.next : TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (isTypingNewDescription) {
                            FocusScope.of(context).nextFocus();
                          } else if (!_isProcessingNetworkCall) {
                            _handleCreateRoomAsset();
                          }
                        },
                        decoration: const InputDecoration(
                          labelText: "Room Number",
                          hintText: "e.g., 5",
                          prefixText: "Room ",
                          border: OutlineInputBorder(),
                        ),
                        validator: (val) => val == null || val.isEmpty ? "Room number is required" : null,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: selectedDescriptionOption,
                        decoration: const InputDecoration(
                          labelText: "Room Type / Description",
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          ...existingDescriptions.map(
                            (description) => DropdownMenuItem(value: description, child: Text(description)),
                          ),
                          const DropdownMenuItem(
                            value: _addNewRoomTypeOption,
                            child: Text("+ Add a new room type"),
                          ),
                        ],
                        onChanged: (value) {
                          setDialogState(() {
                            selectedDescriptionOption = value!;
                            // Picking an existing type fills the description
                            // straight from the dropdown, so it is always a
                            // byte-for-byte match with the rooms it should
                            // be grouped and priced alongside.
                            _descriptionController.text =
                                value == _addNewRoomTypeOption ? "" : value;
                          });
                        },
                        validator: (val) => val == null || val.isEmpty ? "Select or add a room type" : null,
                      ),
                      // Only shown once "+ Add a new room type" is picked,
                      // so a genuinely new type is still typed once, freely.
                      if (isTypingNewDescription) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _descriptionController,
                          // One line, so Enter can mean "done" (a second line
                          // is never needed for a room type's name).
                          maxLines: 1,
                          // The one name rule: "king room" and "KING ROOM" read
                          // "King Room"; TV, AC and the like stay as typed.
                          inputFormatters: [CapitalizeWordsFormatter()],
                          textInputAction: TextInputAction.done,
                          // Last field: Enter adds the room.
                          onFieldSubmitted: (_) {
                            if (!_isProcessingNetworkCall) _handleCreateRoomAsset();
                          },
                          decoration: const InputDecoration(
                            labelText: "New Room Type Description",
                            hintText: "e.g., King bed, courtyard view",
                            border: OutlineInputBorder(),
                          ),
                          validator: (val) =>
                              val == null || val.isEmpty ? "Description is required" : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xff1e9e5a)),
                  onPressed: _isProcessingNetworkCall ? null : _handleCreateRoomAsset,
                  child: _isProcessingNetworkCall
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text("Add Room", style: TextStyle(color: Colors.black)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showEditRoomDialog(RoomConfigRecord room) {
    // The same room-type list used when adding a room, so the description
    // can only ever be a type that already exists or one deliberately added
    // here as new. A description is never free typing.
    final List<String> existingDescriptions =
        _roomInventory.map((r) => r.description).toSet().toList()..sort();

    String selectedDescriptionOption = room.description;
    _editDescriptionController.text = room.description;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final bool isTypingNewDescription = selectedDescriptionOption == _addNewRoomTypeOption;
            final bool typeIsUnchanged = selectedDescriptionOption == room.description;

            // What saving will do to this room's prices, said before it
            // happens: prices belong to the room type.
            String? priceNote;
            if (isTypingNewDescription) {
              priceNote = "A new room type has no prices yet. This room's prices will be cleared, "
                  "and new prices must be set before it can be booked.";
            } else if (!typeIsUnchanged) {
              priceNote = "This room will use the prices of $selectedDescriptionOption. "
                  "Its current prices will be replaced.";
            }

            return AlertDialog(
              title: const Text("Edit Room"),
              content: SingleChildScrollView(
                child: Form(
                  key: _editFormKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        initialValue: room.roomName,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: "Room Name (locked)",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: selectedDescriptionOption,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: "Room Type / Description",
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          ...existingDescriptions.map(
                            (description) => DropdownMenuItem(value: description, child: Text(description)),
                          ),
                          const DropdownMenuItem(
                            value: _addNewRoomTypeOption,
                            child: Text("+ Add a new room type"),
                          ),
                        ],
                        onChanged: (value) {
                          setDialogState(() {
                            selectedDescriptionOption = value!;
                            // An existing type is filled straight from the
                            // list, so it matches the other rooms of that
                            // type exactly.
                            _editDescriptionController.text = value == _addNewRoomTypeOption ? "" : value;
                          });
                        },
                        validator: (val) => val == null || val.isEmpty ? "Select or add a room type" : null,
                      ),
                      if (isTypingNewDescription) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _editDescriptionController,
                          maxLines: 1,
                          // The one name rule, as on Add Room.
                          inputFormatters: [CapitalizeWordsFormatter()],
                          textInputAction: TextInputAction.done,
                          // Last field: Enter saves the change.
                          onFieldSubmitted: (_) {
                            if (!_isProcessingNetworkCall) _handleEditRoomAsset(room);
                          },
                          decoration: const InputDecoration(
                            labelText: "New Room Type Description",
                            hintText: "e.g., King bed, courtyard view",
                            border: OutlineInputBorder(),
                          ),
                          validator: (val) => val == null || val.trim().isEmpty ? "Description is required" : null,
                        ),
                      ],
                      if (priceNote != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x1ac9971f),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xffc9971f), width: 0.7),
                          ),
                          child: Text(priceNote, style: const TextStyle(fontSize: 12.5, color: Colors.white70, height: 1.35)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xff1e9e5a)),
                  onPressed: _isProcessingNetworkCall ? null : () => _handleEditRoomAsset(room),
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

  /// Applies whatever is currently in the Hours/Price fields as a new
  /// approved price for this room's description group, if — and only
  /// if — something has actually been typed into them. Shared by the
  /// "Apply to All Matching Rooms" button, the Price field's Enter key,
  /// and the dialog's own "Done" button, so all three ways of finishing
  /// this action behave identically.
  ///
  /// Fields left untouched are treated as "nothing to add here" rather
  /// than an error — this is what lets "Done" close the dialog quietly
  /// when someone only came in to delete a price, without needing an
  /// empty Hours/Price pair to be filled in first. Fields that DO have
  /// something typed in them still go through the normal validator, so a
  /// genuine typo is caught and shown rather than silently dropped.
  Future<void> _applyPricingIfFilled(RoomConfigRecord room, void Function(void Function()) setDialogState) async {
    final bool hasTypedDuration = _pricingDurationController.text.trim().isNotEmpty;
    final bool hasTypedPrice = _pricingPriceController.text.trim().isNotEmpty;
    if (!hasTypedDuration && !hasTypedPrice) return;

    if (!_pricingFormKey.currentState!.validate()) return;

    await _handleSetPricingForDescription(room.description);
    _pricingDurationController.clear();
    _pricingPriceController.clear();
    setDialogState(() {});
  }

  void _showManagePricingDialog(RoomConfigRecord room) {
    _pricingDurationController.clear();
    _pricingPriceController.clear();

    final matchingRooms = _roomInventory.where((r) => r.description == room.description).toList();
    final matchingRoomNames = matchingRooms.map((r) => r.roomName).join(", ");

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text("Pricing — ${room.description}"),
              content: SizedBox(
                width: double.maxFinite,
                child: FutureBuilder<List<RoomPriceEntry>>(
                  future: _fetchPricingForDescriptionGroup(matchingRooms),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37))),
                      );
                    }

                    if (snapshot.hasError) {
                      return Text(
                        "Could not load pricing: ${snapshot.error}",
                        style: const TextStyle(color: Color(0xffe0584a)),
                      );
                    }

                    final entries = snapshot.data ?? [];

                    return SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Applies to ${matchingRooms.length} room(s): $matchingRoomNames",
                            style: const TextStyle(fontSize: 12, color: Colors.white54, fontStyle: FontStyle.italic),
                          ),
                          const SizedBox(height: 12),
                          if (entries.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                "No approved prices set yet. These rooms cannot be booked until at least one is added.",
                                style: TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            )
                          else
                            ...entries.map((entry) => Material(
                                  type: MaterialType.transparency,
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text("${entry.durationHours} hours"),
                                    subtitle: Text("₵ ${entry.price.toStringAsFixed(2)}"),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.delete, color: Color(0xffc0392b), size: 20),
                                      onPressed: () async {
                                        await _handleRemovePricingForDescription(room.description, entry.durationHours);
                                        setDialogState(() {});
                                      },
                                    ),
                                  ),
                                )),
                          const Divider(height: 24),
                          const Text("Add New Price", style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 12),
                          Form(
                            key: _pricingFormKey,
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _pricingDurationController,
                                    keyboardType: TextInputType.number,
                                    textInputAction: TextInputAction.next,
                                    onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                                    decoration: const InputDecoration(labelText: "Hours", border: OutlineInputBorder()),
                                    validator: (val) {
                                      final parsed = int.tryParse(val ?? '');
                                      if (parsed == null || parsed < 1) return "Required";
                                      return null;
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextFormField(
                                    controller: _pricingPriceController,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    textInputAction: TextInputAction.done,
                                    // Pressing Enter here is the same as pressing "Apply to
                                    // All Matching Rooms" — the last field in this pair
                                    // should complete the action, not just close the
                                    // keyboard and leave what was typed sitting unsaved.
                                    onFieldSubmitted: (_) => _applyPricingIfFilled(room, setDialogState),
                                    decoration: const InputDecoration(labelText: "Price (GHS)", prefixText: "₵ ", border: OutlineInputBorder()),
                                    validator: (val) {
                                      final parsed = double.tryParse(val ?? '');
                                      if (parsed == null || parsed < 0) return "Required";
                                      return null;
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffd4af37), foregroundColor: Colors.black),
                              onPressed: () => _applyPricingIfFilled(room, setDialogState),
                              child: const Text("Apply to All Matching Rooms"),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              actions: [
                // Discards whatever is currently typed in the Hours/Price
                // fields and closes without saving it — the only way any
                // typed-but-not-yet-applied entry gets thrown away.
                TextButton(
                  onPressed: () {
                    _pricingDurationController.clear();
                    _pricingPriceController.clear();
                    Navigator.pop(context);
                  },
                  child: const Text("Cancel"),
                ),
                // Applies whatever is currently typed (if anything) the
                // same way "Apply to All Matching Rooms" does, then
                // closes — so finishing on this button never silently
                // discards a duration/price that was already filled in.
                ElevatedButton(
                  onPressed: () async {
                    await _applyPricingIfFilled(room, setDialogState);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text("Done"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<List<RoomPriceEntry>> _fetchPricingForDescriptionGroup(List<RoomConfigRecord> matchingRooms) async {
    final matchingRoomIds = matchingRooms.map((r) => r.id).toSet();
    final allPricing = await widget.apiService.fetchRoomPricing();

    final Map<int, RoomPriceEntry> representativeByDuration = {};
    for (final entry in allPricing) {
      if (!matchingRoomIds.contains(entry['room_id'])) continue;
      final parsedEntry = RoomPriceEntry.fromJson(entry);
      representativeByDuration.putIfAbsent(parsedEntry.durationHours, () => parsedEntry);
    }

    final entries = representativeByDuration.values.toList();
    entries.sort((a, b) => a.durationHours.compareTo(b.durationHours));
    return entries;
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
              "Room Management",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
            ),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xffd4af37),
                    foregroundColor: Colors.black,
                  ),
                  icon: const Icon(Icons.add_business),
                  label: const Text("Add Room", style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _showAddRoomDialog,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        Expanded(child: _buildRoomList()),
      ],
    );
  }

  Widget _buildRoomList() {
    if (_isLoadingRooms) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)));
    }

    if (_loadErrorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Could not load rooms: $_loadErrorMessage",
              style: const TextStyle(color: Color(0xffe0584a)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadRoomsFromServer, child: const Text("Try Again")),
          ],
        ),
      );
    }

    if (_roomInventory.isEmpty) {
      return const Center(
        child: Text("No rooms have been added yet.", style: TextStyle(color: Colors.white54)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRoomsFromServer,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _roomInventory.length,
        itemBuilder: (context, index) {
          final room = _roomInventory[index];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: const Color(0xff111f3a),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xff2d2d2d),
                foregroundColor: Color(0xffd4af37),
                child: Icon(Icons.bed),
              ),
              title: Text(room.roomName, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(room.description, style: const TextStyle(fontSize: 12, color: Colors.white54)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.price_change, color: Color(0xffd4af37), size: 20),
                    tooltip: "Manage Pricing",
                    onPressed: () => _showManagePricingDialog(room),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
                    onPressed: () => _showEditRoomDialog(room),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Color(0xffc0392b), size: 20),
                    onPressed: () => _handleDeleteRoomAsset(room),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleCreateRoomAsset() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isProcessingNetworkCall = true);

    try {
      final result = await widget.apiService.addRoom(
        roomName: "Room ${_roomNameController.text.trim()}",
        description: canonicalName(_descriptionController.text),
      );
      if (mounted) {
        Navigator.pop(context);
        _showActionResultSnackBar(result, "Room added.");
      }
      await _loadRoomsFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Room could not be added: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingNetworkCall = false);
    }
  }

  Future<void> _handleEditRoomAsset(RoomConfigRecord room) async {
    if (!_editFormKey.currentState!.validate()) return;
    setState(() => _isProcessingNetworkCall = true);

    try {
      final result = await widget.apiService.editRoom(
        roomId: room.id,
        description: canonicalName(_editDescriptionController.text),
      );
      if (mounted) {
        Navigator.pop(context);
        // The server's own sentence says what happened to the room's
        // prices, so it is shown as it is.
        _showActionResultSnackBar(result, (result['status'] ?? "Room updated.").toString());
      }
      await _loadRoomsFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Room could not be updated: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingNetworkCall = false);
    }
  }

  Future<void> _handleSetPricingForDescription(String description) async {
    final duration = int.parse(_pricingDurationController.text);
    final price = double.parse(_pricingPriceController.text);

    try {
      final result = await widget.apiService.setPricingForDescription(
        description: description,
        durationHours: duration,
        price: price,
      );
      _showActionResultSnackBar(result, "Price applied.");
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Could not add price: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    }
  }

  Future<bool> _confirmDelete(String title, String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffc0392b)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _handleRemovePricingForDescription(String description, int durationHours) async {
    if (!await _confirmDelete("Delete Price", "Delete the $durationHours hour price for this room type?")) return;
    try {
      final result = await widget.apiService.removePricingForDescription(
        description: description,
        durationHours: durationHours,
      );
      _showActionResultSnackBar(result, "Price removed.");
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not remove price: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    }
  }

  Future<void> _handleDeleteRoomAsset(RoomConfigRecord room) async {
    if (!await _confirmDelete("Delete Room", "Delete room ${room.roomName}?")) return;
    try {
      final result = await widget.apiService.deleteRoom(roomId: room.id);
      _showActionResultSnackBar(result, "Room removed.");
      await _loadRoomsFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Room could not be removed: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    }
  }
}
