import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_bus.dart';
import '../models/mobile_access.dart';
import '../screens/invoice_screen.dart';
import '../services/local_api_server.dart';
import '../services/mobile_sync_store.dart';
import '../utils/format.dart';
import '../utils/snackbar.dart';
import '../widgets/app_panels.dart';
import '../widgets/skeleton_loader.dart';

class MobileAccessScreen extends StatefulWidget {
  const MobileAccessScreen({super.key});

  @override
  State<MobileAccessScreen> createState() => _MobileAccessScreenState();
}

class _MobileAccessScreenState extends State<MobileAccessScreen>
    with AutomaticKeepAliveClientMixin {
  final _displayNameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();
  final _serverHostCtrl = TextEditingController();
  final _serverPortCtrl = TextEditingController();
  UserRole _selectedRole = UserRole.viewer;
  bool _savingUser = false;
  bool _savingServer = false;
  bool _startingServer = false;
  bool _loading = true;
  bool _locationMonitorUnlocked = false;
  bool _locationPinSet = false;

  List<AppUser> _users = const [];
  List<PendingInvoice> _pendingInvoices = const [];
  List<MobileUserLocation> _locations = const [];
  List<SyncLogEntry> _logs = const [];
  ServerSyncConfig _serverConfig = const ServerSyncConfig();
  List<String> _reachableAddresses = const [];

  final DateFormat _stampFmt = DateFormat('dd MMM yyyy, hh:mm a');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_onDataTick);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_onDataTick);
    _displayNameCtrl.dispose();
    _usernameCtrl.dispose();
    _passcodeCtrl.dispose();
    _serverHostCtrl.dispose();
    _serverPortCtrl.dispose();
    super.dispose();
  }

  void _onDataTick() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      MobileAccessStore.loadUsers(),
      MobileAccessStore.loadPendingInvoices(),
      MobileAccessStore.loadUserLocations(),
      MobileAccessStore.loadSyncLogs(),
      MobileAccessStore.loadServerConfig(),
      MobileAccessStore.loadLocationMonitorPin(),
    ]);
    final serverConfig = results[4] as ServerSyncConfig;
    final addresses =
        await LocalApiServer.reachableAddresses(serverConfig.port);
    if (!mounted) return;
    setState(() {
      _users = results[0] as List<AppUser>;
      _pendingInvoices = results[1] as List<PendingInvoice>;
      _locations = results[2] as List<MobileUserLocation>;
      _logs = results[3] as List<SyncLogEntry>;
      _serverConfig = serverConfig;
      _locationPinSet = ((results[5] as String?) ?? '').trim().isNotEmpty;
      if (!_locationPinSet) _locationMonitorUnlocked = false;
      _reachableAddresses = addresses;
      _serverHostCtrl.text = _serverConfig.host;
      _serverPortCtrl.text = _serverConfig.port.toString();
      _loading = false;
    });
  }

  Future<void> _createUser() async {
    final displayName = _displayNameCtrl.text.trim();
    final username = _usernameCtrl.text.trim().toLowerCase();
    final passcode = _passcodeCtrl.text.trim();
    if (displayName.isEmpty || username.isEmpty || passcode.isEmpty) {
      showErr(context, 'Display name, username, and passcode are required.');
      return;
    }
    if (_users.any((u) => u.username.toLowerCase() == username)) {
      showErr(context, 'Username already exists.');
      return;
    }
    setState(() => _savingUser = true);
    final now = DateTime.now().toIso8601String();
    final user = AppUser(
      id: MobileAccessStore.nextUserId(displayName),
      username: username,
      displayName: displayName,
      passcode: passcode,
      role: _selectedRole,
      createdAt: now,
      updatedAt: now,
    );
    await MobileAccessStore.upsertUser(user);
    await MobileAccessStore.addSyncLog(SyncLogEntry(
      id: MobileAccessStore.nextSyncLogId(),
      createdAt: now,
      direction: SyncLogDirection.local,
      status: SyncLogStatus.success,
      entityType: 'users',
      entityId: user.id,
      summary: 'Created ${userRoleLabel(user.role)} mobile user',
      details: '${user.displayName} (${user.username})',
    ));
    _displayNameCtrl.clear();
    _usernameCtrl.clear();
    _passcodeCtrl.clear();
    _selectedRole = UserRole.viewer;
    if (!mounted) return;
    setState(() => _savingUser = false);
    showOk(context, 'User created.');
    await _load();
  }

  Future<void> _toggleUserStatus(AppUser user) async {
    final updated = user.copyWith(
      active: !user.active,
      updatedAt: DateTime.now().toIso8601String(),
    );
    await MobileAccessStore.upsertUser(updated);
    await MobileAccessStore.addSyncLog(SyncLogEntry(
      id: MobileAccessStore.nextSyncLogId(),
      createdAt: DateTime.now().toIso8601String(),
      direction: SyncLogDirection.local,
      status: SyncLogStatus.info,
      entityType: 'users',
      entityId: user.id,
      summary:
          updated.active ? 'Activated mobile user' : 'Deactivated mobile user',
      details: '${user.displayName} (${user.username})',
    ));
    if (!mounted) return;
    showOk(context, updated.active ? 'User activated.' : 'User deactivated.');
    await _load();
  }

  Future<void> _markPendingInvoice(
    PendingInvoice invoice,
    PendingInvoiceStatus status,
  ) async {
    final action =
        status == PendingInvoiceStatus.approved ? 'Approve' : 'Reject';
    final noteCtrl = TextEditingController(text: invoice.reviewNote ?? '');
    final result = await showDialog<_PendingReviewResult>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('$action draft ${invoice.draftCode}'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (status == PendingInvoiceStatus.approved)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Laptop will generate the final invoice number automatically on approval.',
                    ),
                  ),
                if (status == PendingInvoiceStatus.approved)
                  const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: status == PendingInvoiceStatus.approved
                        ? 'Approval note'
                        : 'Reason',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop(
                  _PendingReviewResult(noteCtrl.text.trim()),
                );
              },
              child: Text(action),
            ),
          ],
        );
      },
    );
    noteCtrl.dispose();
    if (result == null) return;
    if (status == PendingInvoiceStatus.approved) {
      final generatedInvoiceNo = await LocalApiServer.approvePendingInvoice(
        invoice,
        reviewNote: result.note.isEmpty ? null : result.note,
      );
      if (!mounted) return;
      showOk(context, 'Draft approved as invoice #$generatedInvoiceNo.');
      await _load();
      return;
    }
    await MobileAccessStore.updatePendingInvoiceStatus(
      invoice.id,
      status,
      reviewNote: result.note.isEmpty ? null : result.note,
      approvedInvoiceNo: null,
    );
    await MobileAccessStore.addSyncLog(SyncLogEntry(
      id: MobileAccessStore.nextSyncLogId(),
      createdAt: DateTime.now().toIso8601String(),
      direction: SyncLogDirection.local,
      status: SyncLogStatus.success,
      entityType: 'pending_invoice',
      entityId: invoice.id,
      summary:
          '${pendingInvoiceStatusLabel(status)} draft ${invoice.draftCode}',
      details: result.note.isEmpty ? null : result.note,
    ));
    if (!mounted) return;
    showOk(context, 'Draft updated.');
    await _load();
  }

  Future<void> _editPendingInvoice(PendingInvoice invoice) async {
    final updated = await Navigator.of(context).push<PendingInvoice?>(
      MaterialPageRoute(
        builder: (context) => InvoiceScreen(
          initialPendingDraft: invoice,
        ),
      ),
    );
    if (updated == null) return;
    await MobileAccessStore.upsertPendingInvoice(updated);
    await MobileAccessStore.addSyncLog(
      SyncLogEntry(
        id: MobileAccessStore.nextSyncLogId(),
        createdAt: DateTime.now().toIso8601String(),
        direction: SyncLogDirection.local,
        status: SyncLogStatus.info,
        entityType: 'pending_invoice',
        entityId: updated.id,
        summary: 'Edited pending draft ${updated.draftCode}',
      ),
    );
    if (!mounted) return;
    showOk(context, 'Pending draft updated.');
    await _load();
  }

  Future<void> _saveServerConfig() async {
    final port = int.tryParse(_serverPortCtrl.text.trim()) ?? 8787;
    setState(() => _savingServer = true);
    final updated = _serverConfig.copyWith(
      host: _serverHostCtrl.text.trim().isEmpty
          ? '0.0.0.0'
          : _serverHostCtrl.text.trim(),
      port: port,
      enabled: true,
      lastStatus: 'Saved desktop server settings.',
    );
    await MobileAccessStore.saveServerConfig(updated);
    if (!mounted) return;
    setState(() {
      _serverConfig = updated;
      _savingServer = false;
    });
    showOk(context, 'Server settings saved.');
    await _load();
  }

  Future<void> _toggleServer() async {
    setState(() => _startingServer = true);
    try {
      if (LocalApiServer.isRunning) {
        await LocalApiServer.stop();
        final updated = _serverConfig.copyWith(
          enabled: false,
          lastStatus: 'Laptop server stopped.',
          lastSyncAt: DateTime.now().toIso8601String(),
        );
        await MobileAccessStore.saveServerConfig(updated);
        if (!mounted) return;
        showOk(context, 'Laptop server stopped.');
      } else {
        final config = _serverConfig.copyWith(
          host: _serverHostCtrl.text.trim().isEmpty
              ? '0.0.0.0'
              : _serverHostCtrl.text.trim(),
          port: int.tryParse(_serverPortCtrl.text.trim()) ?? 8787,
        );
        await LocalApiServer.start(host: config.host, port: config.port);
        final updated = config.copyWith(
          enabled: true,
          lastStatus: 'Laptop server running on ${config.host}:${config.port}.',
          lastSyncAt: DateTime.now().toIso8601String(),
        );
        await MobileAccessStore.saveServerConfig(updated);
        if (!mounted) return;
        showOk(context, 'Laptop server started.');
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      showErr(context, e.toString());
    } finally {
      if (mounted) setState(() => _startingServer = false);
    }
  }

  Future<void> _unlockLocationMonitor() async {
    final savedPin = await MobileAccessStore.loadLocationMonitorPin();
    if (!mounted) return;
    final pinCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final isSetup = (savedPin ?? '').trim().isEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isSetup ? 'Set Location PIN' : 'Unlock Locations'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: isSetup ? 'New PIN' : 'PIN',
                ),
              ),
              if (isSetup) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: confirmCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Confirm PIN'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isSetup ? 'Save' : 'Unlock'),
          ),
        ],
      ),
    );
    final pin = pinCtrl.text.trim();
    final confirm = confirmCtrl.text.trim();
    pinCtrl.dispose();
    confirmCtrl.dispose();
    if (!mounted) return;
    if (ok != true) return;
    if (pin.length < 4) {
      showErr(context, 'PIN must be at least 4 digits.');
      return;
    }
    if (isSetup) {
      if (pin != confirm) {
        showErr(context, 'PIN does not match.');
        return;
      }
      await MobileAccessStore.saveLocationMonitorPin(pin);
      if (!mounted) return;
      setState(() {
        _locationPinSet = true;
        _locationMonitorUnlocked = true;
      });
      showOk(context, 'Location monitor PIN saved.');
      return;
    }
    if (pin != savedPin) {
      showErr(context, 'Wrong PIN.');
      return;
    }
    if (!mounted) return;
    setState(() => _locationMonitorUnlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const AppSkeletonLoader();
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _summaryRow(),
          const SizedBox(height: 12),
          _serverConfigCard(),
          const SizedBox(height: 12),
          _locationMonitorCard(),
          const SizedBox(height: 12),
          _userManagementCard(),
          const SizedBox(height: 12),
          _syncLogsCard(),
        ],
      ),
    );
  }

  Widget _summaryRow() {
    final activeUsers = _users.where((e) => e.active).length;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _SummaryTile(
          label: 'Mobile users',
          value: '${_users.length}',
          sublabel: '$activeUsers active',
          icon: Icons.person_outline,
        ),
        _SummaryTile(
          label: 'Sync log entries',
          value: '${_logs.length}',
          sublabel:
              _logs.isEmpty ? 'No activity yet' : 'Recent server activity',
          icon: Icons.sync_alt_outlined,
        ),
        _SummaryTile(
          label: 'Live locations',
          value: '${_locations.length}',
          sublabel: _locations.isEmpty ? 'No shared devices' : 'Latest reports',
          icon: Icons.location_on_outlined,
        ),
      ],
    );
  }

  Widget _userManagementCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mobile Users & Roles',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Create mobile users and assign their access level.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _displayNameCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Display name'),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _usernameCtrl,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _passcodeCtrl,
                    decoration: const InputDecoration(labelText: 'Passcode'),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<UserRole>(
                    initialValue: _selectedRole,
                    items: UserRole.values
                        .map(
                          (role) => DropdownMenuItem(
                            value: role,
                            child: Text(userRoleLabel(role)),
                          ),
                        )
                        .toList(),
                    onChanged: (role) {
                      if (role == null) return;
                      setState(() => _selectedRole = role);
                    },
                    decoration: const InputDecoration(labelText: 'Role'),
                  ),
                ),
                FilledButton.icon(
                  style: appGreenButtonStyle(context),
                  onPressed: _savingUser ? null : _createUser,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add mobile user'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_users.isEmpty)
              const Text('No users found.')
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Name')),
                    DataColumn(label: Text('Username')),
                    DataColumn(label: Text('Role')),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Devices')),
                    DataColumn(label: Text('Action')),
                  ],
                  rows: _users
                      .map(
                        (user) => DataRow(cells: [
                          DataCell(Text(user.displayName)),
                          DataCell(Text(user.username)),
                          DataCell(Text(userRoleLabel(user.role))),
                          DataCell(Text(user.active ? 'Active' : 'Inactive')),
                          DataCell(Text(
                            user.allowedDeviceIds.isEmpty
                                ? 'Any'
                                : user.allowedDeviceIds.length.toString(),
                          )),
                          DataCell(
                            TextButton(
                              onPressed: () => _toggleUserStatus(user),
                              child:
                                  Text(user.active ? 'Deactivate' : 'Activate'),
                            ),
                          ),
                        ]),
                      )
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _serverConfigCard() {
    final lastSync = (_serverConfig.lastSyncAt ?? '').trim().isEmpty
        ? 'Not updated yet'
        : _formatStamp(_serverConfig.lastSyncAt!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Laptop Server',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Recommended path for Tailscale: run the server on laptop, then use the shown address from your phone.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _serverHostCtrl,
                    decoration: const InputDecoration(labelText: 'Host'),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _serverPortCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
                FilledButton.icon(
                  style: appGreenButtonStyle(context),
                  onPressed: _savingServer ? null : _saveServerConfig,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(_savingServer ? 'Saving...' : 'Save'),
                ),
                OutlinedButton.icon(
                  style: appGreenOutlineButtonStyle(context),
                  onPressed: _startingServer ? null : _toggleServer,
                  icon: Icon(LocalApiServer.isRunning
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline),
                  label: Text(
                    _startingServer
                        ? 'Working...'
                        : (LocalApiServer.isRunning
                            ? 'Stop server'
                            : 'Start server'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              LocalApiServer.isRunning ? 'Status: Running' : 'Status: Stopped',
            ),
            Text('Last update: $lastSync'),
            if ((_serverConfig.lastStatus ?? '').isNotEmpty)
              Text('Server note: ${_serverConfig.lastStatus}'),
            const SizedBox(height: 10),
            if (_reachableAddresses.isEmpty)
              const Text('No reachable IPs found yet.')
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _reachableAddresses
                    .map((address) => SelectableText(address))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _locationMonitorCard() {
    if (!_locationMonitorUnlocked) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mobile User Locations',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                _locationPinSet
                    ? 'Location monitor is locked on this laptop.'
                    : 'Set a local PIN before viewing mobile locations.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _unlockLocationMonitor,
                icon: Icon(_locationPinSet
                    ? Icons.lock_open_outlined
                    : Icons.pin_outlined),
                label: Text(_locationPinSet ? 'Unlock' : 'Set PIN'),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mobile User Locations',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Shows latest location from mobile users who enabled sharing.',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _locationMonitorUnlocked = false),
                icon: const Icon(Icons.lock_outline),
                label: const Text('Lock'),
              ),
            ),
            const SizedBox(height: 12),
            if (_locations.isEmpty)
              const Text('No mobile locations received yet.')
            else
              ..._locations.map(_locationTile),
          ],
        ),
      ),
    );
  }

  Widget _locationTile(MobileUserLocation location) {
    final received = DateTime.tryParse(location.receivedAt);
    final age = received == null
        ? 'Unknown'
        : _locationAgeLabel(DateTime.now().difference(received));
    final accuracy = location.accuracyMeters == null
        ? '-'
        : '${location.accuracyMeters!.toStringAsFixed(0)} m';
    final mapUrl =
        'https://www.google.com/maps/search/?api=1&query=${location.latitude},${location.longitude}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDCE5EE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  location.displayName.trim().isEmpty
                      ? location.username
                      : location.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              AppMetaChip(
                icon: Icons.schedule_outlined,
                text: age,
                foregroundColor:
                    _isRecentLocation(received) ? Colors.green : Colors.orange,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppMetaChip(
                icon: Icons.my_location_outlined,
                text:
                    '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
              ),
              AppMetaChip(
                icon: Icons.gps_fixed_outlined,
                text: 'Accuracy $accuracy',
              ),
              AppMetaChip(
                icon: Icons.phone_android_outlined,
                text: location.deviceId.trim().isEmpty
                    ? 'Unknown device'
                    : location.deviceId,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(mapUrl),
        ],
      ),
    );
  }

  bool _isRecentLocation(DateTime? received) {
    if (received == null) return false;
    return DateTime.now().difference(received).inMinutes <= 5;
  }

  String _locationAgeLabel(Duration age) {
    if (age.inSeconds < 60) return 'Just now';
    if (age.inMinutes < 60) return '${age.inMinutes} min ago';
    if (age.inHours < 24) return '${age.inHours} hr ago';
    return '${age.inDays} day ago';
  }

  Widget _pendingInvoicesCard() {
    final pendingOnly = _pendingInvoices
        .where((invoice) => invoice.status == PendingInvoiceStatus.pending)
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pending Mobile Drafts',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Review, edit, approve, or reject invoice drafts sent from mobile.',
            ),
            const SizedBox(height: 12),
            if (pendingOnly.isEmpty)
              const Text('No pending mobile drafts yet.')
            else
              ...pendingOnly.map(_pendingInvoiceTile),
          ],
        ),
      ),
    );
  }

  Widget _pendingInvoiceTile(PendingInvoice invoice) {
    final statusColor = switch (invoice.status) {
      PendingInvoiceStatus.pending => Colors.orange.shade700,
      PendingInvoiceStatus.approved => Colors.green.shade700,
      PendingInvoiceStatus.rejected => Colors.red.shade700,
    };
    final ownerLine =
        '${invoice.submittedByName}  •  ${_formatStamp(invoice.submittedAt)}';
    return Card(
      elevation: 0,
      color: const Color(0xFFF8FAFC),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFDCE5EE)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  invoice.customer,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: Color(0xFF172033),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    pendingInvoiceStatusLabel(invoice.status),
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              invoice.draftCode,
              style: const TextStyle(
                color: Color(0xFF596275),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            ownerLine,
            style: const TextStyle(color: Color(0xFF6C7485)),
          ),
        ),
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _pendingMetaChip(
                  Icons.calendar_today_outlined, 'Date ${invoice.invoiceDate}'),
              _pendingMetaChip(Icons.place_outlined,
                  'Site ${invoice.site.isEmpty ? '-' : invoice.site}'),
              if (invoice.address.trim().isNotEmpty)
                _pendingMetaChip(
                  Icons.location_on_outlined,
                  'Address ${invoice.address.trim()}',
                ),
              _pendingMetaChip(Icons.phone_outlined,
                  'Contact ${invoice.contact.isEmpty ? '-' : invoice.contact}'),
              _pendingMetaChip(
                  Icons.payments_outlined, 'Total Rs ${fmt0(invoice.balance)}'),
            ],
          ),
          const SizedBox(height: 10),
          if (invoice.lines.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE1E7EF)),
              ),
              child: const Text(
                'No lines in draft.',
                style: TextStyle(color: Color(0xFF5E6678)),
              ),
            )
          else
            Column(
              children: invoice.lines
                  .map(
                    (line) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE1E7EF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  line.typeLabel,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF172033),
                                  ),
                                ),
                              ),
                              Text(
                                'Rs ${fmt0(line.amount)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF172033),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            line.brand.isEmpty ? 'Brand: -' : line.brand,
                            style: const TextStyle(color: Color(0xFF566074)),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _pendingLinePill('Qty ${line.qty}'),
                              _pendingLinePill('Rate ${fmt0(line.rate)}'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          if ((invoice.reviewNote ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E8),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFF0DEAB)),
              ),
              child: Text(
                'Review note: ${invoice.reviewNote}',
                style: const TextStyle(color: Color(0xFF6D5A18)),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                style: appGreenButtonStyle(context),
                onPressed: () => _editPendingInvoice(invoice),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit'),
              ),
              FilledButton.icon(
                style: appGreenButtonStyle(context),
                onPressed: invoice.status == PendingInvoiceStatus.approved
                    ? null
                    : () => _markPendingInvoice(
                          invoice,
                          PendingInvoiceStatus.approved,
                        ),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('Approve'),
              ),
              OutlinedButton.icon(
                style: appDangerOutlineButtonStyle(context),
                onPressed: invoice.status == PendingInvoiceStatus.rejected
                    ? null
                    : () => _markPendingInvoice(
                          invoice,
                          PendingInvoiceStatus.rejected,
                        ),
                icon: const Icon(Icons.close_outlined, size: 18),
                label: const Text('Reject'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _syncLogsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sync Activity Log',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Audit trail for sync, user changes, and draft actions.',
            ),
            const SizedBox(height: 12),
            if (_logs.isEmpty)
              const Text('No sync activity yet.')
            else
              ..._logs.take(20).map((log) {
                final color = switch (log.status) {
                  SyncLogStatus.info => Colors.blueGrey,
                  SyncLogStatus.success => Colors.green,
                  SyncLogStatus.warning => Colors.orange,
                  SyncLogStatus.error => Colors.red,
                };
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(Icons.fiber_manual_record, size: 12, color: color),
                  title: Text(log.summary),
                  subtitle: Text(
                    '${_formatStamp(log.createdAt)} - ${log.entityType} - ${log.direction.name}',
                  ),
                  trailing: log.details == null
                      ? null
                      : ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          child: Text(
                            log.details!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                          ),
                        ),
                );
              }),
          ],
        ),
      ),
    );
  }

  String _formatStamp(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return _stampFmt.format(parsed.toLocal());
  }

  Widget _pendingMetaChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE1E7EF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF6A7385)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFF364056),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pendingLinePill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6FA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF51607A),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final String sublabel;
  final IconData icon;

  const _SummaryTile({
    required this.label,
    required this.value,
    required this.sublabel,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F7F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDCE7EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 10),
          Text(
            value,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(sublabel, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PendingReviewResult {
  final String note;

  const _PendingReviewResult(this.note);
}
