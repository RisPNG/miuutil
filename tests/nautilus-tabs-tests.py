import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


DBUS_CONFIGURATION = """<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
"""

OBSERVER = """import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gio, GLib, GObject, Gtk, Nautilus

class TabSelectionObserver(GObject.GObject, Nautilus.ColumnProvider):
    def __init__(self):
        super().__init__()
        self.application = Gio.Application.get_default()
        action = Gio.SimpleAction.new_stateful('test-tab-selection', None, GLib.Variant('as', []))
        action.connect('activate', self.inspect_selection)
        self.application.add_action(action)
        for name in ('test-new-tab-open', 'test-new-window-open'):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new('s'))
            action.connect('activate', self.open_from_native_action)
            self.application.add_action(action)

    def get_columns(self):
        return []

    def open_from_native_action(self, action, parameter):
        if action.get_name() == 'test-new-tab-open':
            self.application.get_active_window().lookup_action('new-tab').activate(None)
        else:
            self.application.lookup_action('new-window').activate(None)
        self.application.open([Gio.File.new_for_uri(parameter.get_string())], '')

    def inspect_selection(self, action, parameter):
        window = self.application.get_active_window()
        widgets = [window.get_property('active-slot')]
        selected = []
        while widgets:
            widget = widgets.pop()
            if isinstance(widget, (Gtk.GridView, Gtk.ColumnView, Gtk.ListView)):
                model = widget.get_model()
                for index in range(model.get_n_items()):
                    if not model.is_selected(index):
                        continue
                    item = model.get_item(index)
                    if isinstance(item, Gtk.TreeListRow):
                        item = item.get_item()
                    selected.append(item.get_property('file').get_uri())
                break
            child = widget.get_first_child()
            while child:
                widgets.append(child)
                child = child.get_next_sibling()
        action.set_state(GLib.Variant('as', selected))
"""


def run_session(directory, enabled, service=False):
    from gi.repository import Gio, GLib

    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def call(path, interface, method, parameters=None):
        return connection.call_sync('org.gnome.Nautilus', path, interface, method, parameters,
                                    None, Gio.DBusCallFlags.NO_AUTO_START, 1000, None)

    def windows():
        return call('/org/freedesktop/FileManager1', 'org.freedesktop.DBus.Properties', 'Get',
                    GLib.Variant('(ss)', ('org.freedesktop.FileManager1', 'OpenWindowsWithLocations'))).unpack()[0]

    def wait_for(predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                result = predicate()
                if result:
                    return result
            except GLib.Error:
                pass
            time.sleep(0.05)
        raise AssertionError('Nautilus did not reach the expected state.')

    def tabs(count):
        opened = windows()
        return len(opened) == 1 and len(next(iter(opened.values()))) == count

    def selected_items(expected):
        call('/org/gnome/Nautilus', 'org.gtk.Actions', 'Activate',
             GLib.Variant('(sava{sv})', ('test-tab-selection', [], {})))
        state = call('/org/gnome/Nautilus', 'org.gtk.Actions', 'Describe',
                     GLib.Variant('(s)', ('test-tab-selection',))).unpack()[0][2][0]
        return set(state) == expected

    first = directory / 'first'
    second = directory / 'second'
    first.mkdir()
    second.mkdir()
    (second / 'directory').mkdir()
    (second / 'selected.txt').write_text('sample')
    (second / 'archive.zip').write_bytes(b'PK\x05\x06' + bytes(18))
    output = (directory / 'nautilus.log').open('w+')
    broadway = subprocess.Popen(['gtk4-broadwayd', ':9'], stdout=output, stderr=output)
    nautilus = None
    try:
        time.sleep(0.2)
        nautilus = subprocess.Popen(['nautilus', '--gapplication-service'] if service else ['nautilus', str(first)],
                                    stdout=output, stderr=output)
        if service:
            wait_for(lambda: windows() == {})
            call('/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1', 'ShowItems',
                 GLib.Variant('(ass)', ([(second / 'selected.txt').as_uri()], '')))
        wait_for(lambda: len(windows()) == 1)
        if service:
            wait_for(lambda: selected_items({(second / 'selected.txt').as_uri()}))
        subprocess.run(['nautilus', *([] if enabled else ['--new-window']), str(second)], check=True, timeout=10)
        if not enabled:
            wait_for(lambda: len(windows()) == 2)
            return
        wait_for(lambda: tabs(2))
        subprocess.run(['gio', 'open', str(first)], check=True, timeout=10)
        wait_for(lambda: tabs(3))
        call('/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1', 'ShowFolders',
             GLib.Variant('(ass)', ([second.as_uri()], '')))
        wait_for(lambda: tabs(4))
        call('/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1', 'ShowFolders',
             GLib.Variant('(ass)', ([first.as_uri(), second.as_uri()], '')))
        wait_for(lambda: tabs(6))
        expected_selection = {(second / name).as_uri() for name in ('selected.txt', 'archive.zip', 'directory')}
        call('/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1', 'ShowItems',
             GLib.Variant('(ass)', (sorted(expected_selection), '')))
        wait_for(lambda: tabs(7))

        wait_for(lambda: selected_items(expected_selection))
        assert sorted(windows().values())[0] == [second.as_uri() if service else first.as_uri(), second.as_uri(), first.as_uri(),
                                                 second.as_uri(), first.as_uri(), second.as_uri(), second.as_uri()]
        children = [subprocess.Popen(['nautilus', str(path)], stdout=output, stderr=output)
                    for path in (first, second, first)]
        for child in children:
            assert child.wait(timeout=10) == 0
        wait_for(lambda: tabs(10))
        subprocess.run(['nautilus', '--select', str(second / 'selected.txt')], check=True, timeout=10)
        wait_for(lambda: tabs(11))
        call('/org/gnome/Nautilus', 'org.freedesktop.Application', 'Activate', GLib.Variant('(a{sv})', ({},)))
        wait_for(lambda: tabs(12))
        subprocess.run(['nautilus', '--new-window', str(second)], check=True, timeout=10)
        wait_for(lambda: tabs(13))
        call('/org/gnome/Nautilus', 'org.gtk.Application', 'Open',
             GLib.Variant('(assa{sv})', ([first.as_uri()], 'new-window', {})))
        wait_for(lambda: tabs(14))
        call('/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1', 'ShowFolders',
             GLib.Variant('(ass)', ([(directory / 'missing').as_uri(), first.as_uri()], '')))
        wait_for(lambda: tabs(16) and next(iter(windows().values()))[-1] == first.as_uri())
        call('/org/gnome/Nautilus', 'org.gtk.Actions', 'Activate',
             GLib.Variant('(sava{sv})', ('test-new-tab-open', [GLib.Variant('s', second.as_uri())], {})))
        wait_for(lambda: tabs(18))
        call('/org/gnome/Nautilus', 'org.gtk.Actions', 'Activate',
             GLib.Variant('(sava{sv})', ('test-new-window-open', [GLib.Variant('s', first.as_uri())], {})))
        wait_for(lambda: len(windows()) == 2 and sorted(len(locations) for locations in windows().values()) == [2, 18])
        properties = call('/org/freedesktop/FileManager1', 'org.freedesktop.DBus.Properties', 'GetAll',
                          GLib.Variant('(s)', ('org.freedesktop.FileManager1',))).unpack()[0]
        assert 'OpenLocations' in properties and 'OpenWindowsWithLocations' in properties
    except Exception:
        try:
            sys.stderr.write('Open windows: ' + repr(windows()) + '\n')
        except Exception:
            pass
        output.flush()
        output.seek(0)
        sys.stderr.write(output.read())
        raise
    finally:
        if nautilus is not None:
            nautilus.terminate()
            nautilus.wait(timeout=10)
        broadway.terminate()
        broadway.wait(timeout=10)
        output.close()


@unittest.skipUnless(shutil.which('nautilus') and shutil.which('gtk4-broadwayd') and
                     list(Path('/usr/lib').glob('*/nautilus/extensions-4/libmiu*-nautilus-tabs.so')),
                     'Install Nautilus, its compiled Miu extension and libgtk-4-bin in the disposable test environment.')
class NautilusTabTests(unittest.TestCase):
    def check_session(self, enabled, service=False):
        with tempfile.TemporaryDirectory(prefix='miu-nautilus-tabs-') as temporary:
            directory = Path(temporary)
            configuration = directory / 'config/miu'
            configuration.mkdir(parents=True)
            (configuration / 'nautilus-tabs.conf').write_text(
                '[Nautilus]\nexternal-tabs=' + str(enabled).lower() + '\n')
            extensions = directory / 'data/nautilus-python/extensions'
            extensions.mkdir(parents=True)
            (extensions / 'tab_selection_observer.py').write_text(OBSERVER)
            runtime = directory / 'runtime'
            runtime.mkdir(mode=0o700)
            bus = directory / 'dbus.conf'
            bus.write_text(DBUS_CONFIGURATION)
            environment = dict(os.environ, GDK_BACKEND='broadway', BROADWAY_DISPLAY=':9',
                               GIO_USE_VFS='local', GSETTINGS_BACKEND='memory', GTK_USE_PORTAL='0',
                               XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(directory / 'config'),
                               XDG_DATA_HOME=str(directory / 'data'), PYTHONHOME='/usr',
                               PYTHONPATH='/usr/lib/python3/dist-packages', PATH='/usr/bin:/bin')
            environment.pop('DISPLAY', None)
            environment.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run(['dbus-run-session', '--config-file=' + str(bus), '--',
                                     '/usr/bin/python3', str(Path(__file__).resolve()), '--session',
                                     str(directory), str(enabled).lower() + ('-service' if service else '')], env=environment,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_external_calls_append_tabs_and_preserve_selection(self):
        self.check_session(True)

    def test_disabled_configuration_preserves_native_windows(self):
        self.check_session(False)

    def test_first_file_manager_reveal_opens_one_window(self):
        self.check_session(True, service=True)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--session':
        run_session(Path(sys.argv[2]), sys.argv[3].startswith('true'), sys.argv[3].endswith('-service'))
    else:
        unittest.main()
