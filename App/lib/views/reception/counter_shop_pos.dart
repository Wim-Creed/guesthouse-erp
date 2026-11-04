import 'package:flutter/material.dart';

// Links to the shared network service core tool
import '../../services/api_service.dart';
import '../../widgets/currency_toggle_terminal.dart';
import '../../widgets/payment_method_selector.dart';
import '../../widgets/capitalize_words_formatter.dart';

/// One line item the receptionist has entered for this sale.
class ShopCartItem {
  final String name;
  final int quantity;
  final double unitPrice;

  ShopCartItem({required this.name, required this.quantity, required this.unitPrice});

  double get subtotal => quantity * unitPrice;
}

/// One completed sale, as already recorded on the server during this shift.
class CompletedSaleRecord {
  final String itemName;
  final int quantity;
  final double totalCost;
  final String paymentMode;

  CompletedSaleRecord({
    required this.itemName,
    required this.quantity,
    required this.totalCost,
    required this.paymentMode,
  });

  factory CompletedSaleRecord.fromJson(Map<String, dynamic> json) {
    return CompletedSaleRecord(
      itemName: json['item_name'],
      quantity: json['quantity'],
      totalCost: (json['total_cost'] as num).toDouble(),
      paymentMode: json['payment_mode'] ?? "CASH",
    );
  }
}

/// The counter shop sale screen. Every item is typed in by the
/// receptionist — there is no fixed catalog, since the range of things
/// sold at the counter is too broad to maintain as a hardcoded list.
class CounterShopPos extends StatefulWidget {
  final ApiService apiService;

  const CounterShopPos({super.key, required this.apiService});

  @override
  State<CounterShopPos> createState() => _CounterShopPosState();
}

class _CounterShopPosState extends State<CounterShopPos> {
  final List<ShopCartItem> _cart = [];
  bool _isProcessingSale = false;

  String _paymentMode = "CASH";
  final TextEditingController _momoWalletController = TextEditingController();
  final TextEditingController _bankAccountController = TextEditingController();
  double _cashTenderedGhs = 0.0;
  double _changeReturnedGhs = 0.0;
  double? _usdReceived;
  bool _isPaymentSufficient = true;

  bool _isLoadingTodaysSales = true;
  List<CompletedSaleRecord> _todaysSales = [];

  double get _cartTotal => _cart.fold(0.0, (sum, item) => sum + item.subtotal);

  @override
  void initState() {
    super.initState();
    _loadTodaysSales();
  }

  /// Pulls every sale already recorded during the current shift, so the
  /// receptionist can see what has actually been sold so far, rather than
  /// the screen appearing to forget everything after each sale.
  Future<void> _loadTodaysSales() async {
    setState(() => _isLoadingTodaysSales = true);
    try {
      final rawSales = await widget.apiService.fetchTodaysShopSales();
      if (mounted) {
        setState(() {
          _todaysSales = rawSales.map((s) => CompletedSaleRecord.fromJson(s)).toList();
          _isLoadingTodaysSales = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingTodaysSales = false);
    }
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
              "Shop Sale",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xffd4af37)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffd4af37), foregroundColor: Colors.black),
              icon: const Icon(Icons.add),
              label: const Text("Add Item"),
              onPressed: _showAddItemDialog,
            ),
          ],
        ),
        const SizedBox(height: 16),

        Expanded(
          child: _cart.isEmpty ? _buildTodaysSalesList() : _buildSaleInProgress(),
        ),
      ],
    );
  }

  /// Shown while there is no cart in progress: a plain list of what has
  /// already been sold this shift, pulled straight from the server.
  Widget _buildTodaysSalesList() {
    if (_isLoadingTodaysSales) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffd4af37)));
    }

    return RefreshIndicator(
      onRefresh: _loadTodaysSales,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Sold This Shift", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(height: 8),
          Expanded(
            child: _todaysSales.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            "Nothing sold yet this shift.",
                            style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic),
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _todaysSales.length,
                    itemBuilder: (context, index) {
                      final sale = _todaysSales[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        color: const Color(0xff111f3a),
                        child: ListTile(
                          title: Text(sale.itemName, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text("${sale.quantity} sold  •  ${sale.paymentMode}"),
                          trailing: Text(
                            "₵ ${sale.totalCost.toStringAsFixed(2)}",
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// The sale being built up: its items, then how it is paid for, then the
  /// button that completes it. All of it sits in one scrolling column, so on
  /// a short screen the receptionist can always reach Cash Received and
  /// Complete Sale instead of the bottom being cut off. Everything stays
  /// built while scrolling, so nothing typed is lost.
  Widget _buildSaleInProgress() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._cartItemCards(),
          const Divider(height: 24),

          PaymentMethodSelector(
            paymentMode: _paymentMode,
            momoController: _momoWalletController,
            bankController: _bankAccountController,
            onChanged: (mode) => setState(() => _paymentMode = mode),
          ),

          CurrencyToggleTerminal(
            totalCostInGhs: _cartTotal,
            exchangeRate: widget.apiService.activeExchangeRate,
            // The first thing worth typing into once a cart actually has
            // items in it.
            autofocus: true,
            // Transfers (MoMo or bank) have no meaningful "change due"; only cash does.
            showChangeDue: _paymentMode == "CASH",
            allowDollars: _paymentMode != "MOMO",
            // Enter on Cash Received is the last step: it completes the sale.
            onSubmitted: _isProcessingSale ? null : _submitCartToBackend,
            onValuesChanged: (cashTenderedGhs, changeReturnedGhs, usdReceived, isSufficient) {
              // Captures what the guest handed over and the change owed,
              // so both can be recorded alongside the sale.
              _cashTenderedGhs = cashTenderedGhs;
              _changeReturnedGhs = changeReturnedGhs;
              _usdReceived = usdReceived;
              _isPaymentSufficient = isSufficient;
            },
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xffd4af37),
                foregroundColor: const Color(0xff0a1426),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              onPressed: _isProcessingSale ? null : _submitCartToBackend,
              child: _isProcessingSale
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Text("Complete Sale", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  /// One card per item in the sale being built up.
  List<Widget> _cartItemCards() {
    return List.generate(_cart.length, (index) {
      final item = _cart[index];
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        color: const Color(0xff111f3a),
        child: ListTile(
          title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text("${item.quantity} x ₵ ${item.unitPrice.toStringAsFixed(2)}"),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("₵ ${item.subtotal.toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: () => setState(() => _cart.removeAt(index)),
              ),
            ],
          ),
        ),
      );
    });
  }

  /// Opens the popup for entering one item's name, quantity and unit price
  /// (see _AddItemDialog) and, when the receptionist confirms it, adds the
  /// item to the sale in progress.
  Future<void> _showAddItemDialog() async {
    final ShopCartItem? item = await showDialog<ShopCartItem>(
      context: context,
      builder: (dialogContext) => const _AddItemDialog(),
    );
    if (item != null && mounted) {
      setState(() => _cart.add(item));
    }
  }

  Future<void> _submitCartToBackend() async {
    // Every payment type is checked against the sale total, matching the backend.
    if (!_isPaymentSufficient) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_paymentMode == "CASH" ? "Cash Received is less than the sale total." : "Amount received is less than the sale total.")),
      );
      return;
    }

    // A transfer is recorded with what actually arrived, so it must be typed in.
    if (_paymentMode != "CASH" && _cashTenderedGhs <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Enter the amount received.")),
      );
      return;
    }

    final String? transferProblem = PaymentMethodSelector.detailsProblem(
        _paymentMode, _momoWalletController.text, _bankAccountController.text);
    if (transferProblem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(transferProblem)));
      return;
    }

    setState(() => _isProcessingSale = true);

    try {
      bool anyQueuedOffline = false;

      // Every item in the cart is saved as its own separate record, but
      // the cash actually received and the change actually given belong
      // to the sale as a whole, not to any one item in it. Each item's
      // own share of that cash/change — proportional to its share of the
      // cart's total — is what gets recorded on its line, so that adding
      // every item's recorded cash back up reconstructs exactly what was
      // really handed over, instead of every line showing the full
      // cart's cash figures repeated. The last item absorbs whatever
      // rounding remainder is left over from the earlier items' shares,
      // so the parts always add back up to the real total exactly.
      final double cartTotal = _cart.fold(0.0, (sum, item) => sum + item.subtotal);
      double cashAllocatedSoFar = 0.0;
      double changeAllocatedSoFar = 0.0;

      for (int i = 0; i < _cart.length; i++) {
        final item = _cart[i];
        final bool isLastItem = i == _cart.length - 1;

        double itemCashShare;
        double itemChangeShare;
        if (isLastItem) {
          itemCashShare = _cashTenderedGhs - cashAllocatedSoFar;
          itemChangeShare = _changeReturnedGhs - changeAllocatedSoFar;
        } else {
          final double shareOfCart = cartTotal > 0 ? item.subtotal / cartTotal : 0.0;
          itemCashShare = double.parse((_cashTenderedGhs * shareOfCart).toStringAsFixed(2));
          itemChangeShare = double.parse((_changeReturnedGhs * shareOfCart).toStringAsFixed(2));
          cashAllocatedSoFar += itemCashShare;
          changeAllocatedSoFar += itemChangeShare;
        }

        final result = await widget.apiService.submitShopSaleItem(
          itemName: item.name,
          quantity: item.quantity,
          unitPrice: item.unitPrice,
          paymentMode: _paymentMode,
          cashTendered: itemCashShare,
          changeReturned: itemChangeShare,
          usdReceived: _usdReceived,
          momoNumber: _paymentMode == "MOMO" ? _momoWalletController.text.trim() : null,
          bankSenderAccount: _paymentMode == "BANK" ? _bankAccountController.text.trim() : null,
        );
        if (result['queued_offline'] == true) anyQueuedOffline = true;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: anyQueuedOffline ? const Color(0xffc9971f) : const Color(0xff14703f),
            content: Text(
              anyQueuedOffline ? "Saved. Pending, will be sent when the connection returns." : "Sale completed and recorded.",
            ),
          ),
        );
        setState(() {
          _cart.clear();
          _paymentMode = "CASH";
          _momoWalletController.clear();
          _bankAccountController.clear();
          _cashTenderedGhs = 0.0;
          _changeReturnedGhs = 0.0;
          _usdReceived = null;
        });
        // Refresh the shift's sales list now that a new sale has landed,
        // so the receptionist immediately sees it reflected on screen.
        await _loadTodaysSales();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Sale could not be completed: ${e.toString().replaceAll("Exception: ", "")}")),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingSale = false);
    }
  }

  @override
  void dispose() {
    _momoWalletController.dispose();
    _bankAccountController.dispose();
    super.dispose();
  }
}


/// The popup for entering one item's name, quantity and unit price.
///
/// Enter walks Item Name, then Quantity, then Price, and on the Price field
/// it adds the item, exactly like pressing "Add to Sale". The Up and Down
/// arrow keys walk the same fields. Cancel is only ever reached on purpose.
///
/// The popup owns its text controllers and focus nodes and releases them in
/// its own dispose, which runs only once the popup has fully left the
/// screen, so a field is never released while it is still being drawn.
class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog();

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController(text: "1");
  final TextEditingController _priceController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  final FocusNode _quantityFocus = FocusNode();
  final FocusNode _priceFocus = FocusNode();

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _nameFocus.dispose();
    _quantityFocus.dispose();
    _priceFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(ShopCartItem(
      // The one name rule, so the item is stored and shown the same way
      // whatever case it was typed in.
      name: canonicalName(_nameController.text),
      quantity: int.parse(_quantityController.text),
      unitPrice: double.parse(_priceController.text),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Add Item"),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                focusNode: _nameFocus,
                autofocus: true,
                inputFormatters: [CapitalizeWordsFormatter()],
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => _quantityFocus.requestFocus(),
                decoration: const InputDecoration(labelText: "Item Name", border: OutlineInputBorder()),
                validator: (val) => val == null || val.trim().isEmpty ? "Item name is required" : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _quantityController,
                focusNode: _quantityFocus,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => _priceFocus.requestFocus(),
                decoration: const InputDecoration(labelText: "Quantity", border: OutlineInputBorder()),
                validator: (val) {
                  final parsed = int.tryParse(val ?? '');
                  if (parsed == null || parsed < 1) return "Enter a quantity of at least 1";
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _priceController,
                focusNode: _priceFocus,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: const InputDecoration(labelText: "Price Per Unit (GHS)", prefixText: "₵ ", border: OutlineInputBorder()),
                validator: (val) {
                  final parsed = double.tryParse(val ?? '');
                  if (parsed == null || parsed < 0) return "Enter a valid price";
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xffd4af37), foregroundColor: Colors.black),
          onPressed: _submit,
          child: const Text("Add to Sale", style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
