import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';

void main() {
  test('fork links and update API never download upstream releases', () {
    expect(Constants.appName, 'PiliBoost');
    expect(Constants.sourceCodeUrl, 'https://github.com/jyh9521/PiliBoost');
    expect(
      Api.latestApp,
      'https://api.github.com/repos/jyh9521/PiliBoost/releases',
    );
  });
  test('version and Android release identity stay consistent', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 0.1.0+2'),
    );
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(
      gradle,
      contains('variant.applicationId.set(releaseId)'),
    );
    expect(gradle, contains('applicationIdSuffix = ".debug"'));
    expect(gradle, isNot(contains('config ?: signingConfigs["debug"]')));
    expect(
      File('android/app/src/main/res/values/string.xml').readAsStringSync(),
      contains('>PiliBoost<'),
    );
  });
  for (final readme in ['README.md', 'README.en.md']) {
    test(
      '$readme documents current modes, fork release and test boundaries',
      () {
        final text = File(readme).readAsStringSync();
        expect(text, contains('0.1.0+2'));
        expect(text, contains('Multi-CDN Auto'));
        expect(text, contains('Multi-Range Auto'));
        expect(text, contains('OFF/ON'));
        expect(text, contains('com.jyh9521.piliboost'));
        expect(text, contains('https://github.com/jyh9521/PiliBoost/releases'));
        expect(text, isNot(contains('experimental V1a')));
        expect(text, isNot(contains('实验性 V1a')));
        expect(text, contains('https://github.com/bggRGjQaUbCoE/PiliPlus'));
      },
    );
  }
  test('release builder requires key and generates version metadata', () {
    final text = File('tool/phase1/build_android_release.ps1')
        .readAsStringSync();
    expect(text, contains('Release signing configuration required.'));
    expect(text, contains('build apk --release --no-pub'));
    expect(text, contains('pili.hash'));
    expect(text, contains('verify_android_apk.py'));
    final review = File('.github/workflows/upstream-review.yml')
        .readAsStringSync();
    expect(review, contains('contents: read'));
    expect(review, isNot(contains('git push')));
    expect(review, isNot(contains('git merge --')));
  });
}
