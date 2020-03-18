import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'survey/survey_page.dart';

class SurveyPickerPage extends StatefulWidget {
  static const routeName = '/survey_picker';

  SurveyPickerPage({Key key}) : super(key: key);

  @override
  _SurveyPickerPageState createState() => _SurveyPickerPageState();
}

class _SurveyPickerPageState extends State<SurveyPickerPage> {
  @override
  Widget build(BuildContext context) {
    final List<dynamic> args = ModalRoute.of(context).settings.arguments;
    final experiment = args[0];
    final selfReportTime = args.length > 1 ? args[1] : null;

    var rowChildren = <Widget>[
      buildPickSurveyPromptRow(experiment),
      Divider(
        height: 16.0,
        color: Colors.black,
      ),
    ];

    rowChildren.addAll(buildSurveyList(experiment, selfReportTime));

    return Scaffold(
      appBar: AppBar(
        title: Text(experiment.title + "Choose Survey"),
        backgroundColor: Colors.indigo,
      ),
      body: Container(
        padding: EdgeInsets.all(8.0),
        //margin: EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 0.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rowChildren,
        ),
      ),
    );
  }

  Widget buildPickSurveyPromptRow(experiment) {
    return Text(
      "Please pick the survey to respond",
      style: TextStyle(fontWeight: FontWeight.bold),
    );
  }

  List<Widget> buildSurveyList(experiment, selfReportTime) {
    List<Widget> widgets = [];
    for (var survey in experiment.getActiveSurveys()) {
      var rowChildren = <Widget>[
        Expanded(
            child: InkWell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(survey.name, textScaleFactor: 1.5),
            ],
          ),
          onTap: () {
            Navigator.pushNamed(context, SurveyPage.routeName,
                arguments: [experiment, survey.name, selfReportTime]);
          },
        )),
      ];

      widgets.add(Card(child: Row(children: rowChildren)));
    }
    return widgets;
  }
}
