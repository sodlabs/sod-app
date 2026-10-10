import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/gfp/gfp_health_monitor.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('unchanged candidate results never re-publish health state', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var changes = 0;
    container.listen(gfpVerifiedTagsProvider, (_, _) => changes++);
    final notifier = container.read(gfpVerifiedTagsProvider.notifier);
    notifier.update({});
    notifier.update({});
    notifier.update({'first'});
    notifier.update({'first'});
    notifier.update({'first', 'second'});
    notifier.update(null);
    notifier.update(null);
    expect(changes, 4);
  });
}
