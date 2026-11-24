import 'package:material_ui/material_ui.dart';

import 'plan_controller.dart';

String planDayLabel(DateTime day) => '${day.year}年${day.month}月${day.day}日';

Future<DateTime?> pickPlanDay(BuildContext context, DateTime? day) async {
  final selected = await showDatePicker(
    context: context,
    initialDate: day ?? planDay(DateTime.now()),
    firstDate: DateTime(1),
    lastDate: DateTime(9999, 12, 31),
  );
  return selected == null ? null : planDay(selected);
}
