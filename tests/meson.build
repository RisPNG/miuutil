test_environment = environment()
test_environment.set('GSETTINGS_BACKEND', 'memory')
test_environment.set('GSETTINGS_SCHEMA_DIR', meson.project_build_root() / 'data')
test_environment.set('LANG', 'C.UTF-8')
test_environment.set('GTK_A11Y', 'none')

options_tests = executable('options-tests', 'options.vala', core_resources,
  dependencies: core_dependency, vala_args: ['--pkg=posix'])
test('options', options_tests, env: test_environment)
desktop_settings_tests = executable('desktop-settings-tests', 'desktop-settings.vala', core_resources,
  dependencies: core_dependency, vala_args: ['--pkg=posix'])
test('desktop-settings', find_program('dbus-run-session'),
  args: [desktop_settings_tests], env: test_environment)
plan_tests = executable('plan-tests', 'plan-tests.vala', core_resources,
  dependencies: core_dependency, vala_args: ['--pkg=posix'])
test('plan', plan_tests, env: test_environment)
upstream_tests = executable('upstream-tests', 'upstream-tests.vala', core_resources,
  dependencies: core_dependency, vala_args: ['--pkg=posix'])
test('upstream', upstream_tests, env: test_environment)
executable('upstream-smoke', 'upstream-smoke.vala', core_resources,
  dependencies: core_dependency, vala_args: ['--pkg=posix'])
helper_tests = executable('helper-tests', 'helper-tests.vala', core_resources,
  dependencies: privileged_dependency, vala_args: ['--pkg=posix'])
test('helper', helper_tests, env: test_environment)
packages_tests = executable('packages-tests', 'options-packages.vala',
  dependencies: privileged_dependency)
test('packages', packages_tests, env: test_environment)
helper_test_environment = environment()
helper_test_environment.set('MIUUTIL_TEST_HELPER', helper.full_path())
test('helper-scripts', python, args: files('helper-script-tests.py'), env: helper_test_environment, depends: helper)
test('ci-build', python, args: files('ci-build-tests.py'))
test('launcher', python, args: files('launcher-tests.py'), timeout: 120)
ui_tests = executable('ui-tests', 'ui-tests.vala', core_resources, dependencies: ui_dependency,
  vala_args: ['--pkg=posix'])
test('ui', find_program('dbus-run-session'),
  args: [find_program('xvfb-run').full_path(), '-a', ui_tests],
  env: test_environment, timeout: 120)
