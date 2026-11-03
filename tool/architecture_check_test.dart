import 'dart:io';

import 'check_architecture.dart';

void main() {
  final root = Directory.systemTemp.createTempSync('sky-ui-architecture-');
  void put(String path, String source) {
    File('${root.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);
  }

  void expect(bool value, String message) {
    if (!value) throw StateError(message);
  }

  try {
    put('app/shared/lib/sky_ui_shared.dart', 'class Model {}');
    put(
      'app/web/lib/src/shared/model.dart',
      "import 'package:sky_ui_shared/sky_ui_shared.dart';",
    );
    put('app/web/lib/src/features/view.dart', "import '../shared/model.dart';");
    expect(
      checkArchitecture(root).isEmpty,
      'Valid feature/shared dependencies rejected.',
    );
    put('app/shared/lib/sky_ui_shared.dart', "import 'dart:io';");
    expect(
      checkArchitecture(root).any((e) => e.contains('portable')),
      'Native shared import escaped the guard.',
    );
    put('app/shared/lib/sky_ui_shared.dart', 'class Model {}');
    put('app/web/lib/src/shared/model.dart', "import '../features/view.dart';");
    final cycle = checkArchitecture(root);
    expect(
      cycle.any((e) => e.contains('shared UI')),
      'An upward feature dependency escaped the guard.',
    );
    expect(
      cycle.any((e) => e.contains('Dependency cycle')),
      'A cycle escaped the guard.',
    );
    put('app/web/lib/src/shared/model.dart', "import 'missing.dart';");
    expect(
      checkArchitecture(root).any((e) => e.contains('missing production')),
      'A broken move escaped the guard.',
    );
    put(
      'app/web/lib/src/shared/model.dart',
      "import 'package:sky_ui_shared/sky_ui_shared.dart' if (dart.library.io) '../features/view.dart';",
    );
    expect(
      checkArchitecture(root).any((e) => e.contains('shared UI')),
      'A conditional upward dependency escaped the guard.',
    );
    put('app/api/lib/src/infrastructure/database.dart', 'class Database {}');
    put(
      'app/api/lib/src/application/use_case.dart',
      "import '../infrastructure/database.dart';",
    );
    expect(
      checkArchitecture(root)
          .any((e) => e.contains('inject an application contract')),
      'Infrastructure bypass escaped the guard.',
    );
    print('Architecture guard rejection cases passed.');
  } finally {
    final expectedParent = Directory.systemTemp.absolute.uri;
    if (root.absolute.parent.uri != expectedParent ||
        !root.uri.pathSegments
            .where((v) => v.isNotEmpty)
            .last
            .startsWith('sky-ui-architecture-')) {
      throw StateError('Refusing to remove an unexpected test directory.');
    }
    root.deleteSync(recursive: true);
  }
}
