// This file deliberately imports the deprecated `package:flutter/material.dart`
// (aliased as `legacy`) so that the rest of the app can stay on
// `package:material_ui/material_ui.dart` without triggering
// `deprecated_member_use`. It is the single, intentional compatibility seam
// for dependencies (e.g. `flutter_spiffing`'s XEP-0258 label editor) that
// haven't migrated to `package:material_ui` yet and still require a legacy
// `Material` ancestor (for `debugCheckHasMaterial`/ink effects), not just a
// legacy `Theme`/`MaterialLocalizations`.
// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart' as legacy;
import 'package:material_ui/material_ui.dart';

/// Wraps [child] with a transparent legacy [legacy.Material] ancestor on top
/// of [MaterialUiCompatibilityBridge], so legacy-Material widgets (such as
/// `ChoiceChip` from `flutter_spiffing`) can resolve both `Theme.of`/
/// `MaterialLocalizations.of` and `debugCheckHasMaterial` while still living
/// inside an app whose root is `material_ui`'s [MaterialApp].
///
/// Remove this once every dependency has migrated to `package:material_ui`.
class LegacyMaterialBridge extends StatelessWidget {
  const LegacyMaterialBridge({super.key, required this.child, this.delegates});

  final Widget child;

  /// Forwarded to [MaterialUiCompatibilityBridge.delegates]. Leave `null` to
  /// use its default (global Cupertino/Material/Widgets) delegates; pass an
  /// explicit (possibly empty) list to avoid merging in delegates that would
  /// make resource loading asynchronous for a given ambient locale (see
  /// callers in `test/security_label_editor_test.dart`).
  final List<LocalizationsDelegate<dynamic>>? delegates;

  @override
  Widget build(BuildContext context) {
    return MaterialUiCompatibilityBridge(
      delegates: delegates,
      child: legacy.Material(type: legacy.MaterialType.transparency, child: child),
    );
  }
}
