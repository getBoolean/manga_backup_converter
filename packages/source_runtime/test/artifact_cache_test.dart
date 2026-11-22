@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

void main() {
  late Directory temp;
  late ArtifactCache cache;
  final bytes = Uint8List.fromList(utf8.encode('PK\u0003\u0004 pretend artifact'));
  final binding = ArtifactBinding(sha256: sha256.convert(bytes).toString(), kind: 'jar', version: '1');
  const profile = ArtifactProfile(producer: 'tachi-jar', converterVersion: '1', hostCompatibility: '1.5');

  setUp(() {
    temp = Directory.systemTemp.createTempSync('artifact_cache_test');
    cache = ArtifactCache(Directory(p.join(temp.path, 'cache')));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('rejects bytes that do not match the expected digest before verification', () async {
    var verified = false;
    await check(
      cache.admit(
        Uint8List.fromList(<int>[...bytes, 0]),
        binding: binding,
        profile: profile,
        verifier: (_, _) => verified = true,
      ),
    ).throws<ArtifactIntegrityException>();
    check(verified).isFalse();
  });

  test('a verifier rejection keeps the bytes out of the cache', () async {
    await check(
      cache.admit(
        bytes,
        binding: binding,
        profile: profile,
        verifier: (_, _) => throw const FormatException('untrusted'),
      ),
    ).throws<FormatException>();
    check(await cache.lookup(binding: binding, profile: profile, verifier: (_, _) {})).isNull();
  });

  test('two providers share one digest-bound entry while each runs its own admission', () async {
    final admissions = <String>[];
    final ArtifactLease tachi = await cache.admit(
      bytes,
      binding: binding,
      profile: profile,
      verifier: (_, _) => admissions.add('tachi'),
    );
    final ArtifactLease? other = await cache.lookup(
      binding: binding,
      profile: profile,
      verifier: (_, _) => admissions.add('other'),
    );
    check(admissions).deepEquals(<String>['tachi', 'other']);
    check(other!.path).equals(tachi.path);
    check(cache.leaseCount(binding, profile)).equals(2);
    check(await cache.evict(binding, profile)).isFalse();
    tachi.release();
    check(await other.readVerified()).deepEquals(bytes);
    other.release();
    check(await cache.evict(binding, profile)).isTrue();
  });

  test('a different producer profile is a different cache entry', () async {
    final ArtifactLease a = await cache.admit(bytes, binding: binding, profile: profile, verifier: (_, _) {});
    final ArtifactLease b = await cache.admit(
      bytes,
      binding: binding,
      profile: const ArtifactProfile(producer: 'tachi-dex2jar', converterVersion: '2.4', hostCompatibility: '1.5'),
      verifier: (_, _) {},
    );
    check(a.path).not((Subject<String> it) => it.equals(b.path));
  });

  test('reads re-verify the staged bytes, so changed bytes are never loaded', () async {
    final ArtifactLease lease = await cache.admit(bytes, binding: binding, profile: profile, verifier: (_, _) {});
    check(await lease.verifiedPath()).equals(lease.path);
    File(lease.path).writeAsBytesSync(utf8.encode('tampered'));
    await check(lease.readVerified()).throws<ArtifactIntegrityException>();
    await check(lease.verifiedPath()).throws<ArtifactIntegrityException>();
  });

  test('a tampered entry is restaged on the next admission', () async {
    final ArtifactLease first = await cache.admit(bytes, binding: binding, profile: profile, verifier: (_, _) {});
    first.release();
    File(first.path).writeAsBytesSync(utf8.encode('tampered'));
    check(await cache.lookup(binding: binding, profile: profile, verifier: (_, _) {})).isNull();
    final ArtifactLease again = await cache.admit(bytes, binding: binding, profile: profile, verifier: (_, _) {});
    check(await again.readVerified()).deepEquals(bytes);
  });

  test('a released lease cannot be read', () async {
    final ArtifactLease lease = await cache.admit(bytes, binding: binding, profile: profile, verifier: (_, _) {});
    lease
      ..release()
      ..release();
    await check(lease.readVerified()).throws<StateError>();
  });
}
