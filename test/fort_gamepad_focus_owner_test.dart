import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';

class _Recorder {
  final List<String> events = [];

  void push(String id) {
    GamepadNavigationManager.pushLayer(
      id,
      onActivate: () => events.add('+$id'),
      onDeactivate: () => events.add('-$id'),
    );
  }

  void pop(String id) => GamepadNavigationManager.popLayer(id);
}

void main() {
  test('launch focus remembers and restores the active game view layer', () {
    for (final viewLayer in ['games_grid', 'games_carousel']) {
      final recorder = _Recorder();
      recorder.push('system_games_list');
      recorder.push(viewLayer);

      GamepadNavigationManager.rememberCurrentFocusOwner();
      GamepadNavigationManager.deactivateAll();

      // _freeMemoryForGameplay clears the games and disposes the child view.
      recorder.pop(viewLayer);

      // Returning from the emulator reloads the games and remounts that view.
      recorder.push(viewLayer);
      recorder.events.clear();

      GamepadNavigationManager.restoreFocusOwner();

      expect(
        recorder.events,
        ['+$viewLayer'],
        reason: '$viewLayer must own the controller again after game return',
      );

      recorder.pop(viewLayer);
      recorder.pop('system_games_list');
    }
  });

  test('list mode still restores the parent game-list layer', () {
    final recorder = _Recorder();
    recorder.push('system_games_list');

    GamepadNavigationManager.rememberCurrentFocusOwner();
    GamepadNavigationManager.deactivateAll();
    recorder.events.clear();

    GamepadNavigationManager.restoreFocusOwner();

    expect(recorder.events, ['+system_games_list']);

    recorder.pop('system_games_list');
  });
}
