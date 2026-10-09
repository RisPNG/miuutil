install_data('com.rispeng.MiuUtil.desktop', install_dir: get_option('datadir') / 'applications')
install_data('com.rispeng.MiuUtil.metainfo.xml', install_dir: get_option('datadir') / 'metainfo')
install_data('com.rispeng.MiuUtil.gschema.xml', install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')
gnome.compile_schemas(depend_files: files('com.rispeng.MiuUtil.gschema.xml'))
configure_file(input: 'com.rispeng.MiuUtil.policy.in', output: 'com.rispeng.MiuUtil.policy',
  configuration: configuration, install: true,
  install_dir: get_option('datadir') / 'polkit-1' / 'actions')
install_subdir('helpers', install_dir: get_option('libexecdir') / 'miuutil', strip_directory: true,
  exclude_files: ['nautilus-tabs.c'])
nautilus_extension = dependency('libnautilus-extension-4')
shared_module('miuutil-nautilus-tabs', 'helpers/nautilus-tabs.c',
  dependencies: [nautilus_extension] + ui_dependencies,
  install: true, install_dir: nautilus_extension.get_variable(pkgconfig: 'extensiondir'))
install_subdir('recovery', install_dir: get_option('datadir') / 'miuutil')
install_subdir('icons/hicolor', install_dir: get_option('datadir') / 'icons')
gnome.post_install(glib_compile_schemas: true, gtk_update_icon_cache: true, update_desktop_database: true)
