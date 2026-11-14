import 'package:sky_ui_ops/src/features/engines/amnezia.dart';
import 'package:test/test.dart';

void main() {
  test('legacy nft table text confirms only the exact owned table comment', () {
    expect(
      awgTableOwnershipText(
        'table ip sky_ui_node_awg {\n\tcomment "Managed by Sky UI"\n\tchain example {}\n}\n',
        'sky_ui_node_awg',
      ),
      isTrue,
    );
    expect(
      awgTableOwnershipText(
        'table ip sky_ui_awg {\n\tchain example { comment "Managed by Sky UI"; }\n}\n',
        'sky_ui_awg',
      ),
      isFalse,
    );
    expect(
      awgTableOwnershipText(
        'table ip unrelated {\n\tcomment "Managed by Sky UI"\n}\n',
        'sky_ui_awg',
      ),
      isFalse,
    );
    expect(
      awgTableOwnershipText(
        'table ip sky_ui_awg {\n\tcomment "Managed by someone else"\n}\n',
        'sky_ui_awg',
      ),
      isFalse,
    );
  });
}
