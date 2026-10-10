import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/adaptive/adaptive_presenter.dart';
import 'package:nai_launcher/data/models/prompt_assistant/prompt_assistant_models.dart';
import 'package:nai_launcher/presentation/screens/settings/sections/model_services/provider_model_form.dart';
import 'package:nai_launcher/presentation/screens/settings/widgets/prompt_assistant_settings_forms.dart';

const _provider = ProviderConfig(
  id: 'meifan',
  name: '美饭',
  baseUrl: 'https://sub.mathhomework.top/v1beta',
  allowImageInput: true,
);

Widget _launcher({
  required Future<void> Function(BuildContext context) open,
  double textScale = 1,
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => FilledButton(
        onPressed: () => unawaited(open(context)),
        child: const Text('打开'),
      ),
    ),
  ),
);

Future<void> _openModelForm(BuildContext context) =>
    AdaptivePresenter.showForm<ProviderModelFormResult>(
      context: context,
      dialogWidth: 480,
      title: '手动添加',
      builder: (context, scrollController) => ProviderModelForm(
        provider: _provider,
        existingIds: const {},
        scrollController: scrollController,
      ),
    );

Future<void> _openProviderForm(
  BuildContext context,
  ProviderConfig? provider,
) => AdaptivePresenter.showForm<PromptAssistantProviderFormResult>(
  context: context,
  dialogWidth: 520,
  title: '服务商',
  builder: (context, scrollController) => PromptAssistantProviderForm(
    provider: provider,
    scrollController: scrollController,
  ),
);

void main() {
  testWidgets('模型表单在桌面按内容高度呈现', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(610, 1025);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_launcher(open: _openModelForm));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('adaptive-centered-form'));
    expect(surface, findsOneWidget);
    expect(tester.getSize(surface).height, lessThan(480));
    expect(find.text('保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型表单内容受限时滚动且操作区保持可见', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 500);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_launcher(open: _openModelForm, textScale: 3));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('adaptive-centered-form'));
    final save = find.text('保存');
    expect(surface, findsOneWidget);
    expect(save, findsOneWidget);
    expect(
      tester.getBottomRight(save).dy,
      lessThanOrEqualTo(tester.getBottomRight(surface).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型表单拒绝空 ID 和重复 ID', (tester) async {
    ProviderModelFormResult? result;
    await tester.pumpWidget(
      _launcher(
        open: (context) async {
          result = await AdaptivePresenter.showForm<ProviderModelFormResult>(
            context: context,
            title: '手动添加',
            builder: (context, scrollController) => ProviderModelForm(
              provider: _provider,
              existingIds: const {'gpt-4o'},
              scrollController: scrollController,
            ),
          );
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入模型 ID'), findsOneWidget);

    final idField = find.byKey(const ValueKey('model-services-model-id'));
    await tester.enterText(idField, 'gpt-4o');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('这个服务商已经有这个模型'), findsOneWidget);

    await tester.enterText(idField, '  my-model  ');
    await tester.enterText(
      find.byKey(const ValueKey('model-services-model-display-name')),
      '我的模型',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, (id: 'my-model', displayName: '我的模型'));
  });

  testWidgets('编辑已有服务商时地址和密钥交给页内编辑，新建时仍可填写', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _launcher(open: (context) => _openProviderForm(context, _provider)),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('Base URL'), findsNothing);
    expect(find.text('API Key (留空不改)'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _launcher(open: (context) => _openProviderForm(context, null)),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('API Key (留空不改)'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
  });

  testWidgets(
    'Codex OAuth hides credentials and clears relay values on preset changes',
    (tester) async {
      PromptAssistantProviderFormResult? result;
      await tester.pumpWidget(
        _launcher(
          open: (context) async {
            result =
                await AdaptivePresenter.showForm<
                  PromptAssistantProviderFormResult
                >(
                  context: context,
                  title: '服务商',
                  builder: (context, scrollController) =>
                      PromptAssistantProviderForm(
                        scrollController: scrollController,
                      ),
                );
          },
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final preset = find.byKey(
        const ValueKey('prompt-assistant-provider-preset'),
      );
      final baseUrl = find.byKey(
        const ValueKey('prompt-assistant-provider-base-url'),
      );
      final apiKey = find.byKey(
        const ValueKey('prompt-assistant-provider-api-key'),
      );
      await tester.enterText(baseUrl, 'https://custom-relay.invalid/v1');
      await tester.enterText(apiKey, 'old-provider-api-key');
      tester.widget<DropdownButtonFormField<ProviderPreset>>(preset).onChanged!(
        ProviderPreset.codexOAuth,
      );
      await tester.pumpAndSettle();
      expect(baseUrl, findsNothing);
      expect(apiKey, findsNothing);
      expect(
        find.byKey(const ValueKey('codex-oauth-save-then-sign-in')),
        findsOneWidget,
      );

      tester.widget<DropdownButtonFormField<ProviderPreset>>(preset).onChanged!(
        ProviderPreset.openaiChat,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(baseUrl).controller!.text,
        ProviderPreset.openaiChat.defaultBaseUrl,
      );
      expect(tester.widget<TextField>(apiKey).controller!.text, isEmpty);

      tester.widget<DropdownButtonFormField<ProviderPreset>>(preset).onChanged!(
        ProviderPreset.codexOAuth,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result?.preset, ProviderPreset.codexOAuth);
      expect(result?.baseUrl, ProviderPreset.codexOAuth.defaultBaseUrl);
      expect(result?.apiKey, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 600.0, 840.0, 1180.0, 1600.0]) {
    testWidgets(
      'Codex provider form at $width and 3x keeps save/cancel accessible',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          _launcher(
            textScale: 3,
            open: (context) => _openProviderForm(
              context,
              ProviderPreset.codexOAuth.createConfig(),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('codex-oauth-save-then-sign-in')),
          findsOneWidget,
        );
        expect(find.text('Base URL'), findsNothing);
        expect(
          find.byKey(const ValueKey('prompt-assistant-provider-api-key')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('取消'));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byType(PromptAssistantProviderForm), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
