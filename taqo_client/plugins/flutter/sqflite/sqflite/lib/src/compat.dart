import 'factory_mixin.dart';

///
/// internal options.
///
/// Used internally.
///
/// deprecated since 1.1.1
///
@deprecated
class SqfliteOptions {
  /// deprecated
  SqfliteOptions({this.logLevel});
  // true =<0.7.0
  /// deprecated
  bool queryAsMapList;

  /// deprecated
  int androidThreadPriority;

  /// deprecated
  int logLevel;

  /// deprecated
  Map<String, dynamic> toMap() {
    final Map<String, dynamic> map = <String, dynamic>{};
    if (queryAsMapList != null) {
      map['queryAsMapList'] = queryAsMapList;
    }
    if (androidThreadPriority != null) {
      map['androidThreadPriority'] = androidThreadPriority;
    }
    if (logLevel != null) {
      map[paramLogLevel] = logLevel;
    }
    return map;
  }

  /// deprecated
  void fromMap(Map<String, dynamic> map) {
    final dynamic queryAsMapList = map['queryAsMapList'];
    if (queryAsMapList is bool) {
      this.queryAsMapList = queryAsMapList;
    }
    final dynamic androidThreadPriority = map['androidThreadPriority'];
    if (androidThreadPriority is int) {
      this.androidThreadPriority = androidThreadPriority;
    }
    final dynamic logLevel = map[paramLogLevel];
    if (logLevel is int) {
      this.logLevel = logLevel;
    }
  }
}
