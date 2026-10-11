import 'dart:async';

import 'package:echoes/core/theme/app_theme.dart';
import 'package:echoes/core/design/echo_design.dart';
import 'package:echoes/core/navigation/route_return.dart';
import 'package:echoes/data/models/song.dart';
import 'package:echoes/providers/api_provider.dart';
import 'package:echoes/providers/navigation_provider.dart';
import 'package:echoes/providers/player_provider.dart';
import 'package:echoes/widgets/main_scaffold.dart';
import 'package:echoes/widgets/echo_app_shell/echo_network_status_bar.dart';
import 'package:echoes/widgets/song_list_item.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../features/player/test_player_notifier.dart';

void main() {
  group('MainScaffold back decision', () {
    test('keeps the established five-level priority', () {
      expect(
        resolveEchoBackAction(
          drawerOpen: true,
          rootCanPop: true,
          branchCanPop: true,
          currentBranchIndex: libraryBranchIndex,
        ),
        EchoBackAction.closeDrawer,
      );
      expect(
        resolveEchoBackAction(
          drawerOpen: false,
          rootCanPop: true,
          branchCanPop: true,
          currentBranchIndex: libraryBranchIndex,
        ),
        EchoBackAction.popRootNavigator,
      );
      expect(
        resolveEchoBackAction(
          drawerOpen: false,
          rootCanPop: false,
          branchCanPop: true,
          currentBranchIndex: libraryBranchIndex,
        ),
        EchoBackAction.popBranchNavigator,
      );
      expect(
        resolveEchoBackAction(
          drawerOpen: false,
          rootCanPop: false,
          branchCanPop: false,
          currentBranchIndex: libraryBranchIndex,
        ),
        EchoBackAction.switchToDiscover,
      );
      expect(
        resolveEchoBackAction(
          drawerOpen: false,
          rootCanPop: false,
          branchCanPop: false,
          currentBranchIndex: discoverBranchIndex,
        ),
        EchoBackAction.moveAppToBackground,
      );
    });
  });

  group('MainScaffold destination mapping', () {
    testWidgets('page drawer trigger is compact-only', (tester) async {
      Future<void> pumpAtWidth(double width) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => Text(
                shouldShowPageDrawerTrigger(context) ? 'compact' : 'wide',
              ),
            ),
          ),
        );
        await tester.pump();
      }

      addTearDown(tester.view.reset);
      await pumpAtWidth(599);
      expect(find.text('compact'), findsOneWidget);

      await pumpAtWidth(600);
      expect(find.text('wide'), findsOneWidget);
    });

    testWidgets('expanded page headings use the shared back toolbar', (
      tester,
    ) async {
      Future<void> pumpAtWidth(double width) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: EchoTopBar.back(context: context, title: '全部歌曲'),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      addTearDown(tester.view.reset);
      await pumpAtWidth(1440);
      expect(
        tester.widget<EchoTopBar>(find.byType(EchoTopBar)).leading,
        isNull,
      );

      await pumpAtWidth(390);
      expect(
        tester.widget<EchoTopBar>(find.byType(EchoTopBar)).leading,
        isA<EchoIconButton>(),
      );
    });

    test(
      'desktop minimum width keeps the expanded navigation shell active',
      () {
        expect(
          echoDesktopMinimumWindowWidth,
          greaterThanOrEqualTo(EchoBreakpoints.standard.expanded),
        );
      },
    );

    test('keeps fixed branch indices while Explore is dynamically visible', () {
      expect(
        echoMainDestinations(
          showExploreTab: true,
        ).map((destination) => destination.branchIndex),
        <int>[
          discoverBranchIndex,
          exploreBranchIndex,
          libraryBranchIndex,
          catalogBranchIndex,
        ],
      );
      expect(
        echoMainDestinations(
          showExploreTab: false,
        ).map((destination) => destination.branchIndex),
        <int>[discoverBranchIndex, libraryBranchIndex, catalogBranchIndex],
      );
    });

    testWidgets('catalog stack survives tab switches with Explore hidden', (
      tester,
    ) async {
      final harness = await _pumpMainScaffold(tester);
      harness.showExplore.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('曲库'));
      await tester.pumpAndSettle();
      expect(find.text('Catalog root'), findsOneWidget);
      expect(
        harness.container.read(currentVisibleBranchIndexProvider),
        catalogBranchIndex,
      );
      harness.router.go('/catalog/detail');
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('我的'));
      await tester.pumpAndSettle();
      expect(find.text('Library root'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('曲库'));
      await tester.pumpAndSettle();
      expect(find.text('Catalog detail'), findsOneWidget);
      harness.showExplore.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Catalog detail'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Catalog root'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Home root'), findsOneWidget);
    });

    testWidgets('desktop sidebar exposes the requested grouped destinations', (
      tester,
    ) async {
      await _pumpMainScaffold(tester, size: const Size(1440, 900));

      expect(find.text('Desktop Music Flow'), findsOneWidget);

      for (final label in <String>[
        '发现',
        '音乐流',
        '搜索',
        '资料库',
        '全部歌曲',
        '歌手',
        '专辑',
        '个人收藏',
        '收藏歌曲',
        '收藏专辑',
        '收藏歌手',
        '我的歌单',
        '管理',
        '下载管理',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
      }
      expect(find.text('离线下载'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('设置'),
        120,
        scrollable: find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('echo-expanded-navigation'),
              ),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('设置'), findsOneWidget);
      expect(find.bySemanticsLabel('我的'), findsNothing);
      expect(find.bySemanticsLabel('曲库'), findsNothing);
    });

    testWidgets(
      'desktop sidebar replaces primary destinations and back returns to Music Flow',
      (tester) async {
        await _pumpMainScaffold(tester, size: const Size(1440, 900));

        await tester.tap(
          find.byKey(const ValueKey<String>('echo-desktop-sidebar-songs')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Desktop songs'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('echo-desktop-sidebar-artists')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Desktop artists'), findsOneWidget);
        expect(find.text('Desktop songs'), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey<String>('echo-desktop-sidebar-songs')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Desktop songs'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Desktop Music Flow'), findsOneWidget);
        expect(find.text('Desktop songs'), findsNothing);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Desktop Music Flow'), findsOneWidget);
      },
    );

    testWidgets('desktop Settings is a sidebar route with working back', (
      tester,
    ) async {
      await _pumpMainScaffold(tester, size: const Size(1440, 900));

      final sidebar = find.byKey(
        const ValueKey<String>('echo-expanded-navigation'),
      );
      final settings = find.byKey(
        const ValueKey<String>('echo-desktop-sidebar-settings'),
      );
      await tester.scrollUntilVisible(
        settings,
        120,
        scrollable: find
            .descendant(of: sidebar, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(settings);
      await tester.pumpAndSettle();

      expect(find.text('Desktop settings'), findsOneWidget);
      expect(
        tester
            .widget<EchoIconButton>(
              find.byKey(const ValueKey<String>('echo-desktop-back')),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(const ValueKey<String>('echo-desktop-back')));
      await tester.pumpAndSettle();

      expect(find.text('Desktop Music Flow'), findsOneWidget);
      expect(find.text('Desktop settings'), findsNothing);
    });

    testWidgets('desktop detail routes share the global back stack', (
      tester,
    ) async {
      await _pumpMainScaffold(tester, size: const Size(1440, 900));

      await tester.tap(
        find.byKey(const ValueKey<String>('echo-desktop-sidebar-songs')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('open-desktop-detail')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Desktop detail'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Desktop songs'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('echo-desktop-navigation-toolbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('echo-desktop-forward')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('echo-desktop-forward')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Desktop detail'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Desktop songs'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Desktop Music Flow'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('echo-desktop-sidebar-music-flow')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EchoIconButton>(
              find.byKey(const ValueKey<String>('echo-desktop-forward')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'desktop multi-level detail history restores in order and fresh navigation clears forward',
      (tester) async {
        await _pumpMainScaffold(tester, size: const Size(1440, 900));

        await tester.tap(
          find.byKey(const ValueKey<String>('echo-desktop-sidebar-songs')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('open-desktop-detail')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('open-desktop-nested-detail')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Desktop nested detail'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Desktop detail'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Desktop songs'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('echo-desktop-forward')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Desktop detail'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('echo-desktop-forward')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Desktop nested detail'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Desktop songs'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('open-desktop-detail')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Desktop detail'), findsOneWidget);
        expect(
          tester
              .widget<EchoIconButton>(
                find.byKey(const ValueKey<String>('echo-desktop-forward')),
              )
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets(
      'desktop entity deletion return discards stale forward history',
      (tester) async {
        await _pumpMainScaffold(tester, size: const Size(1440, 900));

        await tester.tap(
          find.byKey(const ValueKey<String>('echo-desktop-sidebar-songs')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('open-desktop-detail')),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey<String>('delete-desktop-detail')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Desktop songs'), findsOneWidget);
        expect(
          tester
              .widget<EchoIconButton>(
                find.byKey(const ValueKey<String>('echo-desktop-forward')),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'desktop workspace keeps queue state when returning to browse',
      (tester) async {
        final songs = <Song>[
          Song(id: 'workspace-first', title: 'Workspace first'),
          Song(id: 'workspace-second', title: 'Workspace second'),
        ];
        await _pumpMainScaffold(
          tester,
          size: const Size(1440, 900),
          showDesktopPlayer: true,
          playerState: PlayerState(
            currentSong: songs.first,
            queue: songs,
            currentIndex: 0,
          ),
        );

        await tester.tap(find.bySemanticsLabel('打开歌词'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '播放队列'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Workspace second'));
        await tester.pumpAndSettle();

        Finder secondRow() => find.ancestor(
          of: find.text('Workspace second'),
          matching: find.byType(EchoSongRow),
        );
        expect(tester.widget<EchoSongRow>(secondRow()).selected, isTrue);

        await tester.tap(find.bySemanticsLabel('返回浏览'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('echo-desktop-player-workspace')),
          findsNothing,
        );

        await tester.tap(find.bySemanticsLabel('打开播放队列'));
        await tester.pumpAndSettle();

        expect(tester.widget<EchoSongRow>(secondRow()).selected, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'wide Android shell does not expose native fullscreen controls',
      (tester) async {
        final song = Song(id: 'wide-android-song', title: 'Wide Android song');
        await _pumpMainScaffold(
          tester,
          size: const Size(1440, 900),
          showDesktopPlayer: true,
          playerState: PlayerState(
            currentSong: song,
            queue: <Song>[song],
            currentIndex: 0,
          ),
        );

        await tester.tap(find.bySemanticsLabel('打开歌词'));
        await tester.pumpAndSettle();

        expect(find.bySemanticsLabel('进入全屏'), findsNothing);
        expect(find.bySemanticsLabel('退出全屏'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('Windows fullscreen toggle exits without native events', (
      tester,
    ) async {
      const channel = MethodChannel('window_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final requests = <bool>[];
      final pendingEnter = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setFullScreen') {
          requests.add(
            (call.arguments! as Map<Object?, Object?>)['isFullScreen']! as bool,
          );
          if (requests.length == 1) await pendingEnter.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final song = Song(id: 'windows-fullscreen', title: 'Windows fullscreen');
      await _pumpMainScaffold(
        tester,
        size: const Size(1440, 900),
        showDesktopPlayer: true,
        playerState: PlayerState(currentSong: song, queue: [song]),
      );
      await tester.tap(find.bySemanticsLabel('打开歌词'));
      await tester.pumpAndSettle();

      for (var cycle = 0; cycle < 2; cycle++) {
        await tester.tap(find.bySemanticsLabel('进入全屏'));
        if (cycle == 0) {
          await tester.pump();
          await tester.tap(find.bySemanticsLabel('进入全屏'));
          expect(requests, [true]);
          pendingEnter.complete();
        }
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('退出全屏'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('退出全屏'));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('进入全屏'), findsOneWidget);
      }
      await tester.tap(find.bySemanticsLabel('进入全屏'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(requests, [true, false, true, false, true, false]);
      expect(find.bySemanticsLabel('进入全屏'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('echo-desktop-player-workspace')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Escape exits fullscreen before closing the player workspace', (
      tester,
    ) async {
      const channel = MethodChannel('window_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final fullScreenRequests = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setFullScreen') {
          fullScreenRequests.add(
            (call.arguments! as Map<Object?, Object?>)['isFullScreen']! as bool,
          );
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final song = Song(id: 'fullscreen-escape-song', title: 'Escape song');
      await _pumpMainScaffold(
        tester,
        size: const Size(1440, 900),
        showDesktopPlayer: true,
        playerState: PlayerState(
          currentSong: song,
          queue: <Song>[song],
          currentIndex: 0,
        ),
      );
      await tester.tap(find.bySemanticsLabel('打开歌词'));
      await tester.pumpAndSettle();

      final enterFullScreen = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', <String, Object>{
          'eventName': 'enter-full-screen',
        }),
      );
      await messenger.handlePlatformMessage(
        channel.name,
        enterFullScreen,
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('退出全屏'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final leaveFullScreen = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', <String, Object>{
          'eventName': 'leave-full-screen',
        }),
      );
      await messenger.handlePlatformMessage(
        channel.name,
        leaveFullScreen,
        (_) {},
      );
      await tester.pumpAndSettle();

      expect(fullScreenRequests, <bool>[false]);
      expect(
        find.byKey(const ValueKey<String>('echo-desktop-player-workspace')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('进入全屏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('desktop forward restores a detail page scroll position', (
      tester,
    ) async {
      await _pumpMainScaffold(tester, size: const Size(1440, 900));

      await tester.tap(
        find.byKey(const ValueKey<String>('echo-desktop-sidebar-songs')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('open-desktop-scroll-detail')),
      );
      await tester.pumpAndSettle();

      final list = find.byKey(
        const ValueKey<String>('desktop-forward-detail-list'),
      );
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final before = tester
          .state<ScrollableState>(scrollable.first)
          .position
          .pixels;
      expect(before, greaterThan(0));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('echo-desktop-forward')),
      );
      await tester.pumpAndSettle();

      final restoredList = find.byKey(
        const ValueKey<String>('desktop-forward-detail-list'),
      );
      final restoredScrollable = find.descendant(
        of: restoredList,
        matching: find.byType(Scrollable),
      );
      final after = tester
          .state<ScrollableState>(restoredScrollable.first)
          .position
          .pixels;
      expect(after, closeTo(before, 1));
    });

    testWidgets('desktop shortcuts respect text entry and Escape route order', (
      tester,
    ) async {
      await _pumpMainScaffold(tester, size: const Size(1440, 900));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Desktop search'), findsOneWidget);

      final searchField = find.byKey(
        const ValueKey<String>('desktop-search-input'),
      );
      await tester.tap(searchField);
      await tester.enterText(searchField, 'find me');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: searchField,
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        'find me',
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('open-desktop-detail')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Desktop detail'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Desktop search'), findsOneWidget);
    });

    testWidgets('preserves branch stacks and resets a reselected branch', (
      tester,
    ) async {
      final harness = await _pumpMainScaffold(tester);

      harness.router.go('/home/detail');
      await tester.pumpAndSettle();
      expect(find.text('Home detail'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('我的'));
      await tester.pumpAndSettle();
      expect(find.text('Library root'), findsOneWidget);
      expect(
        harness.container.read(currentVisibleBranchIndexProvider),
        libraryBranchIndex,
      );

      await tester.tap(find.bySemanticsLabel('音乐流'));
      await tester.pumpAndSettle();
      expect(find.text('Home detail'), findsOneWidget);
      expect(
        harness.container.read(currentVisibleBranchIndexProvider),
        discoverBranchIndex,
      );

      await tester.tap(find.bySemanticsLabel('音乐流'));
      await tester.pumpAndSettle();
      expect(find.text('Home root'), findsOneWidget);
      expect(find.text('Home detail'), findsNothing);
    });

    testWidgets(
      'hiding active Explore falls back to Home and syncs visibility',
      (tester) async {
        final harness = await _pumpMainScaffold(tester);

        await tester.tap(find.bySemanticsLabel('探索'));
        await tester.pumpAndSettle();
        expect(find.text('Explore root'), findsOneWidget);
        expect(
          harness.container.read(currentVisibleBranchIndexProvider),
          exploreBranchIndex,
        );

        harness.router.go('/explore/detail');
        await tester.pumpAndSettle();
        expect(find.text('Explore detail'), findsOneWidget);

        harness.showExplore.value = false;
        await tester.pumpAndSettle();

        expect(find.text('Home root'), findsOneWidget);
        expect(find.bySemanticsLabel('探索'), findsNothing);
        expect(
          harness.container.read(currentVisibleBranchIndexProvider),
          discoverBranchIndex,
        );

        harness.showExplore.value = true;
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('探索'));
        await tester.pumpAndSettle();
        expect(find.text('Explore detail'), findsOneWidget);
        expect(
          harness.container.read(currentVisibleBranchIndexProvider),
          exploreBranchIndex,
        );
      },
    );
  });
}

Future<_MainScaffoldHarness> _pumpMainScaffold(
  WidgetTester tester, {
  Size size = const Size(390, 800),
  bool showDesktopPlayer = false,
  PlayerState? playerState,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: <Override>[
      networkManagerProvider.overrideWith((ref) {}),
      if (playerState != null)
        playerProvider.overrideWith((ref) => TestPlayerNotifier(playerState)),
    ],
  );
  addTearDown(container.dispose);
  final showExplore = ValueNotifier<bool>(true);
  addTearDown(showExplore.dispose);
  final branchNavigatorKeys = <GlobalKey<NavigatorState>>[
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
  ];

  final router = GoRouter(
    initialLocation: '/home',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return ValueListenableBuilder<bool>(
            valueListenable: showExplore,
            builder: (context, showExploreTab, child) {
              return MainScaffold(
                navigationShell: navigationShell,
                branchNavigatorKeys: branchNavigatorKeys,
                showExploreTabOverride: showExploreTab,
                showMiniPlayerOverride: showDesktopPlayer,
                networkStatusOverride: EchoNetworkStatus.online,
                drawerOverride: const SizedBox(width: 320),
                miniPlayerOverride: showDesktopPlayer
                    ? null
                    : const SizedBox(height: 72),
                desktopRootOverride: const _BranchPage('Desktop Music Flow'),
                desktopPageBuilderOverride: (destinationId) =>
                    _DesktopDestinationPage(destinationId: destinationId),
              );
            },
          );
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[discoverBranchIndex],
            routes: <RouteBase>[
              GoRoute(
                path: '/home',
                builder: (context, state) => const _BranchPage('Home root'),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'detail',
                    builder: (context, state) =>
                        const _BranchPage('Home detail'),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[exploreBranchIndex],
            routes: <RouteBase>[
              GoRoute(
                path: '/explore',
                builder: (context, state) => const _BranchPage('Explore root'),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'detail',
                    builder: (context, state) =>
                        const _BranchPage('Explore detail'),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[libraryBranchIndex],
            routes: <RouteBase>[
              GoRoute(
                path: '/library',
                builder: (context, state) => const _BranchPage('Library root'),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: branchNavigatorKeys[catalogBranchIndex],
            routes: <RouteBase>[
              GoRoute(
                path: '/catalog',
                builder: (context, state) => const _BranchPage('Catalog root'),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'detail',
                    builder: (context, state) =>
                        const _BranchPage('Catalog detail'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  return _MainScaffoldHarness(
    router: router,
    container: container,
    showExplore: showExplore,
  );
}

class _MainScaffoldHarness {
  const _MainScaffoldHarness({
    required this.router,
    required this.container,
    required this.showExplore,
  });

  final GoRouter router;
  final ProviderContainer container;
  final ValueNotifier<bool> showExplore;
}

class _BranchPage extends StatelessWidget {
  const _BranchPage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}

class _DesktopDestinationPage extends StatelessWidget {
  const _DesktopDestinationPage({required this.destinationId});

  final String destinationId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('Desktop $destinationId'),
            if (destinationId == 'search')
              const TextField(key: ValueKey<String>('desktop-search-input')),
            ElevatedButton(
              key: const ValueKey<String>('open-desktop-detail'),
              onPressed: () => Navigator.of(context).push<void>(
                EchoPageRoute<void>(
                  context: context,
                  builder: (detailContext) => Scaffold(
                    body: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Text('Desktop detail'),
                          ElevatedButton(
                            key: const ValueKey<String>(
                              'open-desktop-nested-detail',
                            ),
                            onPressed: () =>
                                Navigator.of(detailContext).push<void>(
                                  EchoPageRoute<void>(
                                    context: detailContext,
                                    builder: (_) => const Scaffold(
                                      body: Center(
                                        child: Text('Desktop nested detail'),
                                      ),
                                    ),
                                  ),
                                ),
                            child: const Text('Open nested detail'),
                          ),
                          ElevatedButton(
                            key: const ValueKey<String>(
                              'delete-desktop-detail',
                            ),
                            onPressed: () =>
                                popCurrentRouteAndDiscardForwardOrGoHome(
                                  detailContext,
                                ),
                            child: const Text('Delete detail'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('Open detail'),
            ),
            if (destinationId == 'songs')
              ElevatedButton(
                key: const ValueKey<String>('open-desktop-scroll-detail'),
                onPressed: () => Navigator.of(context).push<void>(
                  EchoPageRoute<void>(
                    context: context,
                    builder: (_) => Scaffold(
                      body: ListView.builder(
                        key: const ValueKey<String>(
                          'desktop-forward-detail-list',
                        ),
                        itemCount: 60,
                        itemBuilder: (context, index) =>
                            ListTile(title: Text('Forward detail row $index')),
                      ),
                    ),
                  ),
                ),
                child: const Text('Open scroll detail'),
              ),
          ],
        ),
      ),
    );
  }
}
