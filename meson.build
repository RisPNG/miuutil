project('miuutil', ['vala', 'c'],
  version: '0.1.6',
  meson_version: '>= 1.0',
  license: '0BSD',
  default_options: ['warning_level=2', 'buildtype=debugoptimized'])

gnome = import('gnome')
i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="miuutil"', language: 'c')
python = import('python').find_installation('python3')
blueprint = find_program('blueprint-compiler', version: '>= 0.16')
common_dependencies = [
  dependency('glib-2.0', version: '>= 2.84'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('json-glib-1.0', version: '>= 1.8'),
]
ui_dependencies = common_dependencies + [
  dependency('gtk4', version: '>= 4.18'),
  dependency('libadwaita-1', version: '>= 1.7'),
]

configuration = configuration_data()
configuration.set('VERSION', meson.project_version())
configuration.set('LOCALE_DIR', get_option('prefix') / get_option('localedir'))
configuration.set('DATA_DIR', get_option('prefix') / get_option('datadir') / 'miuutil')
configuration.set('LIBEXEC_DIR', get_option('prefix') / get_option('libexecdir') / 'miuutil')
configuration.set('HELPER_PATH', get_option('prefix') / get_option('libexecdir') / 'miuutil' / 'miuutil-helper')

subdir('src')
subdir('data')
subdir('tests')
subdir('po')
