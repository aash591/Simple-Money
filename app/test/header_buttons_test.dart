import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/app_back_button.dart';
import 'package:simple_money/ui/components/more_popup_button.dart';
import 'package:simple_money/ui/components/search_field.dart';
import 'package:simple_money/ui/components/secondary_header.dart';
import 'package:simple_money/ui/components/tab_header.dart';

void main() {
  const width = 400.0;

  Future<void> pump(WidgetTester tester, Widget header) async {
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: header)));
  }

  Finder disc(Type button) => find.descendant(
    of: find.byType(button),
    matching: find.byType(AnimatedContainer),
  );

  testWidgets('back and search discs are the same distance from each edge', (
    tester,
  ) async {
    await pump(
      tester,
      SecondaryHeader(
        title: 'Categories',
        leading: const AppBackButton(),
        actions: [AppSearchButton(onPressed: () {})],
      ),
    );
    final back = tester.getRect(disc(AppBackButton));
    final search = tester.getRect(disc(AppSearchButton));
    expect(back.size, const Size.square(GlassCircleButton.size));
    expect(search.size, const Size.square(GlassCircleButton.size));
    expect(back.left, TabHeader.sideMargin);
    expect(width - search.right, back.left);
  });

  testWidgets('a menu at the end of a header keeps the same margin', (
    tester,
  ) async {
    await pump(
      tester,
      SecondaryHeader(
        title: 'Account',
        leading: const AppBackButton(),
        actions: [
          MorePopupButton<int>(
            items: const [MorePopupItem(value: 1, label: 'One')],
            onSelected: (_) {},
          ),
        ],
      ),
    );
    final more = tester.getRect(find.byType(AnimatedContainer).last);
    expect(width - more.right, TabHeader.sideMargin);
  });

  testWidgets('a tab header ends its last disc on the page margin', (
    tester,
  ) async {
    var searched = 0;
    await pump(
      tester,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: TabHeader.sideMargin),
        child: TabHeader(
          title: 'Transactions',
          roundActions: true,
          actions: [AppSearchButton(onPressed: () => searched++)],
        ),
      ),
    );
    final search = tester.getRect(disc(AppSearchButton));
    expect(width - search.right, TabHeader.sideMargin);
    await tester.tapAt(search.center);
    expect(searched, 1);
  });

  testWidgets(
    'the discs match the search bar: height, and the line they sit on',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      Widget header({required bool searching}) => SearchableHeader(
        searching: searching,
        controller: controller,
        onChanged: (_) {},
        onCancel: () {},
        hintText: 'Search',
        header: SecondaryHeader(
          title: 'Categories',
          leading: const AppBackButton(),
          actions: [AppSearchButton(onPressed: () {})],
        ),
      );
      await pump(tester, header(searching: false));
      final disc = tester.getRect(find.byType(AnimatedContainer).first);
      expect(disc.height, SearchField.height);
      await pump(tester, header(searching: true));
      await tester.pumpAndSettle();
      final field = tester.getRect(find.byType(SearchField));
      expect(field.height, SearchField.height);
      expect(field.center.dy, disc.center.dy);
      expect(field.left, TabHeader.sideMargin);
    },
  );
}
