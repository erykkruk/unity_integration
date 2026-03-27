Pod::Spec.new do |s|
  s.name             = 'unity_kit'
  s.version          = '0.9.1'
  s.summary          = 'Flutter plugin for Unity 3D integration'
  s.homepage         = 'https://github.com/erykkruk/unity_kit'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Eryk Kruk' => 'eryk@ravenlab.tech' }
  s.source           = { :http => 'https://github.com/erykkruk/unity_kit' }
  s.source_files     = 'Classes/**/*'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.dependency 'Flutter'

  # UnityFramework is vendored or symlinked by the consuming app.
  # We intentionally avoid File.symlink? here — it returns true even for
  # broken symlinks, which causes CocoaPods to resolve the real path and
  # crash with ENOENT when the target doesn't exist in the pub cache.
  unity_framework_path = File.join(__dir__, 'UnityFramework.framework')
  if File.exist?(unity_framework_path)
    s.ios.vendored_frameworks = 'UnityFramework.framework'
    s.preserve_paths = 'UnityFramework.framework'
  end

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}" "${PODS_CONFIGURATION_BUILD_DIR}"',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }
end
