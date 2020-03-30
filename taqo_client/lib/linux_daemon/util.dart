import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/experiment.dart';
import '../storage/dart_file_storage.dart';

Future<List<Experiment>> readJoinedExperiments() async {
  try {
    final file = await File('${DartFileStorage.getLocalStorageDir().path}/experiments.txt');
    if (await file.exists()) {
      String contents = await file.readAsString();
      List experimentList = jsonDecode(contents);
      var experiments = List<Experiment>();
      for (var experimentJson in experimentList) {
        var experiment = Experiment.fromJson(experimentJson);
        experiments.add(experiment);
      }
      return experiments;
    }
    print("joined experiment file does not exist or is corrupted");
    return [];
  } catch (e) {
    print("Error loading joined experiments file: $e");
    return [];
  }
}
