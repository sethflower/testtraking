import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/scanpak_auth.dart';

class ScanpakHomeScreen extends StatefulWidget {
  const ScanpakHomeScreen({super.key});

  @override
  State<ScanpakHomeScreen> createState() => _ScanpakHomeScreenState();
}

class _ScanpakHomeScreenState extends State<ScanpakHomeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _numberController = TextEditingController();
  final FocusNode _numberFocus = FocusNode();

  final TextEditingController _parcelFilterController = TextEditingController();
  final TextEditingController _userFilterController = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  late final TabController _tabController;
  String? _userName;
  String _status = '';
  bool _isLoadingHistory = false;
  List<_ScanpakRecord> _records = const [];
  List<_ScanpakRecord> _filteredRecords = const [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging && _tabController.index == 0) {
          _focusInput();
        }
      });
    _loadUser();
    _fetchHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusInput());
  }

  @override
  void dispose() {
    _tabController.dispose();
    _numberController.dispose();
    _numberFocus.dispose();
    _parcelFilterController.dispose();
    _userFilterController.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _userName = prefs.getString('scanpak_user_name'));
  }

  Future<void> _fetchHistory() async {
    setState(() => _isLoadingHistory = true);
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('scanpak_token');
    if (token == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      if (mounted) setState(() => _isLoadingHistory = false);
      return;
    }

    try {
      final uri = Uri.https(kScanpakApiHost, '$kScanpakBasePath/history');
      final response = await http.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode != 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Не вдалося отримати історію (${response.statusCode})',
              ),
            ),
          );
        }
        return;
      }

      final parsed = _ScanpakRecord.decodeList(response.body);
      setState(() {
        _records = parsed;
      });
      _applyFilters();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Помилка зв’язку з сервером: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  void _focusInput() {
    if (_numberFocus.canRequestFocus) {
      _numberFocus.requestFocus();
    }
  }

  String _sanitizeNumber(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

  void _onChanged(String value) {
    final sanitized = _sanitizeNumber(value);
    if (sanitized != value) {
      _numberController.value = TextEditingValue(
        text: sanitized,
        selection: TextSelection.collapsed(offset: sanitized.length),
      );
    }
  }

  Future<void> _handleSubmit([String? raw]) async {
    final digits = _sanitizeNumber(raw ?? _numberController.text);
    if (digits.isEmpty) {
      setState(() => _status = 'Введіть номер відправлення (лише цифри)');
      _focusInput();
      return;
    }

    setState(() => _status = 'Відправляємо...');
    try {
      final record = await _sendScanToBackend(digits);
      setState(() {
        _records = <_ScanpakRecord>[record, ..._records];
        _status =
            'Збережено для ${record.user} о ${DateFormat('HH:mm').format(record.timestamp.toLocal())}';
      });
      _applyFilters();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
      setState(() => _status = 'Сталася помилка. Спробуйте ще раз');
    }

    _numberController.clear();
    _focusInput();
  }

  Future<_ScanpakRecord> _sendScanToBackend(String digits) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('scanpak_token');
    if (token == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      throw Exception('Немає токена авторизації');
    }

    final uri = Uri.https(kScanpakApiHost, '$kScanpakBasePath/scans');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'parcel_number': digits}),
    );

    if (response.statusCode == 401) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      throw Exception('Сесію завершено. Увійдіть знову');
    }

    if (response.statusCode != 200) {
      throw Exception('Не вдалося зберегти: ${response.statusCode}');
    }

    return _ScanpakRecord.fromResponse(response.body);
  }

  void _applyFilters() {
    List<_ScanpakRecord> filtered = List.of(_records);

    if (_parcelFilterController.text.isNotEmpty) {
      filtered = filtered
          .where((r) => r.number.contains(_parcelFilterController.text.trim()))
          .toList();
    }

    if (_userFilterController.text.isNotEmpty) {
      filtered = filtered
          .where(
            (r) => r.user.toLowerCase().contains(
              _userFilterController.text.trim().toLowerCase(),
            ),
          )
          .toList();
    }

    if (_selectedDate != null) {
      filtered = filtered.where((r) {
        final local = r.timestamp.toLocal();
        return local.year == _selectedDate!.year &&
            local.month == _selectedDate!.month &&
            local.day == _selectedDate!.day;
      }).toList();
    }

    if (_startTime != null || _endTime != null) {
      filtered = filtered.where((r) {
        final local = r.timestamp.toLocal();
        final time = TimeOfDay.fromDateTime(local);

        bool afterStart = true;
        bool beforeEnd = true;

        if (_startTime != null) {
          afterStart =
              time.hour > _startTime!.hour ||
              (time.hour == _startTime!.hour &&
                  time.minute >= _startTime!.minute);
        }

        if (_endTime != null) {
          beforeEnd =
              time.hour < _endTime!.hour ||
              (time.hour == _endTime!.hour && time.minute <= _endTime!.minute);
        }

        return afterStart && beforeEnd;
      }).toList();
    }

    setState(() => _filteredRecords = filtered);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(2024),
      lastDate: now,
      locale: const Locale('uk', 'UA'),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
      _applyFilters();
    }
  }

  Future<void> _pickTime(bool isStart) async {
    final now = TimeOfDay.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? (_startTime ?? now) : (_endTime ?? now),
      helpText: isStart ? 'Початковий час' : 'Кінцевий час',
      cancelText: 'Скасувати',
      confirmText: 'OK',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
      _applyFilters();
    }
  }

  void _clearFilters() {
    _parcelFilterController.clear();
    _userFilterController.clear();
    _selectedDate = null;
    _startTime = null;
    _endTime = null;
    _applyFilters();
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('scanpak_token');
    await prefs.remove('scanpak_user_name');
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('СканПак'),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Вийти',
              onPressed: _logout,
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Сканування'),
              Tab(text: 'Історія'),
              Tab(text: 'Статистика'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildScanTab(theme),
            _buildHistoryTab(theme),
            _buildStatsTab(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildScanTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Сканування відправлень', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Поле завжди активно. Відскануйте або введіть номер — після "Enter" воно очиститься і залишиться у фокусі.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 24),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.qr_code_scanner, color: Colors.blue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _userName == null
                              ? 'Сканування без імені'
                              : 'Оператор: $_userName',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _numberController,
                    focusNode: _numberFocus,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Номер посилки',
                      helperText: 'Лише цифри, курсор завжди у цьому полі',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: _onChanged,
                    onSubmitted: _handleSubmit,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _handleSubmit(),
                    icon: const Icon(Icons.save),
                    label: const Text('Зберегти скан'),
                  ),
                  if (_status.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.green[700],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _filterField(_parcelFilterController, 'Номер'),
              _filterField(_userFilterController, 'Користувач'),
              ElevatedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.date_range),
                label: Text(
                  _selectedDate == null
                      ? 'Дата'
                      : DateFormat('dd.MM.yyyy').format(_selectedDate!),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => _pickTime(true),
                icon: const Icon(Icons.access_time),
                label: Text(
                  _startTime == null ? 'Початок' : _startTime!.format(context),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => _pickTime(false),
                icon: const Icon(Icons.timelapse),
                label: Text(
                  _endTime == null ? 'Кінець' : _endTime!.format(context),
                ),
              ),
              TextButton.icon(
                onPressed: _clearFilters,
                icon: const Icon(Icons.clear),
                label: const Text('Скинути'),
              ),
              IconButton(
                tooltip: 'Оновити',
                onPressed: _fetchHistory,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _isLoadingHistory
              ? const Center(child: CircularProgressIndicator())
              : _filteredRecords.isEmpty
              ? const Center(child: Text('Історія порожня'))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _filteredRecords.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final record = _filteredRecords[index];
                    final localTime = record.timestamp.toLocal();
                    final date = DateFormat('dd.MM.yyyy').format(localTime);
                    final time = DateFormat('HH:mm').format(localTime);

                    return Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.inventory_2,
                                  color: Colors.blue,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Номер: ${record.number}',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                Text(
                                  '$date • $time',
                                  style: theme.textTheme.labelMedium,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Користувач: ${record.user}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[700],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _filterField(TextEditingController controller, String label) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: controller,
        onChanged: (_) => _applyFilters(),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildStatsTab(ThemeData theme) {
    return Center(
      child: Text(
        'Статистика користувача — в розробці',
        style: theme.textTheme.titleMedium,
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _ScanpakRecord {
  const _ScanpakRecord({
    required this.number,
    required this.user,
    required this.timestamp,
  });

  final String number;
  final String user;
  final DateTime timestamp;

  static _ScanpakRecord fromJson(Map<String, dynamic> map) {
    final number = map['parcel_number']?.toString() ?? '';
    final user = map['username']?.toString() ?? '';
    final timestamp = DateTime.tryParse(map['scanned_at']?.toString() ?? '');
    if (number.isEmpty || timestamp == null) {
      throw const FormatException('Некоректні дані сканування');
    }
    return _ScanpakRecord(number: number, user: user, timestamp: timestamp);
  }

  static _ScanpakRecord fromResponse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Некоректна відповідь сервера');
    }
    return fromJson(decoded);
  }

  static List<_ScanpakRecord> decodeList(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(_ScanpakRecord.fromJson)
        .toList();
  }
}
