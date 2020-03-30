import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:taqo_shared_prefs/taqo_shared_prefs.dart';

import '../storage/dart_file_storage.dart';
import 'app_logger.dart';
import 'cmdline_logger.dart';
import 'rpc_constants.dart';
import 'dbus_notifications.dart' as dbus;
import 'linux_alarm_manager.dart' as linux_alarm_manager;
import 'socket_channel.dart';
import 'util.dart';

const _sharedPrefsExperimentPauseKey = "paused";

json_rpc.Peer _peer;

void openSurvey(int id) {
  try {
    // If the app is running, just notify it to open a survey
    _peer.sendNotification(openSurveyMethod, {'id': id,});
  } catch (e) {
    // Else launch the app and it will automatically open the survey
    // Note: this will only work if Taqo is in the user's PATH
    // For debugging/testing, maybe create a symlink in /usr/local/bin pointing to
    // build/linux/debug/taqo_survey
    Process.run('taqo_survey', []);
  }
}

void _handleCancelAlarm(json_rpc.Parameters args) {
  final id = (args.asMap)['id'];
  linux_alarm_manager.cancel(id);
}

void _handleScheduleAlarm(json_rpc.Parameters args) async {
  linux_alarm_manager.scheduleNextNotification();

  // Schedule is called when we join, pause, un-pause, and leave experiments.
  // Configure app loggers appropriately here
  final storageDir = DartFileStorage.getLocalStorageDir().path;
  final sharedPrefs = TaqoSharedPrefs(storageDir);
  final experiments = await readJoinedExperiments();
  bool active = false;
  for (var e in experiments) {
    final paused = await sharedPrefs.getBool("${_sharedPrefsExperimentPauseKey}_${e.id}");
    if (!e.isOver() && !(paused ?? false)) {
      active = true;
    }
  }

  if (active) {
    // Found a non-paused experiment
    AppLogger().start();
    CmdLineLogger().start();
  } else {
    AppLogger().stop();
    CmdLineLogger().stop();
  }
}

void main() async {
  // Monitor DBus for notification actions
  dbus.monitor();

  // Open a Socket for alarm scheduling
  ServerSocket.bind(localServerHost, localServerPort).then((serverSocket) {
    print('Listening');
    serverSocket.listen((socket) {
      print('Connected');

      _peer = json_rpc.Peer(SocketChannel(socket), onUnhandledError: (e, st) {
        print('linux_daemon socket error: $e');
      });

      _peer.registerMethod(scheduleAlarmMethod, _handleScheduleAlarm);
      _peer.registerMethod(cancelAlarmMethod, _handleCancelAlarm);
      _peer.listen();

      _peer.done.then((_) {
        print('linux_daemon client socket closed');
        _peer = null;
      });

      // Only allow one connection?
      //serverSocket.close();
    },
    onDone: () {
      print('linux_daemon server socket closed');
      _peer = null;
    });
  });
}
