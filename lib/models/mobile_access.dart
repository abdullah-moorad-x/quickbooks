class AppUser {
  final String id;
  final String username;
  final String displayName;
  final String passcode;
  final UserRole role;
  final bool active;
  final List<String> allowedDeviceIds;
  final String createdAt;
  final String updatedAt;

  const AppUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.passcode,
    required this.role,
    this.active = true,
    this.allowedDeviceIds = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  AppUser copyWith({
    String? id,
    String? username,
    String? displayName,
    String? passcode,
    UserRole? role,
    bool? active,
    List<String>? allowedDeviceIds,
    String? createdAt,
    String? updatedAt,
  }) {
    return AppUser(
      id: id ?? this.id,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      passcode: passcode ?? this.passcode,
      role: role ?? this.role,
      active: active ?? this.active,
      allowedDeviceIds: allowedDeviceIds ?? this.allowedDeviceIds,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'displayName': displayName,
        'passcode': passcode,
        'role': role.name,
        'active': active,
        'allowedDeviceIds': allowedDeviceIds,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static AppUser fromJson(Map<String, dynamic> json) => AppUser(
        id: (json['id'] ?? '').toString(),
        username: (json['username'] ?? '').toString(),
        displayName: (json['displayName'] ?? '').toString(),
        passcode: (json['passcode'] ?? '').toString(),
        role: userRoleFromString((json['role'] ?? '').toString()),
        active: json['active'] is bool ? json['active'] as bool : true,
        allowedDeviceIds: ((json['allowedDeviceIds'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList(),
        createdAt: (json['createdAt'] ?? '').toString(),
        updatedAt: (json['updatedAt'] ?? '').toString(),
      );
}

enum UserRole { admin, sales, viewer }

UserRole userRoleFromString(String value) {
  switch (value.trim().toLowerCase()) {
    case 'admin':
      return UserRole.admin;
    case 'sales':
      return UserRole.sales;
    case 'viewer':
      return UserRole.viewer;
    default:
      return UserRole.viewer;
  }
}

String userRoleLabel(UserRole role) {
  switch (role) {
    case UserRole.admin:
      return 'Admin';
    case UserRole.sales:
      return 'Sales';
    case UserRole.viewer:
      return 'Viewer';
  }
}

class MobileDevice {
  final String id;
  final String label;
  final String platform;
  final String userId;
  final String? pushToken;
  final bool trusted;
  final String createdAt;
  final String? lastSeenAt;

  const MobileDevice({
    required this.id,
    required this.label,
    required this.platform,
    required this.userId,
    this.pushToken,
    this.trusted = true,
    required this.createdAt,
    this.lastSeenAt,
  });

  MobileDevice copyWith({
    String? id,
    String? label,
    String? platform,
    String? userId,
    String? pushToken,
    bool? trusted,
    String? createdAt,
    String? lastSeenAt,
  }) {
    return MobileDevice(
      id: id ?? this.id,
      label: label ?? this.label,
      platform: platform ?? this.platform,
      userId: userId ?? this.userId,
      pushToken: pushToken ?? this.pushToken,
      trusted: trusted ?? this.trusted,
      createdAt: createdAt ?? this.createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'platform': platform,
        'userId': userId,
        'pushToken': pushToken,
        'trusted': trusted,
        'createdAt': createdAt,
        'lastSeenAt': lastSeenAt,
      };

  static MobileDevice fromJson(Map<String, dynamic> json) => MobileDevice(
        id: (json['id'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        platform: (json['platform'] ?? '').toString(),
        userId: (json['userId'] ?? '').toString(),
        pushToken: (json['pushToken'] ?? '').toString().trim().isEmpty
            ? null
            : (json['pushToken'] ?? '').toString().trim(),
        trusted: json['trusted'] is bool ? json['trusted'] as bool : true,
        createdAt: (json['createdAt'] ?? '').toString(),
        lastSeenAt: (json['lastSeenAt'] ?? '').toString().trim().isEmpty
            ? null
            : (json['lastSeenAt'] ?? '').toString(),
      );
}

class MobileUserLocation {
  final String userId;
  final String username;
  final String displayName;
  final String deviceId;
  final double latitude;
  final double longitude;
  final double? accuracyMeters;
  final String capturedAt;
  final String receivedAt;
  final bool sharingEnabled;

  const MobileUserLocation({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.deviceId,
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
    required this.capturedAt,
    required this.receivedAt,
    this.sharingEnabled = true,
  });

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'displayName': displayName,
        'deviceId': deviceId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracyMeters': accuracyMeters,
        'capturedAt': capturedAt,
        'receivedAt': receivedAt,
        'sharingEnabled': sharingEnabled,
      };

  static MobileUserLocation fromJson(Map<String, dynamic> json) =>
      MobileUserLocation(
        userId: (json['userId'] ?? '').toString(),
        username: (json['username'] ?? '').toString(),
        displayName: (json['displayName'] ?? '').toString(),
        deviceId: (json['deviceId'] ?? '').toString(),
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
        accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
        capturedAt: (json['capturedAt'] ?? '').toString(),
        receivedAt: (json['receivedAt'] ?? '').toString(),
        sharingEnabled: json['sharingEnabled'] is bool
            ? json['sharingEnabled'] as bool
            : true,
      );
}

enum MobileOrderStatus { pending, delivered, cancelled }

MobileOrderStatus mobileOrderStatusFromString(String value) {
  switch (value.trim().toLowerCase()) {
    case 'delivered':
      return MobileOrderStatus.delivered;
    case 'cancelled':
    case 'canceled':
      return MobileOrderStatus.cancelled;
    case 'pending':
    default:
      return MobileOrderStatus.pending;
  }
}

String mobileOrderStatusLabel(MobileOrderStatus status) {
  switch (status) {
    case MobileOrderStatus.pending:
      return 'Pending';
    case MobileOrderStatus.delivered:
      return 'Delivered';
    case MobileOrderStatus.cancelled:
      return 'Cancelled';
  }
}

class MobileOrder {
  final String id;
  final String createdAt;
  final String createdByUserId;
  final String createdByName;
  final String updatedAt;
  final String updatedByUserId;
  final String updatedByName;
  final String orderDate;
  final String customerName;
  final String plotNo;
  final int bagsQuantity;
  final String bagsType;
  final String bagsBrand;
  final String orderSite;
  final String assignedTruckId;
  final String assignedTruckNo;
  final String note;
  final MobileOrderStatus status;
  final String statusUpdatedAt;
  final String statusUpdatedByUserId;
  final String statusUpdatedByName;
  final int? recordedInvoiceNo;
  final String? recordedInvoiceAt;

  const MobileOrder({
    required this.id,
    required this.createdAt,
    required this.createdByUserId,
    required this.createdByName,
    required this.updatedAt,
    required this.updatedByUserId,
    required this.updatedByName,
    required this.orderDate,
    this.customerName = '',
    required this.plotNo,
    required this.bagsQuantity,
    required this.bagsType,
    required this.bagsBrand,
    required this.orderSite,
    this.assignedTruckId = '',
    this.assignedTruckNo = '',
    this.note = '',
    this.status = MobileOrderStatus.pending,
    required this.statusUpdatedAt,
    required this.statusUpdatedByUserId,
    required this.statusUpdatedByName,
    this.recordedInvoiceNo,
    this.recordedInvoiceAt,
  });

  MobileOrder copyWith({
    String? id,
    String? createdAt,
    String? createdByUserId,
    String? createdByName,
    String? updatedAt,
    String? updatedByUserId,
    String? updatedByName,
    String? orderDate,
    String? customerName,
    String? plotNo,
    int? bagsQuantity,
    String? bagsType,
    String? bagsBrand,
    String? orderSite,
    String? assignedTruckId,
    String? assignedTruckNo,
    String? note,
    MobileOrderStatus? status,
    String? statusUpdatedAt,
    String? statusUpdatedByUserId,
    String? statusUpdatedByName,
    int? recordedInvoiceNo,
    String? recordedInvoiceAt,
    bool clearRecordedInvoice = false,
  }) {
    return MobileOrder(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      createdByUserId: createdByUserId ?? this.createdByUserId,
      createdByName: createdByName ?? this.createdByName,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedByUserId: updatedByUserId ?? this.updatedByUserId,
      updatedByName: updatedByName ?? this.updatedByName,
      orderDate: orderDate ?? this.orderDate,
      customerName: customerName ?? this.customerName,
      plotNo: plotNo ?? this.plotNo,
      bagsQuantity: bagsQuantity ?? this.bagsQuantity,
      bagsType: bagsType ?? this.bagsType,
      bagsBrand: bagsBrand ?? this.bagsBrand,
      orderSite: orderSite ?? this.orderSite,
      assignedTruckId: assignedTruckId ?? this.assignedTruckId,
      assignedTruckNo: assignedTruckNo ?? this.assignedTruckNo,
      note: note ?? this.note,
      status: status ?? this.status,
      statusUpdatedAt: statusUpdatedAt ?? this.statusUpdatedAt,
      statusUpdatedByUserId:
          statusUpdatedByUserId ?? this.statusUpdatedByUserId,
      statusUpdatedByName: statusUpdatedByName ?? this.statusUpdatedByName,
      recordedInvoiceNo: clearRecordedInvoice
          ? null
          : (recordedInvoiceNo ?? this.recordedInvoiceNo),
      recordedInvoiceAt: clearRecordedInvoice
          ? null
          : (recordedInvoiceAt ?? this.recordedInvoiceAt),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'createdByUserId': createdByUserId,
        'createdByName': createdByName,
        'updatedAt': updatedAt,
        'updatedByUserId': updatedByUserId,
        'updatedByName': updatedByName,
        'orderDate': orderDate,
        'customerName': customerName,
        'plotNo': plotNo,
        'bagsQuantity': bagsQuantity,
        'bagsType': bagsType,
        'bagsBrand': bagsBrand,
        'orderSite': orderSite,
        'assignedTruckId': assignedTruckId,
        'assignedTruckNo': assignedTruckNo,
        'note': note,
        'status': status.name,
        'statusUpdatedAt': statusUpdatedAt,
        'statusUpdatedByUserId': statusUpdatedByUserId,
        'statusUpdatedByName': statusUpdatedByName,
        'recordedInvoiceNo': recordedInvoiceNo,
        'recordedInvoiceAt': recordedInvoiceAt,
      };

  static MobileOrder fromJson(Map<String, dynamic> json) => MobileOrder(
        id: (json['id'] ?? '').toString(),
        createdAt: (json['createdAt'] ?? '').toString(),
        createdByUserId: (json['createdByUserId'] ?? '').toString(),
        createdByName: (json['createdByName'] ?? '').toString(),
        updatedAt: (json['updatedAt'] ?? json['createdAt'] ?? '').toString(),
        updatedByUserId:
            (json['updatedByUserId'] ?? json['createdByUserId'] ?? '')
                .toString(),
        updatedByName:
            (json['updatedByName'] ?? json['createdByName'] ?? '').toString(),
        orderDate: _orderDateFromJson(json),
        customerName: (json['customerName'] ?? '').toString(),
        plotNo: (json['plotNo'] ?? '').toString(),
        bagsQuantity: (json['bagsQuantity'] as num?)?.toInt() ?? 0,
        bagsType: (json['bagsType'] ?? '').toString(),
        bagsBrand: (json['bagsBrand'] ?? '').toString(),
        orderSite: (json['orderSite'] ?? '').toString(),
        assignedTruckId: (json['assignedTruckId'] ?? '').toString(),
        assignedTruckNo: (json['assignedTruckNo'] ?? '').toString(),
        note: (json['note'] ?? '').toString(),
        status: mobileOrderStatusFromString((json['status'] ?? '').toString()),
        statusUpdatedAt:
            (json['statusUpdatedAt'] ?? json['updatedAt'] ?? '').toString(),
        statusUpdatedByUserId:
            (json['statusUpdatedByUserId'] ?? json['updatedByUserId'] ?? '')
                .toString(),
        statusUpdatedByName:
            (json['statusUpdatedByName'] ?? json['updatedByName'] ?? '')
                .toString(),
        recordedInvoiceNo: (json['recordedInvoiceNo'] as num?)?.toInt(),
        recordedInvoiceAt:
            (json['recordedInvoiceAt'] ?? '').toString().trim().isEmpty
                ? null
                : (json['recordedInvoiceAt'] ?? '').toString(),
      );

  static String _orderDateFromJson(Map<String, dynamic> json) {
    final explicit = (json['orderDate'] ?? '').toString().trim();
    if (explicit.isNotEmpty) return explicit;
    final created = DateTime.tryParse((json['createdAt'] ?? '').toString());
    if (created != null) {
      return created.toIso8601String().split('T').first;
    }
    return DateTime.now().toIso8601String().split('T').first;
  }
}

class MobileTruck {
  final String id;
  final String number;
  final int capacity;
  final String orderDate;
  final Map<String, int> typeBags;

  const MobileTruck({
    required this.id,
    required this.number,
    required this.capacity,
    this.orderDate = '',
    this.typeBags = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'capacity': capacity,
        'orderDate': orderDate,
        'typeBags': typeBags,
      };

  MobileTruck copyWith({
    String? id,
    String? number,
    int? capacity,
    String? orderDate,
    Map<String, int>? typeBags,
  }) {
    return MobileTruck(
      id: id ?? this.id,
      number: number ?? this.number,
      capacity: capacity ?? this.capacity,
      orderDate: orderDate ?? this.orderDate,
      typeBags: typeBags ?? this.typeBags,
    );
  }

  static MobileTruck fromJson(Map<String, dynamic> json) {
    final rawTypeBags = json['typeBags'];
    final typeBags = <String, int>{};
    if (rawTypeBags is Map) {
      rawTypeBags.forEach((key, value) {
        final label = key.toString().trim();
        final qty =
            value is num ? value.toInt() : int.tryParse(value.toString()) ?? 0;
        if (label.isNotEmpty && qty > 0) {
          typeBags[label] = qty;
        }
      });
    }
    return MobileTruck(
      id: (json['id'] ?? '').toString(),
      number: (json['number'] ?? '').toString(),
      capacity: (json['capacity'] as num?)?.toInt() ??
          int.tryParse((json['capacity'] ?? '').toString()) ??
          0,
      orderDate: (json['orderDate'] ?? json['date'] ?? '').toString().trim(),
      typeBags: typeBags,
    );
  }
}

enum SyncLogDirection { incoming, outgoing, local }

SyncLogDirection syncLogDirectionFromString(String value) {
  switch (value.trim().toLowerCase()) {
    case 'incoming':
      return SyncLogDirection.incoming;
    case 'outgoing':
      return SyncLogDirection.outgoing;
    case 'local':
    default:
      return SyncLogDirection.local;
  }
}

enum SyncLogStatus { info, success, warning, error }

SyncLogStatus syncLogStatusFromString(String value) {
  switch (value.trim().toLowerCase()) {
    case 'success':
      return SyncLogStatus.success;
    case 'warning':
      return SyncLogStatus.warning;
    case 'error':
      return SyncLogStatus.error;
    case 'info':
    default:
      return SyncLogStatus.info;
  }
}

class SyncLogEntry {
  final String id;
  final String createdAt;
  final SyncLogDirection direction;
  final SyncLogStatus status;
  final String entityType;
  final String entityId;
  final String summary;
  final String? details;

  const SyncLogEntry({
    required this.id,
    required this.createdAt,
    required this.direction,
    required this.status,
    required this.entityType,
    required this.entityId,
    required this.summary,
    this.details,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'direction': direction.name,
        'status': status.name,
        'entityType': entityType,
        'entityId': entityId,
        'summary': summary,
        'details': details,
      };

  static SyncLogEntry fromJson(Map<String, dynamic> json) => SyncLogEntry(
        id: (json['id'] ?? '').toString(),
        createdAt: (json['createdAt'] ?? '').toString(),
        direction:
            syncLogDirectionFromString((json['direction'] ?? '').toString()),
        status: syncLogStatusFromString((json['status'] ?? '').toString()),
        entityType: (json['entityType'] ?? '').toString(),
        entityId: (json['entityId'] ?? '').toString(),
        summary: (json['summary'] ?? '').toString(),
        details: (json['details'] ?? '').toString().trim().isEmpty
            ? null
            : (json['details'] ?? '').toString(),
      );
}

class ServerSyncConfig {
  final String host;
  final int port;
  final bool enabled;
  final String baseUrl;
  final String? lastSyncAt;
  final String? lastStatus;
  final bool locationSharingEnabled;

  const ServerSyncConfig({
    this.host = '0.0.0.0',
    this.port = 8787,
    this.enabled = false,
    this.baseUrl = '',
    this.lastSyncAt,
    this.lastStatus,
    this.locationSharingEnabled = false,
  });

  ServerSyncConfig copyWith({
    String? host,
    int? port,
    bool? enabled,
    String? baseUrl,
    String? lastSyncAt,
    String? lastStatus,
    bool? locationSharingEnabled,
    bool clearLastSyncAt = false,
    bool clearLastStatus = false,
  }) {
    return ServerSyncConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      lastSyncAt: clearLastSyncAt ? null : (lastSyncAt ?? this.lastSyncAt),
      lastStatus: clearLastStatus ? null : (lastStatus ?? this.lastStatus),
      locationSharingEnabled:
          locationSharingEnabled ?? this.locationSharingEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'enabled': enabled,
        'baseUrl': baseUrl,
        'lastSyncAt': lastSyncAt,
        'lastStatus': lastStatus,
        'locationSharingEnabled': locationSharingEnabled,
      };

  static ServerSyncConfig fromJson(Map<String, dynamic> json) =>
      ServerSyncConfig(
        host: (json['host'] ?? '0.0.0.0').toString(),
        port: (json['port'] as num?)?.toInt() ?? 8787,
        enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
        baseUrl: (json['baseUrl'] ?? '').toString(),
        lastSyncAt: (json['lastSyncAt'] ?? '').toString().trim().isEmpty
            ? null
            : (json['lastSyncAt'] ?? '').toString(),
        lastStatus: (json['lastStatus'] ?? '').toString().trim().isEmpty
            ? null
            : (json['lastStatus'] ?? '').toString(),
        locationSharingEnabled: json['locationSharingEnabled'] is bool
            ? json['locationSharingEnabled'] as bool
            : false,
      );
}

class BiometricLoginConfig {
  final String userId;
  final String username;
  final String displayName;
  final bool enabled;
  final String? updatedAt;

  const BiometricLoginConfig({
    this.userId = '',
    this.username = '',
    this.displayName = '',
    this.enabled = false,
    this.updatedAt,
  });

  bool get isConfigured => enabled && userId.trim().isNotEmpty;

  BiometricLoginConfig copyWith({
    String? userId,
    String? username,
    String? displayName,
    bool? enabled,
    String? updatedAt,
    bool clearUpdatedAt = false,
  }) {
    return BiometricLoginConfig(
      userId: userId ?? this.userId,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      enabled: enabled ?? this.enabled,
      updatedAt: clearUpdatedAt ? null : (updatedAt ?? this.updatedAt),
    );
  }

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'displayName': displayName,
        'enabled': enabled,
        'updatedAt': updatedAt,
      };

  static BiometricLoginConfig fromJson(Map<String, dynamic> json) =>
      BiometricLoginConfig(
        userId: (json['userId'] ?? '').toString(),
        username: (json['username'] ?? '').toString(),
        displayName: (json['displayName'] ?? '').toString(),
        enabled: json['enabled'] is bool ? json['enabled'] as bool : false,
        updatedAt: (json['updatedAt'] ?? '').toString().trim().isEmpty
            ? null
            : (json['updatedAt'] ?? '').toString(),
      );
}
