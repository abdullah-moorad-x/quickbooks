import 'package:flutter/foundation.dart';

class AppBus {
  static final ValueNotifier<int> dataTick = ValueNotifier<int>(0);
  static void bump() {
    dataTick.value = dataTick.value + 1;
  }
}

