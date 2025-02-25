// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:file_testing/file_testing.dart';
import 'package:flutter_tools/src/android/android_sdk.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/flutter_cache.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:meta/meta.dart';
import 'package:test/fake.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fakes.dart';

const FakeCommand unameCommandForX64 = FakeCommand(
  command: <String>[
    'uname',
    '-m',
  ],
  stdout: 'x86_64',
);

const FakeCommand unameCommandForArm64 = FakeCommand(
  command: <String>[
    'uname',
    '-m',
  ],
  stdout: 'aarch64',
);

void main() {
  FakeProcessManager fakeProcessManager;

  setUp(() {
    fakeProcessManager = FakeProcessManager.empty();
  });

  Cache createCache(Platform platform) {
    return Cache.test(
      platform: platform,
      processManager: fakeProcessManager
    );
  }

  group('Cache.checkLockAcquired', () {
    setUp(() {
      Cache.enableLocking();
    });

    tearDown(() {
      // Restore locking to prevent potential side-effects in
      // tests outside this group (this option is globally shared).
      Cache.enableLocking();
    });

    testWithoutContext('should throw when locking is not acquired', () {
      final Cache cache = Cache.test(processManager: FakeProcessManager.any());

      expect(cache.checkLockAcquired, throwsStateError);
    });

    testWithoutContext('should not throw when locking is disabled', () {
      final Cache cache = Cache.test(processManager: FakeProcessManager.any());
      Cache.disableLocking();

      expect(cache.checkLockAcquired, returnsNormally);
    });

    testWithoutContext('should not throw when lock is acquired', () async {
      final String oldRoot = Cache.flutterRoot;
      Cache.flutterRoot = '';
      try {
        final FileSystem fileSystem = MemoryFileSystem.test();
        final Cache cache = Cache.test(
            fileSystem: fileSystem, processManager: FakeProcessManager.any());
        fileSystem.file(fileSystem.path.join('bin', 'cache', 'lockfile'))
            .createSync(recursive: true);

        await cache.lock();

        expect(cache.checkLockAcquired, returnsNormally);
        expect(cache.releaseLock, returnsNormally);
      } finally {
        Cache.flutterRoot = oldRoot;
      }
      // TODO(zanderso): implement support for lock so this can be tested with the memory file system.
    }, skip: true); // https://github.com/flutter/flutter/issues/87923

    testWithoutContext('throws tool exit when lockfile open fails', () async {
      final FileSystem fileSystem = MemoryFileSystem.test();
      final Cache cache = Cache.test(fileSystem: fileSystem, processManager: FakeProcessManager.any());
      fileSystem.file(fileSystem.path.join('bin', 'cache', 'lockfile'))
        .createSync(recursive: true);

      expect(() async => cache.lock(), throwsToolExit());
      // TODO(zanderso): implement support for lock so this can be tested with the memory file system.
    }, skip: true); // https://github.com/flutter/flutter/issues/87923

    testWithoutContext('should not throw when FLUTTER_ALREADY_LOCKED is set', () {
     final Cache cache = Cache.test(
       platform: FakePlatform(environment: <String, String>{
        'FLUTTER_ALREADY_LOCKED': 'true',
       }),
       processManager: FakeProcessManager.any(),
     );

      expect(cache.checkLockAcquired, returnsNormally);
    });
  });

  group('Cache', () {
    testWithoutContext('Continues on failed stamp file update', () async {
      final FileSystem fileSystem = MemoryFileSystem.test();
      final BufferLogger logger = BufferLogger.test();
      final Directory artifactDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_artifact.');
      final Directory downloadDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_download.');
      final Cache cache = FakeSecondaryCache()
        ..version = 'asdasd'
        ..artifactDirectory = artifactDir
        ..downloadDir = downloadDir
        ..onSetStamp = (String name, String version) {
          throw const FileSystemException('stamp write failed');
        };

      final FakeSimpleArtifact artifact = FakeSimpleArtifact(cache);
      await artifact.update(FakeArtifactUpdater(), logger, fileSystem, FakeOperatingSystemUtils());

      expect(logger.warningText, contains('stamp write failed'));
    });

    testWithoutContext('Continues on missing version file', () async {
      final FileSystem fileSystem = MemoryFileSystem.test();
      final BufferLogger logger = BufferLogger.test();
      final Directory artifactDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_artifact.');
      final Directory downloadDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_download.');
      final Cache cache = FakeSecondaryCache()
        ..version = null // version is missing.
        ..artifactDirectory = artifactDir
        ..downloadDir = downloadDir;

      final FakeSimpleArtifact artifact = FakeSimpleArtifact(cache);
      await artifact.update(FakeArtifactUpdater(), logger, fileSystem, FakeOperatingSystemUtils());

      expect(logger.warningText, contains('No known version for the artifact name "fake"'));
    });

    testWithoutContext('Gradle wrapper should not be up to date, if some cached artifact is not available', () {
      final FileSystem fileSystem = MemoryFileSystem.test();
      final Cache cache = Cache.test(fileSystem: fileSystem, processManager: FakeProcessManager.any());
      final GradleWrapper gradleWrapper = GradleWrapper(cache);
      final Directory directory = cache.getCacheDir(fileSystem.path.join('artifacts', 'gradle_wrapper'));
      fileSystem.file(fileSystem.path.join(directory.path, 'gradle', 'wrapper', 'gradle-wrapper.jar')).createSync(recursive: true);

      expect(gradleWrapper.isUpToDateInner(fileSystem), false);
    });

    testWithoutContext('Gradle wrapper will delete .properties/NOTICES if they exist', () async {
      final FileSystem fileSystem = MemoryFileSystem.test();
      final Directory artifactDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_artifact.');
      final FakeSecondaryCache cache = FakeSecondaryCache()
        ..artifactDirectory = artifactDir
        ..version = '123456';

      final OperatingSystemUtils operatingSystemUtils = OperatingSystemUtils(
        processManager: FakeProcessManager.any(),
        platform: FakePlatform(),
        logger: BufferLogger.test(),
        fileSystem: fileSystem,
      );
      final GradleWrapper gradleWrapper = GradleWrapper(cache);
      final File propertiesFile = fileSystem.file(fileSystem.path.join(artifactDir.path, 'gradle', 'wrapper', 'gradle-wrapper.properties'))
        ..createSync(recursive: true);
      final File noticeFile = fileSystem.file(fileSystem.path.join(artifactDir.path, 'NOTICE'))
        ..createSync(recursive: true);

      await gradleWrapper.updateInner(FakeArtifactUpdater(), fileSystem, operatingSystemUtils);

      expect(propertiesFile, isNot(exists));
      expect(noticeFile, isNot(exists));
    });

    testWithoutContext('Gradle wrapper should be up to date, only if all cached artifact are available', () {
      final FileSystem fileSystem = MemoryFileSystem.test();
      final Cache cache = Cache.test(fileSystem: fileSystem, processManager: FakeProcessManager.any());
      final GradleWrapper gradleWrapper = GradleWrapper(cache);
      final Directory directory = cache.getCacheDir(fileSystem.path.join('artifacts', 'gradle_wrapper'));
      fileSystem.file(fileSystem.path.join(directory.path, 'gradle', 'wrapper', 'gradle-wrapper.jar')).createSync(recursive: true);
      fileSystem.file(fileSystem.path.join(directory.path, 'gradlew')).createSync(recursive: true);
      fileSystem.file(fileSystem.path.join(directory.path, 'gradlew.bat')).createSync(recursive: true);

      expect(gradleWrapper.isUpToDateInner(fileSystem), true);
    });

    testWithoutContext('should not be up to date, if some cached artifact is not', () async {
      final CachedArtifact artifact1 = FakeSecondaryCachedArtifact()
        ..upToDate = true;
      final CachedArtifact artifact2 = FakeSecondaryCachedArtifact()
        ..upToDate = false;
      final FileSystem fileSystem = MemoryFileSystem.test();

      final Cache cache = Cache.test(
        fileSystem: fileSystem,
        artifacts: <CachedArtifact>[artifact1, artifact2],
        processManager: FakeProcessManager.any(),
      );

      expect(await cache.isUpToDate(), isFalse);
    });

    testWithoutContext('should be up to date, if all cached artifacts are', () async {
      final FakeSecondaryCachedArtifact artifact1 = FakeSecondaryCachedArtifact()
        ..upToDate = true;
      final FakeSecondaryCachedArtifact artifact2 = FakeSecondaryCachedArtifact()
        ..upToDate = true;
      final FileSystem fileSystem = MemoryFileSystem.test();
      final Cache cache = Cache.test(
        fileSystem: fileSystem,
        artifacts: <CachedArtifact>[artifact1, artifact2],
        processManager: FakeProcessManager.any(),
      );

      expect(await cache.isUpToDate(), isTrue);
    });

    testWithoutContext('should update cached artifacts which are not up to date', () async {
      final FakeSecondaryCachedArtifact artifact1 = FakeSecondaryCachedArtifact()
        ..upToDate = true;
      final FakeSecondaryCachedArtifact artifact2 = FakeSecondaryCachedArtifact()
        ..upToDate = false;
      final FileSystem fileSystem = MemoryFileSystem.test();

      final Cache cache = Cache.test(
        fileSystem: fileSystem,
        artifacts: <CachedArtifact>[artifact1, artifact2],
        processManager: FakeProcessManager.any(),
      );

      await cache.updateAll(<DevelopmentArtifact>{
        DevelopmentArtifact.universal,
      });
      expect(artifact1.didUpdate, false);
      expect(artifact2.didUpdate, true);
    });

    testWithoutContext("getter dyLdLibEntry concatenates the output of each artifact's dyLdLibEntry getter", () async {
      final FakeIosUsbArtifacts artifact1 = FakeIosUsbArtifacts();
      final FakeIosUsbArtifacts artifact2 = FakeIosUsbArtifacts();
      final FakeIosUsbArtifacts artifact3 = FakeIosUsbArtifacts();
      artifact1.environment = <String, String>{
        'DYLD_LIBRARY_PATH': '/path/to/alpha:/path/to/beta',
      };
      artifact2.environment = <String, String>{
        'DYLD_LIBRARY_PATH': '/path/to/gamma:/path/to/delta:/path/to/epsilon',
      };
      artifact3.environment = <String, String>{
        'DYLD_LIBRARY_PATH': '',
      };
      final Cache cache = Cache.test(
        artifacts: <CachedArtifact>[artifact1, artifact2, artifact3],
        processManager: FakeProcessManager.any(),
      );

      expect(cache.dyLdLibEntry.key, 'DYLD_LIBRARY_PATH');
      expect(
        cache.dyLdLibEntry.value,
        '/path/to/alpha:/path/to/beta:/path/to/gamma:/path/to/delta:/path/to/epsilon',
      );
    });

    testWithoutContext('failed storage.googleapis.com download shows China warning', () async {
      final InternetAddress address = (await InternetAddress.lookup('storage.googleapis.com')).first;
      final FakeSecondaryCachedArtifact artifact1 = FakeSecondaryCachedArtifact()
        ..upToDate = false;
      final FakeSecondaryCachedArtifact artifact2 = FakeSecondaryCachedArtifact()
        ..upToDate = false
        ..updateException = SocketException(
        'Connection reset by peer',
        address: address,
      );

      final BufferLogger logger = BufferLogger.test();
      final Cache cache = Cache.test(
        artifacts: <CachedArtifact>[artifact1, artifact2],
        processManager: FakeProcessManager.any(),
        logger: logger,
      );
      await expectLater(
        () => cache.updateAll(<DevelopmentArtifact>{DevelopmentArtifact.universal}),
        throwsException,
      );
      expect(artifact1.didUpdate, true);
      // Don't continue when retrieval fails.
      expect(artifact2.didUpdate, false);
      expect(
        logger.errorText,
        contains('https://flutter.dev/community/china'),
      );
    });

    testWithoutContext('Invalid URI for FLUTTER_STORAGE_BASE_URL throws ToolExit', () async {
      final Cache cache = Cache.test(
        platform: FakePlatform(environment: <String, String>{
          'FLUTTER_STORAGE_BASE_URL': ' http://foo',
        }),
        processManager: FakeProcessManager.any(),
      );

      expect(() => cache.storageBaseUrl, throwsToolExit());
    });
  });

  testWithoutContext('flattenNameSubdirs', () {
    expect(flattenNameSubdirs(Uri.parse('http://flutter.dev/foo/bar'), MemoryFileSystem.test()), 'flutter.dev/foo/bar');
    expect(flattenNameSubdirs(Uri.parse('http://api.flutter.dev/foo/bar'), MemoryFileSystem.test()), 'api.flutter.dev/foo/bar');
    expect(flattenNameSubdirs(Uri.parse('https://www.flutter.dev'), MemoryFileSystem.test()), 'www.flutter.dev');
  });

  testWithoutContext('EngineCachedArtifact makes binary dirs readable and executable by all', () async {
    final FakeOperatingSystemUtils operatingSystemUtils = FakeOperatingSystemUtils();
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Directory artifactDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_artifact.');
    final Directory downloadDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_download.');
    final FakeSecondaryCache cache = FakeSecondaryCache()
      ..artifactDirectory = artifactDir
      ..downloadDir = downloadDir;
    artifactDir.childDirectory('bin_dir').createSync();
    artifactDir.childFile('unused_url_path').createSync();

    final FakeCachedArtifact artifact = FakeCachedArtifact(
      cache: cache,
      binaryDirs: <List<String>>[
        <String>['bin_dir', 'unused_url_path'],
      ],
      requiredArtifacts: DevelopmentArtifact.universal,
    );
    await artifact.updateInner(FakeArtifactUpdater(), fileSystem, operatingSystemUtils);
    final Directory dir = fileSystem.systemTempDirectory
        .listSync(recursive: true)
        .whereType<Directory>()
        .singleWhere((Directory directory) => directory.basename == 'bin_dir', orElse: () => null);

    expect(dir, isNotNull);
    expect(dir.path, artifactDir.childDirectory('bin_dir').path);
    expect(operatingSystemUtils.chmods, <List<String>>[<String>['/.tmp_rand0/flutter_cache_test_artifact.rand0/bin_dir', 'a+r,a+x']]);
  });

  testWithoutContext('EngineCachedArtifact removes unzipped FlutterMacOS.framework before replacing', () async {
    final OperatingSystemUtils operatingSystemUtils = FakeOperatingSystemUtils();
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Directory artifactDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_artifact.');
    final Directory downloadDir = fileSystem.systemTempDirectory.createTempSync('flutter_cache_test_download.');
    final FakeSecondaryCache cache = FakeSecondaryCache()
      ..artifactDirectory = artifactDir
      ..downloadDir = downloadDir;

    final Directory binDir = artifactDir.childDirectory('bin_dir')..createSync();
    binDir.childFile('FlutterMacOS.framework.zip').createSync();
    final Directory unzippedFramework = binDir.childDirectory('FlutterMacOS.framework');
    final File staleFile = unzippedFramework.childFile('stale_file')..createSync(recursive: true);
    artifactDir.childFile('unused_url_path').createSync();

    final FakeCachedArtifact artifact = FakeCachedArtifact(
      cache: cache,
      binaryDirs: <List<String>>[
        <String>['bin_dir', 'unused_url_path'],
      ],
      requiredArtifacts: DevelopmentArtifact.universal,
    );
    await artifact.updateInner(FakeArtifactUpdater(), fileSystem, operatingSystemUtils);
    expect(unzippedFramework, exists);
    expect(staleFile, isNot(exists));
  });

  testWithoutContext('IosUsbArtifacts verifies executables for libimobiledevice in isUpToDateInner', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Cache cache = Cache.test(fileSystem: fileSystem, processManager: FakeProcessManager.any());
    final IosUsbArtifacts iosUsbArtifacts = IosUsbArtifacts('libimobiledevice', cache, platform: FakePlatform(operatingSystem: 'macos'));
    iosUsbArtifacts.location.createSync();
    final File ideviceScreenshotFile = iosUsbArtifacts.location.childFile('idevicescreenshot')
      ..createSync();
    iosUsbArtifacts.location.childFile('idevicesyslog')
      .createSync();

    expect(iosUsbArtifacts.isUpToDateInner(fileSystem), true);

    ideviceScreenshotFile.deleteSync();

    expect(iosUsbArtifacts.isUpToDateInner(fileSystem), false);
  });

  testWithoutContext('IosUsbArtifacts verifies iproxy for usbmuxd in isUpToDateInner', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Cache cache = Cache.test(fileSystem: fileSystem, processManager: FakeProcessManager.any());
    final IosUsbArtifacts iosUsbArtifacts = IosUsbArtifacts('usbmuxd', cache, platform: FakePlatform(operatingSystem: 'macos'));
    iosUsbArtifacts.location.createSync();
    final File iproxy = iosUsbArtifacts.location.childFile('iproxy')
      ..createSync();

    expect(iosUsbArtifacts.isUpToDateInner(fileSystem), true);

    iproxy.deleteSync();

    expect(iosUsbArtifacts.isUpToDateInner(fileSystem), false);
  });

  testWithoutContext('IosUsbArtifacts does not verify executables for openssl in isUpToDateInner', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Cache cache = Cache.test(fileSystem: fileSystem, processManager: FakeProcessManager.any());
    final IosUsbArtifacts iosUsbArtifacts = IosUsbArtifacts('openssl', cache, platform: FakePlatform(operatingSystem: 'macos'));
    iosUsbArtifacts.location.createSync();

    expect(iosUsbArtifacts.isUpToDateInner(fileSystem), true);
  });

  testWithoutContext('IosUsbArtifacts uses unsigned when specified', () async {
    final Cache cache = Cache.test(processManager: FakeProcessManager.any());
    cache.useUnsignedMacBinaries = true;

    final IosUsbArtifacts iosUsbArtifacts = IosUsbArtifacts('name', cache, platform: FakePlatform(operatingSystem: 'macos'));
    expect(iosUsbArtifacts.archiveUri.toString(), contains('/unsigned/'));
  });

  testWithoutContext('IosUsbArtifacts does not use unsigned when not specified', () async {
    final Cache cache = Cache.test(processManager: FakeProcessManager.any());
    final IosUsbArtifacts iosUsbArtifacts = IosUsbArtifacts('name', cache, platform: FakePlatform(operatingSystem: 'macos'));

    expect(iosUsbArtifacts.archiveUri.toString(), isNot(contains('/unsigned/')));
  });

  testWithoutContext('FlutterRunnerDebugSymbols downloads Flutter runner debug symbols', () async {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Cache cache = FakeSecondaryCache()
      ..version = '123456';

    final FakeVersionedPackageResolver packageResolver = FakeVersionedPackageResolver();
    final FlutterRunnerDebugSymbols flutterRunnerDebugSymbols = FlutterRunnerDebugSymbols(
      cache,
      packageResolver: packageResolver,
      platform: FakePlatform(),
    );

    await flutterRunnerDebugSymbols.updateInner(FakeArtifactUpdater(), fileSystem, FakeOperatingSystemUtils());

    expect(packageResolver.resolved, <List<String>>[
      <String>['fuchsia-debug-symbols-x64', '123456'],
      <String>['fuchsia-debug-symbols-arm64', '123456'],
    ]);
  });

  testWithoutContext('FontSubset in universal artifacts', () {
    final Cache cache = Cache.test(processManager: FakeProcessManager.any());
    final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform());

    expect(artifacts.developmentArtifact, DevelopmentArtifact.universal);
  });

  testWithoutContext('FontSubset artifacts on x64 linux', () {
    fakeProcessManager.addCommand(unameCommandForX64);

    final Cache cache = createCache(FakePlatform());
    final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform());
    cache.includeAllPlatforms = false;

    expect(artifacts.getBinaryDirs(), <List<String>>[<String>['linux-x64', 'linux-x64/font-subset.zip']]);
  });

  testWithoutContext('FontSubset artifacts on arm64 linux', () {
    fakeProcessManager.addCommand(unameCommandForArm64);

    final Cache cache = createCache(FakePlatform());
    final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform());
    cache.includeAllPlatforms = false;

    expect(artifacts.getBinaryDirs(), <List<String>>[<String>['linux-arm64', 'linux-arm64/font-subset.zip']]);
  });

  testWithoutContext('FontSubset artifacts on windows', () {
    final Cache cache = createCache(FakePlatform(operatingSystem: 'windows'));
    final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform(operatingSystem: 'windows'));
    cache.includeAllPlatforms = false;

    expect(artifacts.getBinaryDirs(), <List<String>>[<String>['windows-x64', 'windows-x64/font-subset.zip']]);
  });

  testWithoutContext('FontSubset artifacts on macos', () {
    fakeProcessManager.addCommands(<FakeCommand>[
      const FakeCommand(
        command: <String>[
          'which',
          'sysctl'
        ],
        stdout: '/sbin/sysctl',
      ),
      const FakeCommand(
        command: <String>[
          'sysctl',
          'hw.optional.arm64',
        ],
        stdout: 'hw.optional.arm64: 0',
      ),
    ]);

    final Cache cache = createCache(FakePlatform(operatingSystem: 'macos'));
    final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform(operatingSystem: 'macos'));
    cache.includeAllPlatforms = false;

    expect(artifacts.getBinaryDirs(), <List<String>>[<String>['darwin-x64', 'darwin-x64/font-subset.zip']]);
  });

  testWithoutContext('FontSubset artifacts on fuchsia', () {
    fakeProcessManager.addCommand(unameCommandForX64);

    final Cache cache = createCache(FakePlatform(operatingSystem: 'fuchsia'));
    final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform(operatingSystem: 'fuchsia'));
    cache.includeAllPlatforms = false;

    expect(artifacts.getBinaryDirs, throwsToolExit(message: 'Unsupported operating system: fuchsia'));
  });

  testWithoutContext('FontSubset artifacts for all platforms on x64 hosts', () {
      fakeProcessManager.addCommand(unameCommandForX64);

      final Cache cache = createCache(FakePlatform(operatingSystem: 'fuchsia'));
      final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform(operatingSystem: 'fuchsia'));
      cache.includeAllPlatforms = true;

      expect(artifacts.getBinaryDirs(), <List<String>>[
        <String>['darwin-x64', 'darwin-x64/font-subset.zip'],
        <String>['linux-x64', 'linux-x64/font-subset.zip'],
        <String>['windows-x64', 'windows-x64/font-subset.zip'],
      ]);
  });

  testWithoutContext('FontSubset artifacts for all platforms on arm64 hosts', () {
      fakeProcessManager.addCommand(unameCommandForArm64);

      final Cache cache = createCache(FakePlatform(operatingSystem: 'fuchsia'));
      final FontSubsetArtifacts artifacts = FontSubsetArtifacts(cache, platform: FakePlatform(operatingSystem: 'fuchsia'));
      cache.includeAllPlatforms = true;

      expect(artifacts.getBinaryDirs(), <List<String>>[
        <String>['darwin-x64', 'darwin-x64/font-subset.zip'], // arm64 macOS hosts are not supported now
        <String>['linux-arm64', 'linux-arm64/font-subset.zip'],
        <String>['windows-x64', 'windows-x64/font-subset.zip'], // arm64 macOS hosts are not supported now
      ]);
  });

  testWithoutContext('macOS desktop artifacts ignore filtering when requested', () {
    final Cache cache = Cache.test(processManager: FakeProcessManager.any());
    final MacOSEngineArtifacts artifacts = MacOSEngineArtifacts(cache, platform: FakePlatform());
    cache.includeAllPlatforms = false;
    cache.platformOverrideArtifacts = <String>{'macos'};

    expect(artifacts.getBinaryDirs(), isNotEmpty);
  });

  testWithoutContext('Windows desktop artifacts ignore filtering when requested', () {
    final Cache cache = Cache.test(processManager: FakeProcessManager.any());
    final WindowsEngineArtifacts artifacts = WindowsEngineArtifacts(
      cache,
      platform: FakePlatform(),
    );
    cache.includeAllPlatforms = false;
    cache.platformOverrideArtifacts = <String>{'windows'};

    expect(artifacts.getBinaryDirs(), isNotEmpty);
  });

  testWithoutContext('Windows desktop artifacts include profile and release artifacts', () {
    final Cache cache = Cache.test(processManager: FakeProcessManager.any());
    final WindowsEngineArtifacts artifacts = WindowsEngineArtifacts(
      cache,
      platform: FakePlatform(operatingSystem: 'windows'),
    );

    expect(artifacts.getBinaryDirs(), containsAll(<Matcher>[
      contains(contains('profile')),
      contains(contains('release')),
    ]));
  });

  testWithoutContext('Windows UWP desktop artifacts include profile, debug, and release artifacts', () {
    final Cache cache = Cache.test(processManager: FakeProcessManager.any());
    final WindowsUwpEngineArtifacts artifacts = WindowsUwpEngineArtifacts(
      cache,
      platform: FakePlatform(operatingSystem: 'windows'),
    );

    expect(artifacts.getBinaryDirs(), containsAll(<Matcher>[
      contains(contains('profile')),
      contains(contains('release')),
      contains(contains('debug')),
    ]));
  });

  testWithoutContext('Linux desktop artifacts ignore filtering when requested', () {
    fakeProcessManager.addCommand(unameCommandForX64);

    final Cache cache = createCache(FakePlatform());
    final LinuxEngineArtifacts artifacts = LinuxEngineArtifacts(
      cache,
      platform: FakePlatform(operatingSystem: 'macos'),
    );
    cache.includeAllPlatforms = false;
    cache.platformOverrideArtifacts = <String>{'linux'};

    expect(artifacts.getBinaryDirs(), isNotEmpty);
  });

  testWithoutContext('Linux desktop artifacts for x64 include profile and release artifacts', () {
      fakeProcessManager.addCommand(unameCommandForX64);

      final Cache cache = createCache(FakePlatform());
      final LinuxEngineArtifacts artifacts = LinuxEngineArtifacts(
        cache,
        platform: FakePlatform(),
      );

      expect(artifacts.getBinaryDirs(), <List<String>>[
        <String>['linux-x64', 'linux-x64/linux-x64-flutter-gtk.zip'],
        <String>['linux-x64-profile', 'linux-x64-profile/linux-x64-flutter-gtk.zip'],
        <String>['linux-x64-release', 'linux-x64-release/linux-x64-flutter-gtk.zip'],
      ]);
  });

  testWithoutContext('Linux desktop artifacts for arm64 include profile and release artifacts', () {
      fakeProcessManager.addCommand(unameCommandForArm64);

      final Cache cache = createCache(FakePlatform());
      final LinuxEngineArtifacts artifacts = LinuxEngineArtifacts(
        cache,
        platform: FakePlatform(),
      );

      expect(artifacts.getBinaryDirs(), <List<String>>[
        <String>['linux-arm64', 'linux-arm64/linux-arm64-flutter-gtk.zip'],
        <String>['linux-arm64-profile', 'linux-arm64-profile/linux-arm64-flutter-gtk.zip'],
        <String>['linux-arm64-release', 'linux-arm64-release/linux-arm64-flutter-gtk.zip'],
      ]);
  });

  testWithoutContext('Cache can delete stampfiles of artifacts', () {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final FakeIosUsbArtifacts artifactSet = FakeIosUsbArtifacts();
    final BufferLogger logger = BufferLogger.test();

    artifactSet.stampName = 'STAMP';
    final Cache cache = Cache(
      artifacts: <ArtifactSet>[
        artifactSet,
      ],
      logger: logger,
      fileSystem: fileSystem,
      platform: FakePlatform(),
      osUtils: FakeOperatingSystemUtils(),
      rootOverride: fileSystem.currentDirectory,
    );
    final File toolStampFile = fileSystem.file('bin/cache/flutter_tools.stamp');
    final File stampFile = cache.getStampFileFor(artifactSet.stampName);
    stampFile.createSync(recursive: true);
    toolStampFile.createSync(recursive: true);

    cache.clearStampFiles();

    expect(logger.errorText, isEmpty);
    expect(stampFile, isNot(exists));
    expect(toolStampFile, isNot(exists));
  });

   testWithoutContext('Cache does not attempt to delete already missing stamp files', () {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final FakeIosUsbArtifacts artifactSet = FakeIosUsbArtifacts();
    final BufferLogger logger = BufferLogger.test();

    artifactSet.stampName = 'STAMP';
    final Cache cache = Cache(
      artifacts: <ArtifactSet>[
        artifactSet,
      ],
      logger: logger,
      fileSystem: fileSystem,
      platform: FakePlatform(),
      osUtils: FakeOperatingSystemUtils(),
      rootOverride: fileSystem.currentDirectory,
    );
    final File toolStampFile = fileSystem.file('bin/cache/flutter_tools.stamp');
    final File stampFile = cache.getStampFileFor(artifactSet.stampName);
    toolStampFile.createSync(recursive: true);

    cache.clearStampFiles();

    expect(logger.errorText, isEmpty);
    expect(stampFile, isNot(exists));
    expect(toolStampFile, isNot(exists));
  });

  testWithoutContext('Cache catches file system exception from missing tool stamp file', () {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final FakeIosUsbArtifacts artifactSet = FakeIosUsbArtifacts();
    final BufferLogger logger = BufferLogger.test();

    artifactSet.stampName = 'STAMP';
    final Cache cache = Cache(
      artifacts: <ArtifactSet>[
        artifactSet,
      ],
      logger: logger,
      fileSystem: fileSystem,
      platform: FakePlatform(),
      osUtils: FakeOperatingSystemUtils(),
      rootOverride: fileSystem.currentDirectory,
    );

    cache.clearStampFiles();

    expect(logger.warningText, contains('Failed to delete some stamp files'));
  });

  testWithoutContext('FlutterWebSdk fetches web artifacts and deletes previous directory contents', () async {
    final MemoryFileSystem fileSystem = MemoryFileSystem.test();
    final File canvasKitVersionFile = fileSystem.currentDirectory
      .childDirectory('cache')
      .childDirectory('bin')
      .childDirectory('internal')
      .childFile('canvaskit.version');
    canvasKitVersionFile.createSync(recursive: true);
    canvasKitVersionFile.writeAsStringSync('abcdefg');

    final Cache cache = Cache.test(processManager: FakeProcessManager.any(), fileSystem: fileSystem);
    final Directory webCacheDirectory = cache.getWebSdkDirectory();
    final FakeArtifactUpdater artifactUpdater = FakeArtifactUpdater();
    final FlutterWebSdk webSdk = FlutterWebSdk(cache, platform: FakePlatform());

    final List<String> messages = <String>[];
    final List<String> downloads = <String>[];
    final List<String> locations = <String>[];
    artifactUpdater.onDownloadZipArchive = (String message, Uri uri, Directory location) {
      messages.add(message);
      downloads.add(uri.toString());
      locations.add(location.path);
      location.createSync(recursive: true);
      location.childFile('foo').createSync();
    };
    webCacheDirectory.childFile('bar').createSync(recursive: true);

    await webSdk.updateInner(artifactUpdater, fileSystem, FakeOperatingSystemUtils());

    expect(messages, <String>[
      'Downloading Web SDK...',
      'Downloading CanvasKit...',
    ]);

    expect(downloads, <String>[
      'https://storage.googleapis.com/flutter_infra_release/flutter/null/flutter-web-sdk-linux-x64.zip',
      'https://chrome-infra-packages.appspot.com/dl/flutter/web/canvaskit_bundle/+/abcdefg',
    ]);

    expect(locations, <String>[
      'cache/bin/cache/flutter_web_sdk',
      'cache/bin/cache/flutter_web_sdk',
    ]);

    expect(webCacheDirectory.childFile('foo'), exists);
    expect(webCacheDirectory.childFile('bar'), isNot(exists));
  });

  testWithoutContext('FlutterWebSdk uses tryToDelete to handle directory edge cases', () async {
    final FileExceptionHandler handler = FileExceptionHandler();
    final MemoryFileSystem fileSystem = MemoryFileSystem.test(opHandle: handler.opHandle);
    final Cache cache = Cache.test(processManager: FakeProcessManager.any(), fileSystem: fileSystem);
    final Directory webCacheDirectory = cache.getWebSdkDirectory();
    final FakeArtifactUpdater artifactUpdater = FakeArtifactUpdater();
    final FlutterWebSdk webSdk = FlutterWebSdk(cache, platform: FakePlatform());

    artifactUpdater.onDownloadZipArchive = (String message, Uri uri, Directory location) {
      location.createSync(recursive: true);
      location.childFile('foo').createSync();
    };
    webCacheDirectory.childFile('bar').createSync(recursive: true);
    handler.addError(webCacheDirectory, FileSystemOp.delete, const FileSystemException('', '', OSError('', 2)));

    await expectLater(() => webSdk.updateInner(artifactUpdater, fileSystem, FakeOperatingSystemUtils()), throwsToolExit(
      message: RegExp('The Flutter tool tried to delete the file or directory cache/bin/cache/flutter_web_sdk but was unable to'),
    ));
  });

  testWithoutContext('Cache handles exception thrown if stamp file cannot be parsed', () {
    final FileExceptionHandler exceptionHandler = FileExceptionHandler();
    final FileSystem fileSystem = MemoryFileSystem.test(opHandle: exceptionHandler.opHandle);
    final Logger logger = BufferLogger.test();
    final FakeCache cache = FakeCache(
      fileSystem: fileSystem,
      logger: logger,
      platform: FakePlatform(),
      osUtils: FakeOperatingSystemUtils()
    );
    final File file = fileSystem.file('stamp');
    cache.stampFile = file;

    expect(cache.getStampFor('foo'), null);

    file.createSync();
    exceptionHandler.addError(
      file,
      FileSystemOp.read,
      const FileSystemException(),
    );

    expect(cache.getStampFor('foo'), null);
  });

  testWithoutContext('Cache parses stamp file', () {
    final FileSystem fileSystem = MemoryFileSystem.test();
    final Logger logger = BufferLogger.test();
    final FakeCache cache = FakeCache(
      fileSystem: fileSystem,
      logger: logger,
      platform: FakePlatform(),
      osUtils: FakeOperatingSystemUtils()
    );

    final File file = fileSystem.file('stamp')..writeAsStringSync('ABC ');
    cache.stampFile = file;

    expect(cache.getStampFor('foo'), 'ABC');
  });

  testWithoutContext('PubDependencies needs to be updated if the package config'
    ' file or the source directories are missing', () async {
    final BufferLogger logger = BufferLogger.test();
    final MemoryFileSystem fileSystem = MemoryFileSystem.test();
    final PubDependencies pubDependencies = PubDependencies(
      flutterRoot: () => '',
      logger: logger,
      pub: () => FakePub(),
    );

    expect(await pubDependencies.isUpToDate(fileSystem), false); // no package config

    fileSystem.file('packages/flutter_tools/.packages')
      ..createSync(recursive: true)
      ..writeAsStringSync('\n');
    fileSystem.file('packages/flutter_tools/.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "example",
      "rootUri": "file:///.pub-cache/hosted/pub.dartlang.org/example-7.0.0",
      "packageUri": "lib/",
      "languageVersion": "2.7"
    }
  ],
  "generated": "2020-09-15T20:29:20.691147Z",
  "generator": "pub",
  "generatorVersion": "2.10.0-121.0.dev"
}
''');

    expect(await pubDependencies.isUpToDate(fileSystem), false); // dependencies are missing.

    fileSystem.file('.pub-cache/hosted/pub.dartlang.org/example-7.0.0/lib/foo.dart')
      .createSync(recursive: true);

    expect(await pubDependencies.isUpToDate(fileSystem), true);
  });

  testWithoutContext('PubDependencies updates via pub get', () async {
    final BufferLogger logger = BufferLogger.test();
    final MemoryFileSystem fileSystem = MemoryFileSystem.test();
    final FakePub pub = FakePub();
    final PubDependencies pubDependencies = PubDependencies(
      flutterRoot: () => '',
      logger: logger,
      pub: () => pub,
    );

    await pubDependencies.update(FakeArtifactUpdater(), logger, fileSystem, FakeOperatingSystemUtils());

    expect(pub.calledGet, 1);
  });

  // Check that the build number matches the format documented here:
  // https://dart.dev/get-dart#release-channels
  testUsingContext('Check current Dart SDK build number', () async {
    final String currentDartSdkVersion = globals.cache.dartSdkBuild;
    final RegExp dartSdkVersionFormat = RegExp(r'\d+\.\d+\.\d+(?:-\S+)?');

    expect(dartSdkVersionFormat.allMatches(currentDartSdkVersion).length, 1,);
  });

  group('AndroidMavenArtifacts', () {
    MemoryFileSystem memoryFileSystem;
    Cache cache;
    FakeAndroidSdk fakeAndroidSdk;

    setUp(() {
      memoryFileSystem = MemoryFileSystem.test();
      cache = Cache.test(
        fileSystem: memoryFileSystem,
        processManager: FakeProcessManager.any(),
      );
      fakeAndroidSdk = FakeAndroidSdk();
    });

    testWithoutContext('AndroidMavenArtifacts has a specified development artifact', () async {
      final AndroidMavenArtifacts mavenArtifacts = AndroidMavenArtifacts(cache, platform: FakePlatform());
      expect(mavenArtifacts.developmentArtifact, DevelopmentArtifact.androidMaven);
    });

    testUsingContext('AndroidMavenArtifacts can invoke Gradle resolve dependencies if Android SDK is present', () async {
      Cache.flutterRoot = '';
      final AndroidMavenArtifacts mavenArtifacts = AndroidMavenArtifacts(cache, platform: FakePlatform());
      expect(await mavenArtifacts.isUpToDate(memoryFileSystem), isFalse);

      final Directory gradleWrapperDir = cache.getArtifactDirectory('gradle_wrapper')..createSync(recursive: true);
      gradleWrapperDir.childFile('gradlew').writeAsStringSync('irrelevant');
      gradleWrapperDir.childFile('gradlew.bat').writeAsStringSync('irrelevant');

      await mavenArtifacts.update(FakeArtifactUpdater(), BufferLogger.test(), memoryFileSystem, FakeOperatingSystemUtils());

      expect(await mavenArtifacts.isUpToDate(memoryFileSystem), isFalse);
      expect(fakeAndroidSdk.reinitialized, true);
    }, overrides: <Type, Generator>{
      Cache: () => cache,
      FileSystem: () => memoryFileSystem,
      Platform: () => FakePlatform(),
      ProcessManager: () => FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(command: <String>[
          '/cache/bin/cache/flutter_gradle_wrapper.rand0/gradlew',
          '-b',
          'packages/flutter_tools/gradle/resolve_dependencies.gradle',
          '--project-cache-dir',
          'cache/bin/cache/flutter_gradle_wrapper.rand0',
          'resolveDependencies',
        ])
      ]),
      AndroidSdk: () => fakeAndroidSdk
    });

    testUsingContext('AndroidMavenArtifacts is a no-op if the Android SDK is absent', () async {
      final AndroidMavenArtifacts mavenArtifacts = AndroidMavenArtifacts(cache, platform: FakePlatform());
      expect(await mavenArtifacts.isUpToDate(memoryFileSystem), isFalse);

      await mavenArtifacts.update(FakeArtifactUpdater(), BufferLogger.test(), memoryFileSystem, FakeOperatingSystemUtils());

      expect(await mavenArtifacts.isUpToDate(memoryFileSystem), isFalse);
    }, overrides: <Type, Generator>{
      Cache: () => cache,
      FileSystem: () => memoryFileSystem,
      ProcessManager: () => FakeProcessManager.empty(),
      AndroidSdk: () => null // Android SDK was not located.
    });
  });
}

class FakeCachedArtifact extends EngineCachedArtifact {
  FakeCachedArtifact({
    String stampName = 'STAMP',
    @required Cache cache,
    DevelopmentArtifact requiredArtifacts,
    this.binaryDirs = const <List<String>>[],
    this.licenseDirs = const <String>[],
    this.packageDirs = const <String>[],
  }) : super(stampName, cache, requiredArtifacts);

  final List<List<String>> binaryDirs;
  final List<String> licenseDirs;
  final List<String> packageDirs;

  @override
  List<List<String>> getBinaryDirs() => binaryDirs;

  @override
  List<String> getLicenseDirs() => licenseDirs;

  @override
  List<String> getPackageDirs() => packageDirs;
}

class FakeSimpleArtifact extends CachedArtifact {
  FakeSimpleArtifact(Cache cache) : super(
    'fake',
    cache,
    DevelopmentArtifact.universal,
  );

  @override
  Future<void> updateInner(ArtifactUpdater artifactUpdater, FileSystem fileSystem, OperatingSystemUtils operatingSystemUtils) async { }
}

class FakeDownloadedArtifact extends CachedArtifact {
  FakeDownloadedArtifact(this.downloadedFile, Cache cache) : super(
    'fake',
    cache,
    DevelopmentArtifact.universal,
  );

  final File downloadedFile;

  @override
  Future<void> updateInner(ArtifactUpdater artifactUpdater, FileSystem fileSystem, OperatingSystemUtils operatingSystemUtils) async { }
}

class FakeSecondaryCachedArtifact extends Fake implements CachedArtifact {
  bool upToDate = false;
  bool didUpdate = false;
  Exception updateException;

  @override
  Future<bool> isUpToDate(FileSystem fileSystem) async => upToDate;

  @override
  Future<void> update(ArtifactUpdater artifactUpdater, Logger logger, FileSystem fileSystem, OperatingSystemUtils operatingSystemUtils) async {
    if (updateException != null) {
      throw updateException;
    }
    didUpdate = true;
  }

  @override
  DevelopmentArtifact get developmentArtifact => DevelopmentArtifact.universal;
}

class FakeIosUsbArtifacts extends Fake implements IosUsbArtifacts {
  @override
  Map<String, String> environment =  <String, String>{};

  @override
  String stampName = 'ios-usb';
}

class FakeSecondaryCache extends Fake implements Cache {
  Directory downloadDir;
  Directory artifactDirectory;
  String version;
  void Function(String artifactName, String version) onSetStamp;

  @override
  String get storageBaseUrl => 'https://storage.googleapis.com';

  @override
  Directory getDownloadDir() => artifactDirectory;

  @override
  Directory getArtifactDirectory(String name) => artifactDirectory;

  @override
  Directory getCacheDir(String name) {
    return artifactDirectory.childDirectory(name);
  }

  @override
  File getLicenseFile() {
    return artifactDirectory.childFile('LICENSE');
  }

  @override
  String getVersionFor(String artifactName) => version;

  @override
  void setStampFor(String artifactName, String version) {
    onSetStamp(artifactName, version);
  }
}

class FakeVersionedPackageResolver extends Fake implements VersionedPackageResolver {
  final List<List<String>> resolved = <List<String>>[];

  @override
  String resolveUrl(String packageName, String version) {
    resolved.add(<String>[packageName, version]);
    return '';
  }
}

class FakePub extends Fake implements Pub {
  int calledGet = 0;

  @override
  Future<void> get({
    PubContext context,
    String directory,
    bool skipIfAbsent = false,
    bool upgrade = false,
    bool offline = false,
    bool generateSyntheticPackage = false,
    String flutterRootOverride,
    bool checkUpToDate = false,
    bool shouldSkipThirdPartyGenerator = true,
    bool printProgress = true,
  }) async {
    calledGet += 1;
  }
}

class FakeCache extends Cache {
  FakeCache({
    @required Logger logger,
    @required FileSystem fileSystem,
    @required Platform platform,
    @required OperatingSystemUtils osUtils,
  }) : super(
    logger: logger,
    fileSystem: fileSystem,
    platform: platform,
    osUtils: osUtils,
    artifacts: <ArtifactSet>[],
  );

  File stampFile;

  @override
  File getStampFileFor(String artifactName) {
    return stampFile;
  }
}

class FakeAndroidSdk extends Fake implements AndroidSdk {
  bool reinitialized = false;

  @override
  void reinitialize() {
    reinitialized = true;
  }
}

class FakeArtifactUpdater extends Fake implements ArtifactUpdater {
  void Function(String, Uri, Directory) onDownloadZipArchive;
  void Function(String, Uri, Directory) onDownloadZipTarball;

  @override
  Future<void> downloadZippedTarball(String message, Uri url, Directory location) async {
    onDownloadZipTarball?.call(message, url, location);
  }

  @override
  Future<void> downloadZipArchive(String message, Uri url, Directory location) async {
    onDownloadZipArchive?.call(message, url, location);
  }

  @override
  void removeDownloadedFiles() { }
}
