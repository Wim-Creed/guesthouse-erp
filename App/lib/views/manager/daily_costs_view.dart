import 'package:flutter/material.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';
import '../../widgets/capitalize_words_formatter.dart';

/// Models an expense ledger row entry, as stored on the server.
class ExpenseRecord {
  final int id;
  final String itemOrReason;
  final double amountSpent;
  final String category;

  ExpenseRecord({
    required this.id,
    required this.itemOrReason,
    required this.amountSpent,
    required this.category,
  });

  factory ExpenseRecord.fromJson(Map<String, dynamic> json) {
    return ExpenseRecord(
      id: json['id'],
      itemOrReason: json['item_or_reason'],
      amountSpent: (json['amount_spent'] as num).toDouble(),
      category: json['category'] ?? "EXPENDABLES",
    );
  }
}

/// Handles daily Utilities and Expendables cost tracking. Utilities
/// entries are name + amount only (electricity and water aren't
/// countable units); Expendables keeps name + quantity + unit price, with
/// the total worked out automatically. Every write action here still
/// works even if the router is briefly down — it is saved and synced
/// automatically once the connection returns.
class DailyCostsView extends StatefulWidget {
  final ApiService apiService;

  const DailyCostsView({super.key, required this.apiService});

  @override
  State<DailyCostsView> createState() => _DailyCostsViewState();
}

class _DailyCostsViewState extends State<DailyCostsView> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _itemOrReasonController = TextEditingController();
  final TextEditingController _unitPriceController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController(text: "1");

  String _selectedCategoryFilter = "UTILITIES";
  bool _isProcessingNetworkCall = false;

  bool _isLoadingExpenses = true;
  String? _loadErrorMessage;
  List<ExpenseRecord> _activeExpensesRoster = [];

  @override
  void initState() {
    super.initState();
    _loadExpensesFromServer();
  }

  @override
  void dispose() {
    _itemOrReasonController.dispose();
    _unitPriceController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  Future<void> _loadExpensesFromServer() async {
    setState(() {
      _isLoadingExpenses = true;
      _loadErrorMessage = null;
    });

    try {
      final rawExpenses = await widget.apiService.fetchDailyExpenses();
      setState(() {
        _activeExpensesRoster = rawExpenses.map((e) => ExpenseRecord.fromJson(e)).toList();
        _isLoadingExpenses = false;
      });
    } catch (e) {
      setState(() {
        _loadErrorMessage = e.toString().replaceAll("Exception: ", "");
        _isLoadingExpenses = false;
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

  @override
  Widget build(BuildContext context) {
    final filteredExpenses = _activeExpensesRoster.where((e) => e.category == _selectedCategoryFilter).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Daily Costs",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
            ),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffd4af37), foregroundColor: Colors.black),
                  icon: const Icon(Icons.add_card),
                  label: const Text("Log Expense", style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () => _showExpenseEntryDialog(null),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),

        Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: ["UTILITIES", "EXPENDABLES"].map((category) {
            bool selected = _selectedCategoryFilter == category;
            return Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: ChoiceChip(
                label: Text(category),
                selected: selected,
                selectedColor: const Color(0xffd4af37),
                disabledColor: Colors.black12,
                labelStyle: TextStyle(color: selected ? Colors.black : Colors.white, fontWeight: FontWeight.bold),
                onSelected: (val) {
                  if (val) setState(() => _selectedCategoryFilter = category);
                },
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),
        Expanded(child: _buildExpenseList(filteredExpenses)),
      ],
    );
  }

  Widget _buildExpenseList(List<ExpenseRecord> filteredExpenses) {
    if (_isLoadingExpenses) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)));
    }

    if (_loadErrorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Could not load expenses: $_loadErrorMessage",
              style: const TextStyle(color: Color(0xffe0584a)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadExpensesFromServer, child: const Text("Try Again")),
          ],
        ),
      );
    }

    if (filteredExpenses.isEmpty) {
      return const Center(
        child: Text("No entries logged under this category.", style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadExpensesFromServer,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: filteredExpenses.length,
        itemBuilder: (context, index) {
          final record = filteredExpenses[index];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: const Color(0xff111f3a),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xff2d2d2d),
                foregroundColor: Color(0xffd4af37),
                child: Icon(Icons.monetization_on),
              ),
              title: Text(record.itemOrReason, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text("Category: ${record.category}"),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "₵ ${record.amountSpent.toStringAsFixed(2)}",
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber, fontSize: 16),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
                    onPressed: () => _showExpenseEntryDialog(record),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Color(0xffc0392b), size: 20),
                    onPressed: () => _handleDeleteRecord(record),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showExpenseEntryDialog(ExpenseRecord? existingRecord) {
    final bool isEditingMode = existingRecord != null;
    // Utilities entries are name + amount only (no quantity — electricity
    // and water aren't countable units); an edit keeps whichever category
    // the entry already has, a new entry follows the active filter chip.
    final String category = isEditingMode ? existingRecord.category : _selectedCategoryFilter;
    final bool isUtilities = category == "UTILITIES";

    if (isEditingMode) {
      _itemOrReasonController.text = existingRecord.itemOrReason;
      _unitPriceController.text = existingRecord.amountSpent.toString();
      _quantityController.text = "1";
    } else {
      _itemOrReasonController.clear();
      _unitPriceController.clear();
      _quantityController.text = "1";
    }

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final double unitPrice = double.tryParse(_unitPriceController.text) ?? 0.0;
            final int quantity = int.tryParse(_quantityController.text) ?? 0;
            final double calculatedTotal = isUtilities ? unitPrice : unitPrice * quantity;

            // One function behind both the Save button and the Enter key, so
            // they can never behave differently. It calls the very same
            // save routines the button always called; nothing about how an
            // entry is worked out or stored is changed here.
            void submitEntry() {
              if (_isProcessingNetworkCall) return;
              if (isEditingMode) {
                _handleEditExpense(existingRecord, calculatedTotal);
              } else {
                _handleAddExpense(calculatedTotal, category);
              }
            }

            return AlertDialog(
              title: Text(isEditingMode ? "Edit Expense" : "Log Expense"),
              content: SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: _itemOrReasonController,
                        autofocus: true,
                        // The one name rule (capitalize_words_formatter.dart):
                        // "diesel", "DIESEL" and "dIesel" all read "Diesel".
                        inputFormatters: [CapitalizeWordsFormatter()],
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                        decoration: const InputDecoration(labelText: "Item or Reason", border: OutlineInputBorder()),
                        validator: (val) => val == null || val.isEmpty ? "A reason is required" : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _unitPriceController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: isUtilities ? TextInputAction.done : TextInputAction.next,
                        // Utilities has no quantity, so this is its last field and Enter
                        // saves. Expendables carries on to Quantity.
                        onFieldSubmitted: isUtilities ? (_) => submitEntry() : (_) => FocusScope.of(context).nextFocus(),
                        decoration: InputDecoration(
                          labelText: isUtilities ? "Amount (GHS)" : "Price Per Unit (GHS)",
                          border: const OutlineInputBorder(),
                          prefixText: "₵ ",
                        ),
                        validator: (val) {
                          final parsed = double.tryParse(val ?? '');
                          return parsed == null || parsed < 0 ? "Enter a valid amount" : null;
                        },
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      // Expendables keeps name + quantity + unit price, with
                      // the total worked out automatically; Utilities has
                      // no quantity field at all.
                      if (!isUtilities) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _quantityController,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.done,
                          // Last field: Enter saves the entry.
                          onFieldSubmitted: (_) => submitEntry(),
                          decoration: const InputDecoration(labelText: "Quantity", border: OutlineInputBorder()),
                          validator: (val) {
                            final parsed = int.tryParse(val ?? '');
                            return parsed == null || parsed < 1 ? "Enter a quantity of at least 1" : null;
                          },
                          onChanged: (_) => setDialogState(() {}),
                        ),
                        const SizedBox(height: 16),
                        // Calculated automatically — nothing to add up by hand.
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Total", style: TextStyle(color: Colors.white70)),
                              Text(
                                "₵ ${calculatedTotal.toStringAsFixed(2)}",
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xffd4af37), fontSize: 16),
                              ),
                            ],
                          ),
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
                  onPressed: _isProcessingNetworkCall ? null : submitEntry,
                  child: _isProcessingNetworkCall
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text("Save Entry", style: TextStyle(color: Colors.black)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleAddExpense(double calculatedTotal, String category) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isProcessingNetworkCall = true);

    try {
      final result = await widget.apiService.addExpense(
        itemOrReason: canonicalName(_itemOrReasonController.text),
        amountSpent: calculatedTotal,
        category: category,
      );
      if (mounted) {
        Navigator.pop(context);
        _showActionResultSnackBar(result, "Expense logged.");
      }
      await _loadExpensesFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Could not log expense: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingNetworkCall = false);
    }
  }

  Future<void> _handleEditExpense(ExpenseRecord existingRecord, double calculatedTotal) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isProcessingNetworkCall = true);

    try {
      final result = await widget.apiService.editExpense(
        expenseId: existingRecord.id,
        itemOrReason: canonicalName(_itemOrReasonController.text),
        amountSpent: calculatedTotal,
      );
      if (mounted) {
        Navigator.pop(context);
        _showActionResultSnackBar(result, "Expense updated.");
      }
      await _loadExpensesFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xffc0392b),
            content: Text("Could not update expense: ${e.toString().replaceAll("Exception: ", "")}"),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingNetworkCall = false);
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

  Future<void> _handleDeleteRecord(ExpenseRecord targetingRecord) async {
    if (!await _confirmDelete("Delete Cost", "Delete \"${targetingRecord.itemOrReason}\"?")) return;
    try {
      final result = await widget.apiService.deleteExpense(expenseId: targetingRecord.id);
      _showActionResultSnackBar(result, "Expense removed.");
      await _loadExpensesFromServer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not remove expense: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    }
  }
}
