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

  # UnityFramework is provided by the consuming app (symlink or vendored).
  # Preserve it if present so the Swift compiler can find the module.
  unity_framework_path = File.join(__dir__, 'UnityFramework.framework')
  if File.exist?(unity_framework_path) || File.symlink?(unity_framework_path)
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
