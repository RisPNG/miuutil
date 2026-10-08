config_source = configure_file(input: 'config.vala.in', output: 'config.vala', configuration: configuration)
core_resources = gnome.compile_resources('miuutil-core-resources', files('miuutil-core.gresource.xml'),
  source_dir: meson.current_source_dir(), c_name: 'miuutil_core', export: true)

core_sources = files(
  'core/option.vala', 'core/catalogue.vala', 'core/change-plan.vala', 'core/setup-session.vala',
  'core/operations/desktop-settings.vala', 'core/operations/configuration-files.vala',
  'core/operations/packages.vala', 'core/operations/upstream-installs.vala')
core_library = static_library('miuutil-core', core_sources, config_source,
  dependencies: common_dependencies, vala_args: ['--pkg=posix'],
  vala_header: 'miuutil-core.h', vala_vapi: 'miuutil-core.vapi', install: false)
core_dependency = declare_dependency(link_with: core_library, dependencies: common_dependencies,
  include_directories: include_directories('.'))

blueprints = files('ui/window.blp', 'ui/option-row.blp', 'ui/review-page.blp')
ui_templates = custom_target('ui-templates', input: blueprints,
  output: ['window.ui', 'option-row.ui', 'review-page.ui'],
  command: [blueprint, 'batch-compile', '@OUTDIR@', meson.current_source_dir() / 'ui', '@INPUT@'])
ui_resources = gnome.compile_resources('miuutil-resources', files('miuutil.gresource.xml'),
  c_name: 'miuutil_ui', source_dir: [meson.current_build_dir(), meson.current_source_dir()], dependencies: ui_templates)

ui_library = static_library('miuutil-ui', files('application.vala', 'ui/window.vala',
  'ui/option-row.vala', 'ui/review-page.vala'), ui_resources,
  dependencies: [core_dependency] + ui_dependencies, vala_args: ['--pkg=posix'],
  vala_header: 'miuutil-ui.h', vala_vapi: 'miuutil-ui.vapi', install: false)
ui_dependency = declare_dependency(link_whole: ui_library,
  dependencies: [core_dependency] + ui_dependencies, include_directories: include_directories('.'))
miuutil = executable('miuutil', files('main.vala'), core_resources,
  dependencies: ui_dependency, vala_args: ['--pkg=posix'],
  install: true)
privileged_library = static_library('miuutil-privileged', files('privileged/operations.vala',
  'core/operations/debian-packages.vala'), config_source,
  dependencies: common_dependencies, vala_args: ['--pkg=posix'],
  vala_header: 'miuutil-privileged.h', vala_vapi: 'miuutil-privileged.vapi', install: false)
privileged_dependency = declare_dependency(link_with: privileged_library,
  dependencies: common_dependencies, include_directories: include_directories('.'))
helper = executable('miuutil-helper', files('privileged/helper.vala'), core_resources,
  dependencies: privileged_dependency, vala_args: ['--pkg=posix'],
  install: true, install_dir: get_option('libexecdir') / 'miuutil')
