import 'package:flutter_test/flutter_test.dart';
import 'package:ripple_app/features/notifications/notification_model.dart';

void main() {
  test('model settings accept HTTPS and reject embedded credentials', () {
    expect(
      NotificationModel.parseUrl('https://model.example/v1/')?.path,
      '/v1',
    );
    expect(NotificationModel.parseUrl('http://model.example'), isNull);
    expect(NotificationModel.parseUrl('https://user@model.example'), isNull);
    expect(
      NotificationModel.parseUrl('https://model.example?api_key=secret'),
      isNull,
    );
  });
}
