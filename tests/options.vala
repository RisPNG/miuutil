using MiuUtil;

private string workspace;
private string test_program;

private const string CURSOR_FIXTURE = """
import ctypes
import os
from pathlib import Path
import struct
import sys

mode, root = sys.argv[1:]
icons = Path(root) / 'data' / 'icons'
pixels = {'fluent-dark': 0xff123456, 'fluent': 0xff654321}
if mode == 'create':
    (icons / 'Fluent-dark').mkdir(parents=True, exist_ok=True)
    (icons / 'Fluent-dark' / 'index.theme').write_text('[Icon Theme]\nName=Fluent dark\n')
    for theme, pixel in pixels.items():
        directory = icons / theme / 'cursors'
        directory.mkdir(parents=True, exist_ok=True)
        (directory.parent / 'index.theme').write_text('[Icon Theme]\nName=' + theme + '\n')
        (directory / 'left_ptr').write_bytes(struct.pack('<17I',
            0x72756358, 16, 0x10000, 1, 0xfffd0002, 24, 28,
            36, 0xfffd0002, 24, 1, 1, 1, 0, 0, 0, pixel))
    sys.exit(0)

assert os.environ['XCURSOR_PATH'] == '~/.icons:/usr/share/icons:/usr/share/pixmaps'
class Image(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('version', 'size', 'width', 'height', 'xhot', 'yhot', 'delay')]
    _fields_.append(('pixels', ctypes.POINTER(ctypes.c_uint32)))

library = ctypes.CDLL('libXcursor.so.1')
library.XcursorLibraryLoadImage.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int)
library.XcursorLibraryLoadImage.restype = ctypes.POINTER(Image)
library.XcursorImageDestroy.argtypes = (ctypes.POINTER(Image),)
for theme, pixel in pixels.items():
    image = library.XcursorLibraryLoadImage(b'left_ptr', theme.encode(), 24)
    matching = bool(image) and image.contents.width == 1 and image.contents.height == 1 \
        and image.contents.pixels[0] == pixel
    if image:
        library.XcursorImageDestroy(image)
    assert matching == (mode == 'published'), (theme, mode, matching)
""";

private void compile_sandbox_schema (string directory, string xml) throws Error {
    DirUtils.create_with_parents (directory, 0700);
    FileUtils.set_contents (directory + "/runtime.gschema.xml", xml);
    var compiler = new Subprocess.newv ({ "glib-compile-schemas", directory }, SubprocessFlags.NONE);
    compiler.wait_check ();
}

private Option schema_option (string schema, string key, string value) throws Error {
    var definition = new Json.Object ();
    definition.set_string_member ("id", "runtime-schema-fixture");
    definition.set_string_member ("title", "Runtime schema fixture");
    definition.set_string_member ("description", "Configure a schema installed during this session.");
    definition.set_string_member ("category", "desktop");
    definition.set_string_member ("scope", "Your account");
    definition.set_string_member ("risk", "Low");
    definition.set_string_member ("desired", value);
    definition.set_string_member ("details", "Native schema refresh regression.");
    definition.set_boolean_member ("requires_admin", false);
    definition.set_array_member ("dependencies", new Json.Array ());
    var entry = new Json.Object ();
    entry.set_string_member ("schema", schema);
    entry.set_string_member ("key", key);
    entry.set_string_member ("value", value);
    var settings = new Json.Array ();
    settings.add_object_element (entry);
    var operation = new Json.Object ();
    operation.set_string_member ("kind", "settings");
    operation.set_array_member ("settings", settings);
    definition.set_object_member ("operation", operation);
    return new Option (definition);
}

private class ProcessFixture : Operation {
    public string captured { get; private set; }
    private bool failure;

    public ProcessFixture (bool failure = false) {
        this.failure = failure;
    }

    public override async Assessment inspect (Cancellable? cancellable) throws Error {
        return new Assessment (OptionState.DIFFERENT, "Process output fixture");
    }

    public override async void apply (Cancellable? cancellable) throws Error {
        captured = yield run_process ({ test_program, failure ? "--stream-failure" : "--stream-fixture", workspace + "/process-complete" }, cancellable);
    }
}

private Option catalogue_option (string identity) throws Error {
    var catalogue = new Catalogue ();
    for (uint index = 0; index < catalogue.options.get_n_items (); index++) {
        var option = (Option) catalogue.options.get_item (index);
        if (option.id == identity)
            return option;
    }
    throw new IOError.NOT_FOUND (identity);
}

private void inspect_option (Option option) {
    var loop = new MainLoop ();
    option.detect.begin (null, (object, result) => {
        try {
            option.detect.end (result);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
        loop.quit ();
    });
    loop.run ();
}

private void apply_option (Option option) {
    var loop = new MainLoop ();
    option.apply.begin (null, (object, result) => {
        try {
            option.apply.end (result);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
        loop.quit ();
    });
    loop.run ();
}

int main (string[] arguments) {
    if (arguments.length > 1 && arguments[1] == "--default-application") {
        var application = AppInfo.get_default_for_type (arguments[2], false);
        if (application == null)
            return 1;
        stdout.printf ("%s\n", application.get_id ());
        return 0;
    }
    if (arguments.length > 1 && (arguments[1] == "--stream-fixture" || arguments[1] == "--stream-failure")) {
        stdout.printf ("first line\n");
        stdout.flush ();
        Thread.usleep (100000);
        for (uint index = 0; index < 100; index++) {
            stdout.printf ("%s\n", string.nfill (1024, 'x'));
            stderr.printf ("%s\n", string.nfill (1024, 'y'));
        }
        try {
            FileUtils.set_contents (arguments[2], "complete");
        } catch (Error error) {
            return 2;
        }
        stdout.printf ("last output line\n");
        stderr.printf ("last diagnostic line\n");
        return arguments[1] == "--stream-failure" ? 7 : 0;
    }
    test_program = Filename.canonicalize (arguments[0]);
    Test.init (ref arguments);
    try {
        workspace = DirUtils.make_tmp ("miuutil-options-XXXXXX");
    } catch (Error error) {
        critical ("%s", error.message);
        return 1;
    }
    Environment.set_variable ("HOME", workspace, true);
    Environment.set_variable ("XDG_CONFIG_HOME", workspace + "/config", true);
    Environment.set_variable ("XDG_DATA_HOME", workspace + "/data", true);
    Environment.set_variable ("XDG_STATE_HOME", workspace + "/state", true);
    Environment.set_variable ("XDG_DATA_DIRS", workspace + "/system-high:" + workspace + "/system-low:/usr/local/share:/usr/share", true);
    Environment.set_variable ("GSETTINGS_BACKEND", "memory", true);

    Test.add_func ("/options/schemas-installed-and-upgraded-during-session", () => {
        try {
            var directory = workspace + "/system-high/glib-2.0/schemas";
            compile_sandbox_schema (directory, """
                <schemalist>
                  <schema id="com.rispeng.MiuUtil.RuntimeUpgrade" path="/com/rispeng/miuutil/runtime-upgrade/">
                    <key name="count" type="i"><default>0</default><range min="0" max="1"/></key>
                  </schema>
                </schemalist>
                """);
            var cached = SettingsSchemaSource.get_default ();
            var old_schema = cached.lookup ("com.rispeng.MiuUtil.RuntimeUpgrade", true);
            assert (old_schema != null);
            assert (!old_schema.has_key ("late"));
            assert (cached.lookup ("com.rispeng.MiuUtil.RuntimeAdded", true) == null);
            var range = schema_option ("com.rispeng.MiuUtil.RuntimeUpgrade", "count", "8");
            inspect_option (range);
            assert (range.state == OptionState.UNAVAILABLE);
            var added = schema_option ("com.rispeng.MiuUtil.RuntimeAdded", "enabled", "true");
            inspect_option (added);
            assert (added.state == OptionState.UNAVAILABLE);
            compile_sandbox_schema (directory, """
                <schemalist>
                  <schema id="com.rispeng.MiuUtil.RuntimeUpgrade" path="/com/rispeng/miuutil/runtime-upgrade/">
                    <key name="count" type="i"><default>0</default><range min="0" max="10"/></key>
                    <key name="late" type="b"><default>false</default></key>
                  </schema>
                  <schema id="com.rispeng.MiuUtil.RuntimeAdded" path="/com/rispeng/miuutil/runtime-added/">
                    <key name="enabled" type="b"><default>false</default></key>
                  </schema>
                </schemalist>
                """);
            assert (cached.lookup ("com.rispeng.MiuUtil.RuntimeAdded", true) == null);
            assert (!old_schema.has_key ("late"));
            inspect_option (added);
            assert (added.state == OptionState.DIFFERENT);
            apply_option (added);
            assert (added.state == OptionState.MATCHING);
            apply_option (range);
            assert (range.state == OptionState.MATCHING);
            var new_key = schema_option ("com.rispeng.MiuUtil.RuntimeUpgrade", "late", "true");
            apply_option (new_key);
            assert (new_key.state == OptionState.MATCHING);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/process-streams-and-bounds-diagnostics", () => {
        var operation = new ProcessFixture ();
        bool progress_before_completion = false;
        operation.output.connect ((line) => {
            if (line == "first line")
                progress_before_completion = !FileUtils.test (workspace + "/process-complete", FileTest.EXISTS);
            assert_cmpuint (line.length, CompareOperator.LE, 16384);
        });
        var loop = new MainLoop ();
        operation.apply.begin (null, (object, result) => {
            try {
                operation.apply.end (result);
                assert (progress_before_completion);
                assert_cmpuint (operation.captured.length, CompareOperator.LE, 65536);
                assert (operation.captured.has_suffix ("last output line\n"));
            } catch (Error error) {
                Test.message (error.message);
                Test.fail ();
            }
            loop.quit ();
        });
        loop.run ();
        var failure = new ProcessFixture (true);
        failure.apply.begin (null, (object, result) => {
            try {
                failure.apply.end (result);
                Test.fail ();
            } catch (IOError.FAILED error) {
                assert (error.message.contains ("last diagnostic line"));
                assert_cmpuint (error.message.length, CompareOperator.LE, 66000);
            } catch (Error error) {
                Test.message (error.message);
                Test.fail ();
            }
            loop.quit ();
        });
        loop.run ();
    });

    Test.add_func ("/options/catalogue", () => {
        try {
            var catalogue = new Catalogue ();
            assert_cmpuint (catalogue.options.get_n_items (), CompareOperator.GE, 100);
            var categories = new HashTable<string, bool> (str_hash, str_equal);
            for (uint index = 0; index < catalogue.options.get_n_items (); index++) {
                var option = (Option) catalogue.options.get_item (index);
                assert (option.id != "" && option.title != "" && option.desired != "");
                categories.insert (option.category, true);
            }
            assert_cmpuint (categories.size (), CompareOperator.EQ, 8);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/git-preserves-identity", () => {
        try {
            var path = workspace + "/.gitconfig";
            FileUtils.set_contents (path, "[user]\nname=Existing User\nemail=existing@example.test\n[credential]\nhelper=cache\n");
            var option = catalogue_option ("development-git");
            inspect_option (option);
            assert (option.state == OptionState.DIFFERENT);
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            var configuration = new KeyFile ();
            configuration.load_from_file (path, KeyFileFlags.NONE);
            assert_cmpstr (configuration.get_string ("user", "name"), CompareOperator.EQ, "Existing User");
            assert_cmpstr (configuration.get_string ("user", "email"), CompareOperator.EQ, "existing@example.test");
            assert_cmpstr (configuration.get_string ("credential", "helper"), CompareOperator.EQ, "store");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/default-applications-cover-installed-mime-types", () => {
        try {
            var directory = workspace + "/data/mime/packages";
            DirUtils.create_with_parents (directory, 0700);
            FileUtils.set_contents (directory + "/defaults-fixture.xml", """
                <?xml version="1.0" encoding="UTF-8"?>
                <mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
                  <mime-type type="audio/vnd.miuutil-fixture"><glob pattern="*.miuaudio"/></mime-type>
                  <mime-type type="video/vnd.miuutil-fixture"><glob pattern="*.miuvideo"/></mime-type>
                  <mime-type type="image/vnd.miuutil-fixture"><glob pattern="*.miuimage"/></mime-type>
                  <mime-type type="application/vnd.miuutil-image"><sub-class-of type="image/png"/></mime-type>
                </mime-info>
                """.strip ());
            var database = new Subprocess.newv ({ "update-mime-database", workspace + "/data/mime" }, SubprocessFlags.NONE);
            database.wait_check ();
            ContentType.set_mime_dirs ({ workspace + "/data/mime", "/usr/share/mime" });
            var launchers = workspace + "/data/applications";
            DirUtils.create_with_parents (launchers, 0700);
            foreach (var desktop in new string[] { "mpv.desktop", "harmonoid.desktop", "qview.desktop", "vivaldi-stable.desktop" })
                FileUtils.set_contents (launchers + "/" + desktop, "[Desktop Entry]\nType=Application\nName=Default fixture\nExec=/bin/true %U\n");
            var exports = workspace + "/data/flatpak/exports/share/applications";
            DirUtils.create_with_parents (exports, 0700);
            var exported_pdf = exports + "/org.gnome.Evince.desktop";
            FileUtils.set_contents (exported_pdf, "[Desktop Entry]\nType=Application\nName=Evince export fixture\nExec=/bin/true %U\n");
            DirUtils.create_with_parents (workspace + "/config", 0700);
            var path = workspace + "/config/mimeapps.list";
            FileUtils.set_contents (path, """
                [Default Applications]
                text/plain=personal-editor.desktop;
                audio/webm=old-audio.desktop;
                [Added Associations]
                video/mp4=other-video.desktop;
                audio/mpeg=other-audio.desktop;
                [Removed Associations]
                video/mp4=mpv.desktop;blocked-video.desktop;
                audio/mpeg=mpv.desktop;blocked-audio.desktop;
                text/plain=blocked-editor.desktop;
                """);
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            foreach (var id in new string[] { "applications-default-audio", "applications-default-image", "applications-default-video", "applications-default-pdf", "browsers-default" }) {
                foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
                    var definition = node.get_object ();
                    if (definition.get_string_member ("id") != id)
                        continue;
                    definition.get_object_member ("operation").remove_member ("required_programs");
                    var option = new Option (definition);
                    if (id == "applications-default-pdf") {
                        assert (new DesktopAppInfo.from_filename (exported_pdf) != null);
                        inspect_option (option);
                        assert (option.state == OptionState.DIFFERENT);
                    }
                    apply_option (option);
                    assert (option.state == OptionState.MATCHING);
                    if (id == "applications-default-pdf")
                        File.new_for_path (exported_pdf).copy (File.new_for_path (launchers + "/org.gnome.Evince.desktop"), FileCopyFlags.NONE);
                }
            }
            var associations = new KeyFile ();
            associations.load_from_file (path, KeyFileFlags.NONE);
            foreach (var type in new string[] { "audio/mpeg", "audio/webm", "audio/vnd.miuutil-fixture", "application/xspf+xml" })
                assert_cmpstr (associations.get_string ("Default Applications", type), CompareOperator.EQ, "harmonoid.desktop;mpv.desktop;");
            foreach (var type in new string[] { "video/mp4", "video/x-mjpeg", "video/vnd.miuutil-fixture", "application/ogg" })
                assert_cmpstr (associations.get_string ("Default Applications", type), CompareOperator.EQ, "mpv.desktop;");
            foreach (var type in new string[] { "image/png", "image/avif", "image/vnd.miuutil-fixture", "application/vnd.miuutil-image", "application/x-krita" })
                assert_cmpstr (associations.get_string ("Default Applications", type), CompareOperator.EQ, "qview.desktop;");
            assert_cmpstr (associations.get_string ("Default Applications", "application/pdf"), CompareOperator.EQ, "org.gnome.Evince.desktop;");
            assert_cmpstr (associations.get_string ("Default Applications", "application/xhtml+xml"), CompareOperator.EQ, "vivaldi-stable.desktop;");
            assert_cmpstr (associations.get_string ("Default Applications", "text/plain"), CompareOperator.EQ, "personal-editor.desktop;");
            assert_cmpstr (associations.get_string ("Added Associations", "video/mp4"), CompareOperator.EQ, "mpv.desktop;other-video.desktop;");
            assert_cmpstr (associations.get_string ("Added Associations", "audio/mpeg"), CompareOperator.EQ, "harmonoid.desktop;mpv.desktop;other-audio.desktop;");
            assert_cmpstr (associations.get_string ("Removed Associations", "video/mp4"), CompareOperator.EQ, "blocked-video.desktop;");
            assert_cmpstr (associations.get_string ("Removed Associations", "audio/mpeg"), CompareOperator.EQ, "blocked-audio.desktop;");
            assert_cmpstr (associations.get_string ("Removed Associations", "text/plain"), CompareOperator.EQ, "blocked-editor.desktop;");
            assert (!associations.has_key ("Default Applications", "video/*"));
            assert (!associations.has_key ("Default Applications", "audio/*"));
            assert (!associations.has_key ("Default Applications", "image/*"));
            foreach (var type in new string[] { "audio/vnd.miuutil-fixture", "video/vnd.miuutil-fixture", "image/vnd.miuutil-fixture", "application/pdf", "text/html" }) {
                var probe = new Subprocess.newv ({ test_program, "--default-application", type },
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                string selected;
                probe.communicate_utf8 (null, null, out selected, null);
                assert (probe.get_successful ());
                assert_cmpstr (selected.strip (), CompareOperator.EQ, associations.get_string_list ("Default Applications", type)[0]);
            }
            var fallback_data = workspace + "/audio-fallback-data";
            DirUtils.create_with_parents (fallback_data + "/applications", 0700);
            File.new_for_path (launchers + "/mpv.desktop").copy (
                File.new_for_path (fallback_data + "/applications/mpv.desktop"), FileCopyFlags.NONE);
            string saved;
            FileUtils.get_contents (path, out saved);
            foreach (var desktop in new string[] { "mpv.desktop", "harmonoid.desktop" }) {
                if (desktop == "harmonoid.desktop")
                    File.new_for_path (launchers + "/harmonoid.desktop").copy (
                        File.new_for_path (fallback_data + "/applications/harmonoid.desktop"), FileCopyFlags.NONE);
                foreach (var type in new string[] { "audio/mpeg", "application/xspf+xml" }) {
                    var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                    launcher.setenv ("XDG_DATA_HOME", fallback_data, true);
                    launcher.setenv ("XDG_DATA_DIRS", workspace + "/system-high:" + workspace + "/system-low", true);
                    var probe = launcher.spawnv ({ test_program, "--default-application", type });
                    string selected;
                    probe.communicate_utf8 (null, null, out selected, null);
                    assert (probe.get_successful ());
                    assert_cmpstr (selected.strip (), CompareOperator.EQ, desktop);
                }
                string retained;
                FileUtils.get_contents (path, out retained);
                assert_cmpstr (retained, CompareOperator.EQ, saved);
            }
            foreach (var desktop in new string[] { "mpv.desktop", "harmonoid.desktop", "qview.desktop", "org.gnome.Evince.desktop", "vivaldi-stable.desktop" })
                FileUtils.remove (launchers + "/" + desktop);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
        ContentType.set_mime_dirs (null);
    });

    Test.add_func ("/options/mpv-preserves-other-keys", () => {
        try {
            var directory = workspace + "/config/mpv";
            DirUtils.create_with_parents (directory + "/script-opts", 0700);
            FileUtils.set_contents (directory + "/mpv.conf",
                "volume=42\nkeep-open=no\nwatch-later-options-remove=volume,speed\nwatch-later-options-remove=gamma\n");
            FileUtils.set_contents (directory + "/script-opts/modernz.conf",
                "window_top_bar=always\nlayout=compact\nicon_theme=material\nicon_style=outline\nseekbar_height=large\nnibbles_style=bar\n");
            FileUtils.set_contents (directory + "/script-opts/thumbfast.conf", "network=yes\n");
            var option = catalogue_option ("applications-mpv");
            assert ("applications-modernz" in option.dependencies);
            assert ("applications-thumbfast" in option.dependencies);
            apply_option (option);
            string content;
            FileUtils.get_contents (directory + "/mpv.conf", out content);
            assert (content.contains ("volume=42"));
            assert (content.contains ("keep-open=always"));
            assert (!content.contains ("keep-open=no"));
            assert (content.contains ("osc=no"));
            assert (content.contains ("watch-later-options-remove=sub-pos"));
            assert (content.contains ("watch-later-options-remove=volume,speed"));
            assert (content.contains ("watch-later-options-remove=gamma"));
            assert_cmpuint (content.split ("watch-later-options-remove=sub-pos").length, CompareOperator.EQ, 2);
            var saved = content;
            apply_option (option);
            FileUtils.get_contents (directory + "/mpv.conf", out content);
            assert_cmpstr (content, CompareOperator.EQ, saved);
            FileUtils.get_contents (directory + "/script-opts/modernz.conf", out content);
            assert (content.contains ("window_top_bar=always"));
            assert (content.contains ("layout=default"));
            assert (content.contains ("icon_theme=fluent"));
            assert (content.contains ("icon_style=mixed"));
            assert (content.contains ("seekbar_height=medium"));
            assert (content.contains ("nibbles_style=triangle"));
            assert (!content.contains ("layout=compact"));
            assert (!content.contains ("icon_theme=material"));
            FileUtils.get_contents (directory + "/script-opts/thumbfast.conf", out content);
            assert_cmpstr (content, CompareOperator.EQ, "network=yes\n");
            assert (option.state == OptionState.MATCHING);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/modernz-requires-font-and-backs-up-uosc", () => {
        try {
            var directory = workspace + "/config/mpv";
            DirUtils.create_with_parents (directory + "/scripts/uosc", 0700);
            DirUtils.create_with_parents (directory + "/fonts", 0700);
            DirUtils.create_with_parents (directory + "/script-opts", 0700);
            FileUtils.set_contents (directory + "/scripts/modernz.lua", "existing ModernZ script");
            FileUtils.set_contents (directory + "/scripts/thumbfast.lua", "existing thumbfast script");
            FileUtils.set_contents (directory + "/scripts/uosc/main.lua", "old uosc script");
            FileUtils.set_contents (directory + "/scripts/personal.lua", "personal script");
            File.new_for_path (directory + "/scripts/uosc.lua").make_symbolic_link ("personal.lua");
            FileUtils.set_contents (directory + "/scripts/uosc_shared.lua", "old uosc library");
            FileUtils.set_contents (directory + "/script-opts/modernz.conf", "layout=compact\n");
            FileUtils.set_contents (directory + "/fonts/personal.ttf", "personal font");
            var option = catalogue_option ("applications-modernz");
            inspect_option (option);
            assert (option.state != OptionState.MATCHING);
            FileUtils.set_contents (directory + "/fonts/modernz-icons.ttf", "existing ModernZ font");
            inspect_option (option);
            assert (option.state == OptionState.PARTIAL);
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert (!FileUtils.test (directory + "/scripts/uosc", FileTest.EXISTS));
            assert (!FileUtils.test (directory + "/scripts/uosc.lua", FileTest.IS_SYMLINK));
            assert (!FileUtils.test (directory + "/scripts/uosc_shared.lua", FileTest.EXISTS));
            var backups = File.new_for_path (workspace + "/state/miuutil/backups/applications-modernz")
                .enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
            var saved = backups.next_file ();
            assert (saved != null);
            var backup = workspace + "/state/miuutil/backups/applications-modernz/" + saved.get_name ();
            string content;
            FileUtils.get_contents (backup + "/uosc/main.lua", out content);
            assert_cmpstr (content, CompareOperator.EQ, "old uosc script");
            assert_cmpstr (FileUtils.read_link (backup + "/uosc.lua"), CompareOperator.EQ, "personal.lua");
            FileUtils.get_contents (backup + "/uosc_shared.lua", out content);
            assert_cmpstr (content, CompareOperator.EQ, "old uosc library");
            foreach (var retained in new string[] { "scripts/modernz.lua", "scripts/thumbfast.lua", "scripts/personal.lua",
                "script-opts/modernz.conf", "fonts/modernz-icons.ttf", "fonts/personal.ttf" }) {
                FileUtils.get_contents (directory + "/" + retained, out content);
                assert_cmpstr (content, CompareOperator.EQ,
                    retained == "scripts/modernz.lua" ? "existing ModernZ script" :
                    retained == "scripts/thumbfast.lua" ? "existing thumbfast script" :
                    retained == "scripts/personal.lua" ? "personal script" :
                    retained == "script-opts/modernz.conf" ? "layout=compact\n" :
                    retained == "fonts/modernz-icons.ttf" ? "existing ModernZ font" : "personal font");
            }
            var thumbfast = catalogue_option ("applications-thumbfast");
            inspect_option (thumbfast);
            assert (thumbfast.state == OptionState.MATCHING);
            apply_option (thumbfast);
            apply_option (option);
            assert (backups.next_file () == null);
            backups.close ();
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/firefox-preserves-personal-data", () => {
        try {
            var directory = workspace + "/.mozilla/firefox";
            DirUtils.create_with_parents (directory + "/personal", 0700);
            FileUtils.set_contents (directory + "/profiles.ini", "[Profile0]\nName=personal\nIsRelative=1\nPath=personal\nDefault=1\n");
            FileUtils.set_contents (directory + "/personal/user.js", "user_pref(\"personal.preference\", true);\n");
            FileUtils.set_contents (directory + "/personal/places.sqlite", "personal history sentinel");
            FileUtils.set_contents (directory + "/personal/logins.json", "saved login sentinel");
            FileUtils.set_contents (directory + "/personal/key4.db", "credential key sentinel");
            FileUtils.set_contents (directory + "/personal/cookies.sqlite", "signed-in cookie sentinel");
            DirUtils.create_with_parents (directory + "/personal/extensions", 0700);
            FileUtils.set_contents (directory + "/personal/extensions/personal@example.test.xpi", "personal addon sentinel");
            var option = catalogue_option ("browsers-firefox");
            apply_option (option);
            string content;
            FileUtils.get_contents (directory + "/personal/user.js", out content);
            assert (content.contains ("personal.preference"));
            assert (content.contains ("sidebar.verticalTabs"));
            assert (option.state == OptionState.MATCHING);
            FileUtils.get_contents (directory + "/personal/places.sqlite", out content);
            assert_cmpstr (content, CompareOperator.EQ, "personal history sentinel");
            FileUtils.get_contents (directory + "/personal/logins.json", out content);
            assert_cmpstr (content, CompareOperator.EQ, "saved login sentinel");
            FileUtils.get_contents (directory + "/personal/key4.db", out content);
            assert_cmpstr (content, CompareOperator.EQ, "credential key sentinel");
            FileUtils.get_contents (directory + "/personal/cookies.sqlite", out content);
            assert_cmpstr (content, CompareOperator.EQ, "signed-in cookie sentinel");
            FileUtils.get_contents (directory + "/personal/extensions/personal@example.test.xpi", out content);
            assert_cmpstr (content, CompareOperator.EQ, "personal addon sentinel");
            Posix.symlink ("stale-process", directory + "/personal/lock");
            inspect_option (option);
            assert (option.state == OptionState.UNAVAILABLE);
            FileUtils.remove (directory + "/personal/lock");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/firefox-install-default-precedes-legacy-profile-order", () => {
        try {
            var directory = workspace + "/.mozilla/firefox";
            DirUtils.create_with_parents (directory + "/legacy-default", 0700);
            DirUtils.create_with_parents (directory + "/installed-default", 0700);
            var legacy = "user_pref(\"legacy.personal.preference\", true);\n";
            var installed = "user_pref(\"installed.personal.preference\", true);\n";
            FileUtils.set_contents (directory + "/legacy-default/user.js", legacy);
            FileUtils.set_contents (directory + "/installed-default/user.js", installed);
            FileUtils.set_contents (directory + "/installed-default/prefs.js", "personal preference sentinel");
            var profiles = "[Profile1]\nName=Legacy\nIsRelative=1\nPath=legacy-default\nDefault=1\n\n[Profile0]\nName=Installed\nIsRelative=1\nPath=installed-default\n\n";
            var installation = "[InstallFixture]\nDefault=installed-default\nLocked=1\n\n";
            FileUtils.set_contents (directory + "/profiles.ini", profiles + installation);
            var option = catalogue_option ("browsers-firefox");
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            string configured;
            FileUtils.get_contents (directory + "/installed-default/user.js", out configured);
            assert (configured.has_prefix (installed));
            assert (configured.contains ("sidebar.verticalTabs"));
            string retained;
            FileUtils.get_contents (directory + "/legacy-default/user.js", out retained);
            assert_cmpstr (retained, CompareOperator.EQ, legacy);
            FileUtils.set_contents (directory + "/profiles.ini", installation + profiles);
            inspect_option (option);
            assert (option.state == OptionState.MATCHING);
            string reordered;
            FileUtils.get_contents (directory + "/installed-default/user.js", out reordered);
            assert_cmpstr (reordered, CompareOperator.EQ, configured);
            FileUtils.get_contents (directory + "/installed-default/prefs.js", out retained);
            assert_cmpstr (retained, CompareOperator.EQ, "personal preference sentinel");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/firefox-stale-native-lock-is-retained-and-held-during-updates", () => {
        try {
            var directory = workspace + "/.mozilla/firefox/lock-fixture";
            DirUtils.create_with_parents (directory, 0700);
            FileUtils.set_contents (workspace + "/.mozilla/firefox/profiles.ini", "[InstallFixture]\nDefault=lock-fixture\n");
            var lock_path = directory + "/.parentlock";
            FileUtils.set_contents (lock_path, "existing lock metadata sentinel");
            var signature = "127.0.1.1:+%d".printf (Posix.getpid ());
            Posix.symlink (signature, directory + "/lock");
            var option = catalogue_option ("browsers-firefox");
            inspect_option (option);
            assert (option.state == OptionState.DIFFERENT);
            bool held_during_update = false;
            option.output.connect ((message) => {
                if (!message.has_prefix ("Updated "))
                    return;
                try {
                    var probe = new Subprocess.newv ({ "python3", "-c",
                        "import fcntl,sys; f=open(sys.argv[1],'r+');\ntry: fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(0)\nelse: sys.exit(3)", lock_path }, SubprocessFlags.NONE);
                    probe.wait_check ();
                    held_during_update = true;
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
            });
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert (held_during_update);
            assert_cmpstr (FileUtils.read_link (directory + "/lock"), CompareOperator.EQ, signature);
            string metadata;
            FileUtils.get_contents (lock_path, out metadata);
            assert_cmpstr (metadata, CompareOperator.EQ, "existing lock metadata sentinel");
            var released = new Subprocess.newv ({ "python3", "-c",
                "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB)", lock_path }, SubprocessFlags.NONE);
            released.wait_check ();
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/firefox-active-native-lock-prevents-changes", () => {
        Subprocess? holder = null;
        try {
            var directory = workspace + "/.mozilla/firefox/busy-fixture";
            DirUtils.create_with_parents (directory, 0700);
            FileUtils.set_contents (workspace + "/.mozilla/firefox/profiles.ini", "[InstallFixture]\nDefault=busy-fixture\n");
            FileUtils.set_contents (directory + "/user.js", "personal preference sentinel");
            holder = new Subprocess.newv ({ "python3", "-c",
                "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB); print('locked',flush=True); sys.stdin.read()", directory + "/.parentlock" }, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
            var reader = new DataInputStream (holder.get_stdout_pipe ());
            assert_cmpstr (reader.read_line (), CompareOperator.EQ, "locked");
            var option = catalogue_option ("browsers-firefox");
            inspect_option (option);
            assert (option.state == OptionState.UNAVAILABLE);
            assert (option.current.contains ("Close Firefox"));
            var loop = new MainLoop ();
            bool rejected = false;
            option.apply.begin (null, (object, result) => {
                try {
                    option.apply.end (result);
                    Test.fail ();
                } catch (Error error) {
                    rejected = true;
                }
                loop.quit ();
            });
            loop.run ();
            assert (rejected);
            string retained;
            FileUtils.get_contents (directory + "/user.js", out retained);
            assert_cmpstr (retained, CompareOperator.EQ, "personal preference sentinel");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        } finally {
            if (holder != null) {
                try {
                    holder.get_stdin_pipe ().close ();
                    holder.wait_check ();
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
            }
        }
    });

    Test.add_func ("/options/nautilus-preserves-personal-actions", () => {
        try {
            var directory = workspace + "/data/actions-for-nautilus";
            DirUtils.create_with_parents (directory, 0700);
            FileUtils.set_contents (directory + "/config.json", "{\"actions\":[{\"type\":\"command\",\"label\":\"Personal action\",\"command_line\":\"example\"}],\"personal\":true}");
            var option = catalogue_option ("files-nautilus-actions");
            apply_option (option);
            string content;
            FileUtils.get_contents (directory + "/config.json", out content);
            assert (content.contains ("Personal action"));
            assert (content.contains ("Copy details"));
            assert (content.contains ("\"personal\""));
            assert (option.state == OptionState.MATCHING);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/native-settings-and-notifications", () => {
        try {
            var settings = new Settings ("org.gtk.gtk4.Settings.FileChooser");
            settings.set_boolean ("show-hidden", false);
            var option = catalogue_option ("files-hidden-gtk4");
            uint changes = 0;
            option.notify["state"].connect (() => changes++);
            inspect_option (option);
            assert (option.state == OptionState.DIFFERENT);
            apply_option (option);
            assert (settings.get_boolean ("show-hidden"));
            assert (option.state == OptionState.MATCHING);
            assert_cmpuint (changes, CompareOperator.GE, 2);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/arcmenu-restores-button-anchored-layout", () => {
        try {
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            Json.Object? definition = null;
            foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
                if (node.get_object ().get_string_member ("id") == "desktop-arcmenu")
                    definition = node.get_object ();
            }
            assert (definition != null);
            var xml = new StringBuilder ("""
                <schemalist>
                  <enum id="org.gnome.shell.extensions.arcmenu.forcemenulocation">
                    <value value="0" nick="Off"/><value value="1" nick="TopCentered"/>
                    <value value="2" nick="TopLeft"/><value value="3" nick="TopRight"/>
                    <value value="4" nick="BottomCentered"/><value value="5" nick="BottomLeft"/>
                    <value value="6" nick="BottomRight"/><value value="7" nick="LeftCentered"/>
                    <value value="8" nick="RightCentered"/><value value="9" nick="MonitorCentered"/>
                  </enum>
                  <enum id="org.gnome.shell.extensions.arcmenu.menu-position">
                    <value value="0" nick="Left"/><value value="1" nick="Center"/><value value="2" nick="Right"/>
                  </enum>
                  <schema id="org.gnome.shell.extensions.arcmenu" path="/org/gnome/shell/extensions/arcmenu/">
                    <key name="force-menu-location" enum="org.gnome.shell.extensions.arcmenu.forcemenulocation"><default>'Off'</default></key>
                    <key name="menu-layout" type="s"><default>'arcmenu'</default><choices><choice value="arcmenu"/><choice value="runner"/></choices></key>
                    <key name="position-in-panel" enum="org.gnome.shell.extensions.arcmenu.menu-position"><default>'Left'</default></key>
                    <key name="menu-button-position-offset" type="i"><default>0</default></key>
                    <key name="menu-position-alignment" type="i"><default>50</default></key>
                    <key name="personal-preference" type="s"><default>''</default></key>
                """);
            foreach (var node in definition.get_object_member ("operation").get_array_member ("settings").get_elements ()) {
                var entry = node.get_object ();
                var key = entry.get_string_member ("key");
                if (key in new string[] { "force-menu-location", "menu-layout", "position-in-panel", "menu-button-position-offset", "menu-position-alignment" })
                    continue;
                var value = Variant.parse (null, entry.get_string_member ("value"));
                xml.append_printf ("<key name=\"%s\" type=\"%s\"><default>%s</default></key>", key,
                    Markup.escape_text (value.get_type_string ()), Markup.escape_text (entry.get_string_member ("value")));
            }
            xml.append ("</schema></schemalist>");
            var directory = workspace + "/system-low/glib-2.0/schemas";
            compile_sandbox_schema (directory, xml.str);
            var source = new SettingsSchemaSource.from_directory (directory, null, false);
            var settings = new Settings.full (source.lookup ("org.gnome.shell.extensions.arcmenu", false), null, null);
            settings.set_string ("force-menu-location", "MonitorCentered");
            settings.set_string ("menu-layout", "runner");
            settings.set_string ("position-in-panel", "Center");
            settings.set_int ("menu-button-position-offset", 3);
            settings.set_int ("menu-position-alignment", 75);
            settings.set_string ("personal-preference", "Retain my unrelated menu preference");
            var option = catalogue_option ("desktop-arcmenu");
            inspect_option (option);
            assert (option.state == OptionState.DIFFERENT || option.state == OptionState.PARTIAL);
            option.selected = true;
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert_cmpstr (settings.get_string ("force-menu-location"), CompareOperator.EQ, "Off");
            assert_cmpstr (settings.get_string ("menu-layout"), CompareOperator.EQ, "arcmenu");
            assert_cmpstr (settings.get_string ("position-in-panel"), CompareOperator.EQ, "Left");
            assert_cmpint (settings.get_int ("menu-button-position-offset"), CompareOperator.EQ, 0);
            assert_cmpint (settings.get_int ("menu-position-alignment"), CompareOperator.EQ, 50);
            assert_cmpstr (settings.get_string ("personal-preference"), CompareOperator.EQ, "Retain my unrelated menu preference");
            settings.set_string ("force-menu-location", "MonitorCentered");
            inspect_option (option);
            assert (option.state == OptionState.PARTIAL);
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert_cmpstr (settings.get_string ("force-menu-location"), CompareOperator.EQ, "Off");
            assert_cmpstr (settings.get_string ("personal-preference"), CompareOperator.EQ, "Retain my unrelated menu preference");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/blur-restores-artifact-handling-and-retains-exclusions", () => {
        try {
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            Json.Object? definition = null;
            foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
                if (node.get_object ().get_string_member ("id") == "appearance-blur")
                    definition = node.get_object ();
            }
            assert (definition != null);
            var schemas = new HashTable<string, StringBuilder> (str_hash, str_equal);
            foreach (var node in definition.get_object_member ("operation").get_array_member ("settings").get_elements ()) {
                var entry = node.get_object ();
                var identity = entry.get_string_member ("schema");
                if (!schemas.contains (identity))
                    schemas.insert (identity, new StringBuilder ("<schema id=\"%s\" path=\"/%s/\">".printf (identity, identity.replace (".", "/"))));
                var value = Variant.parse (null, entry.get_string_member ("value"));
                schemas.lookup (identity).append_printf ("<key name=\"%s\" type=\"%s\"><default>%s</default></key>",
                    entry.get_string_member ("key"), Markup.escape_text (value.get_type_string ()), Markup.escape_text (entry.get_string_member ("value")));
            }
            schemas.lookup ("org.gnome.shell.extensions.blur-my-shell.applications").append ("<key name=\"personal-preference\" type=\"s\"><default>''</default></key>");
            var xml = new StringBuilder ("<schemalist>");
            schemas.foreach ((identity, declaration) => {
                xml.append (declaration.str + "</schema>");
            });
            xml.append ("</schemalist>");
            var directory = workspace + "/data/glib-2.0/schemas";
            compile_sandbox_schema (directory, xml.str);
            var source = new SettingsSchemaSource.from_directory (directory, null, false);
            var general = new Settings.full (source.lookup ("org.gnome.shell.extensions.blur-my-shell", false), null, null);
            general.set_int ("hacks-level", 0);
            var settings = new Settings.full (source.lookup ("org.gnome.shell.extensions.blur-my-shell.applications", false), null, null);
            settings.set_strv ("blacklist", { "org.example.PersonalNotes", "Plank", "org.example.PrivateTerminal" });
            settings.set_string ("personal-preference", "Retain my unrelated blur preference");
            var option = catalogue_option ("appearance-blur");
            inspect_option (option);
            assert (option.state == OptionState.PARTIAL);
            option.selected = true;
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert_cmpint (general.get_int ("hacks-level"), CompareOperator.EQ, 1);
            var exclusions = settings.get_strv ("blacklist");
            assert_cmpuint (exclusions.length, CompareOperator.EQ, 7);
            foreach (var identity in new string[] { "Plank", "com.desktop.ding", "Conky", "com.rastersoft.ding", "gjs", "org.example.PersonalNotes", "org.example.PrivateTerminal" })
                assert (identity in exclusions);
            assert_cmpstr (settings.get_string ("personal-preference"), CompareOperator.EQ, "Retain my unrelated blur preference");
            exclusions += "org.example.AdditionalExclusion";
            settings.set_strv ("blacklist", exclusions);
            inspect_option (option);
            assert (option.state == OptionState.MATCHING);
            string[] incomplete = {};
            foreach (var identity in exclusions) {
                if (identity != "gjs")
                    incomplete += identity;
            }
            settings.set_strv ("blacklist", incomplete);
            inspect_option (option);
            assert (option.state == OptionState.PARTIAL);
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            exclusions = settings.get_strv ("blacklist");
            assert_cmpuint (exclusions.length, CompareOperator.EQ, 8);
            foreach (var identity in new string[] { "Plank", "com.desktop.ding", "Conky", "com.rastersoft.ding", "gjs", "org.example.PersonalNotes", "org.example.PrivateTerminal", "org.example.AdditionalExclusion" })
                assert (identity in exclusions);
            assert_cmpstr (settings.get_string ("personal-preference"), CompareOperator.EQ, "Retain my unrelated blur preference");
            general.set_int ("hacks-level", 0);
            inspect_option (option);
            assert (option.state == OptionState.PARTIAL);
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert_cmpint (general.get_int ("hacks-level"), CompareOperator.EQ, 1);
            assert_cmpuint (settings.get_strv ("blacklist").length, CompareOperator.EQ, 8);
            assert_cmpstr (settings.get_string ("personal-preference"), CompareOperator.EQ, "Retain my unrelated blur preference");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/firefox-clean-profile", () => {
        try {
            FileUtils.remove (workspace + "/.mozilla/firefox/profiles.ini");
            var option = catalogue_option ("browsers-firefox");
            inspect_option (option);
            assert (option.state == OptionState.DIFFERENT);
            apply_option (option);
            var profiles = new KeyFile ();
            profiles.load_from_file (workspace + "/.mozilla/firefox/profiles.ini", KeyFileFlags.NONE);
            assert_cmpstr (profiles.get_string ("Profile0", "Path"), CompareOperator.EQ, "miuutil.default");
            assert (FileUtils.test (workspace + "/.mozilla/firefox/miuutil.default/user.js", FileTest.EXISTS));
            assert (FileUtils.test (workspace + "/.mozilla/firefox/personal/places.sqlite", FileTest.EXISTS));
            assert (option.state == OptionState.MATCHING);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/theme-requires-the-real-addon", () => {
        try {
            var directory = workspace + "/.mozilla/firefox/miuutil.default";
            DirUtils.create_with_parents (directory + "/extensions", 0700);
            FileUtils.set_contents (directory + "/user.js", "user_pref(\"extensions.activeThemeID\", \"{9e0d0c26-e659-4f2d-bbeb-25b86baae860}\");\n");
            FileUtils.set_contents (directory + "/extensions/{9e0d0c26-e659-4f2d-bbeb-25b86baae860}.xpi", "not the theme");
            var option = catalogue_option ("browsers-firefox-theme");
            inspect_option (option);
            assert (option.state == OptionState.UNAVAILABLE);
            assert (!option.current.contains ("2 of 2"));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/firefox-retains-existing-theme-addon", () => {
        try {
            var directory = workspace + "/.mozilla/firefox/miuutil.default";
            var path = directory + "/extensions/{9e0d0c26-e659-4f2d-bbeb-25b86baae860}.xpi";
            var creator = new Subprocess.newv ({ "python3", "-c",
                "import json,sys,zipfile; manifest={'manifest_version':2,'name':'Existing Biscuit','version':'1.1','theme':{'colors':{'frame':'#000000','tab_background_text':'#ffffff'}},'browser_specific_settings':{'gecko':{'id':'{9e0d0c26-e659-4f2d-bbeb-25b86baae860}'}}}; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('manifest.json',json.dumps(manifest)); z.close()", path }, SubprocessFlags.NONE);
            creator.wait_check ();
            var before = Checksum.compute_for_bytes (ChecksumType.SHA256, File.new_for_path (path).load_bytes ());
            FileUtils.set_contents (directory + "/extensions/personal@example.test.xpi", "unrelated addon sentinel");
            FileUtils.set_contents (directory + "/user.js", "user_pref(\"personal.preference\", true);\n");
            var option = catalogue_option ("browsers-firefox-theme");
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert_cmpstr (Checksum.compute_for_bytes (ChecksumType.SHA256, File.new_for_path (path).load_bytes ()), CompareOperator.EQ, before);
            string content;
            FileUtils.get_contents (directory + "/extensions/personal@example.test.xpi", out content);
            assert_cmpstr (content, CompareOperator.EQ, "unrelated addon sentinel");
            FileUtils.get_contents (directory + "/user.js", out content);
            assert (content.contains ("personal.preference"));
            assert (content.contains ("extensions.activeThemeID"));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/firefox-preferences-and-theme-retain-separate-blocks", () => {
        try {
            var directory = workspace + "/.mozilla/firefox/miuutil.default";
            DirUtils.create_with_parents (directory + "/extensions", 0700);
            FileUtils.set_contents (workspace + "/.mozilla/firefox/profiles.ini", "[Profile0]\nName=Fixture\nIsRelative=1\nPath=miuutil.default\nDefault=1\n");
            var path = directory + "/extensions/{9e0d0c26-e659-4f2d-bbeb-25b86baae860}.xpi";
            var creator = new Subprocess.newv ({ "python3", "-c",
                "import json,sys,zipfile; manifest={'manifest_version':2,'name':'Existing Biscuit','version':'1.1','theme':{'colors':{'frame':'#000000','tab_background_text':'#ffffff'}},'browser_specific_settings':{'gecko':{'id':'{9e0d0c26-e659-4f2d-bbeb-25b86baae860}'}}}; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('manifest.json',json.dumps(manifest)); z.close()", path }, SubprocessFlags.NONE);
            creator.wait_check ();
            var before = Checksum.compute_for_bytes (ChecksumType.SHA256, File.new_for_path (path).load_bytes ());
            var personal = "user_pref(\"personal.preference\", true);\n// Personal note: // BEGIN MiuUtil browsers-firefox\n-theme\n";
            FileUtils.set_contents (directory + "/user.js", personal);
            var theme = catalogue_option ("browsers-firefox-theme");
            var preferences = catalogue_option ("browsers-firefox");
            apply_option (theme);
            apply_option (preferences);
            inspect_option (theme);
            inspect_option (preferences);
            assert (theme.state == OptionState.MATCHING);
            assert (preferences.state == OptionState.MATCHING);
            string content;
            FileUtils.get_contents (directory + "/user.js", out content);
            assert (content.has_prefix (personal));
            foreach (var identity in new string[] { "browsers-firefox", "browsers-firefox-theme" }) {
                var beginning = new Regex ("^// BEGIN MiuUtil " + Regex.escape_string (identity) + "$", RegexCompileFlags.MULTILINE);
                var ending = new Regex ("^// END MiuUtil " + Regex.escape_string (identity) + "$", RegexCompileFlags.MULTILINE);
                assert (beginning.match (content));
                assert (ending.match (content));
            }
            var desired = resources_lookup_data ("/com/rispeng/MiuUtil/payloads/firefox/user.js", ResourceLookupFlags.NONE);
            content = content.replace (((string) desired.get_data ()).substring (0, (int) desired.get_size ()), "user_pref(\"fixture.preference\", true);\n");
            FileUtils.set_contents (directory + "/user.js", content);
            apply_option (preferences);
            inspect_option (theme);
            assert (theme.state == OptionState.MATCHING);
            assert (preferences.state == OptionState.MATCHING);
            FileUtils.get_contents (directory + "/user.js", out content);
            assert (content.has_prefix (personal));
            assert (!content.contains ("fixture.preference"));
            assert_cmpstr (Checksum.compute_for_bytes (ChecksumType.SHA256, File.new_for_path (path).load_bytes ()), CompareOperator.EQ, before);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/vivaldi-preserves-personal-profile-and-launcher", () => {
        try {
            var directory = workspace + "/config/vivaldi";
            DirUtils.create_with_parents (directory + "/Default", 0700);
            DirUtils.create_with_parents (workspace + "/data/applications", 0700);
            FileUtils.set_contents (directory + "/Default/Preferences", """
                {"account_info":[{"test_signin_marker":"retained"}],"default_search_provider":{"guid":"personal-search"},
                 "default_search_provider_data":{"template_url_data":{"url":"https://search.example.test/"}},
                 "vivaldi":{"dashboard":{"widgets":[{"personal_widget":true}]},
                            "panels":{"elements":[{"id":"PersonalWebPanel","personal_panel":true},{"id":"PanelBookmarks","personal_marker":true}]},
                            "toolbars":{"navigation":["PersonalToolbarControl","Back"]},
                            "startup":{"first_seen_version":"personal-first","last_seen_version":"personal-last"}}}
                """);
            FileUtils.set_contents (directory + "/Local State", "{\"profile\":{\"personal_identity\":true}}");
            foreach (var name in new string[] { "Bookmarks", "History", "Login Data", "Cookies", "Extension State" })
                FileUtils.set_contents (directory + "/Default/" + name, "personal database sentinel");
            var launcher_path = workspace + "/data/applications/vivaldi-stable.desktop";
            FileUtils.set_contents (launcher_path, "[Desktop Entry]\nType=Application\nName=Personal Vivaldi\nExec=/usr/bin/vivaldi-stable --user-data-dir=\"/personal browser profile\" --profile-directory=Personal --enable-features=PersonalFeature %U\n");
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            Json.Object? definition = null;
            foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
                if (node.get_object ().get_string_member ("id") == "browsers-vivaldi")
                    definition = node.get_object ();
            }
            assert (definition != null);
            definition.get_object_member ("operation").remove_member ("required_programs");
            var option = new Option (definition);
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            var preferences = new Json.Parser ();
            preferences.load_from_file (directory + "/Default/Preferences");
            var current = preferences.get_root ().get_object ();
            assert (current.has_member ("account_info"));
            assert_cmpstr (current.get_object_member ("default_search_provider").get_string_member ("guid"), CompareOperator.EQ, "personal-search");
            assert_cmpstr (current.get_object_member ("default_search_provider_data").get_object_member ("template_url_data").get_string_member ("url"), CompareOperator.EQ, "https://search.example.test/");
            var vivaldi = current.get_object_member ("vivaldi");
            assert_cmpuint (vivaldi.get_object_member ("dashboard").get_array_member ("widgets").get_length (), CompareOperator.EQ, 1);
            bool panel_retained = false;
            bool panel_metadata_retained = false;
            foreach (var panel in vivaldi.get_object_member ("panels").get_array_member ("elements").get_elements ()) {
                panel_retained = panel_retained || panel.get_object ().get_string_member ("id") == "PersonalWebPanel";
                panel_metadata_retained = panel_metadata_retained || panel.get_object ().has_member ("personal_marker");
            }
            assert (panel_retained && panel_metadata_retained);
            bool toolbar_retained = false;
            foreach (var control in vivaldi.get_object_member ("toolbars").get_array_member ("navigation").get_elements ())
                toolbar_retained = toolbar_retained || control.get_string () == "PersonalToolbarControl";
            assert (toolbar_retained);
            assert_cmpstr (vivaldi.get_object_member ("startup").get_string_member ("first_seen_version"), CompareOperator.EQ, "personal-first");
            assert_cmpstr (vivaldi.get_object_member ("startup").get_string_member ("last_seen_version"), CompareOperator.EQ, "personal-last");
            var launcher = new KeyFile ();
            launcher.load_from_file (launcher_path, KeyFileFlags.NONE);
            var command = launcher.get_string ("Desktop Entry", "Exec");
            assert (command.contains ("--user-data-dir=\"/personal browser profile\""));
            assert (command.contains ("--profile-directory=Personal"));
            assert (command.contains ("--enable-features=PersonalFeature,VivaldiCssMods"));
            assert (command.contains ("--ozone-platform=x11"));
            foreach (var name in new string[] { "Bookmarks", "History", "Login Data", "Cookies", "Extension State" }) {
                string content;
                FileUtils.get_contents (directory + "/Default/" + name, out content);
                assert_cmpstr (content, CompareOperator.EQ, "personal database sentinel");
            }
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/fluent-cursors-legacy-search-path", () => {
        var original_path = Environment.get_variable ("PATH");
        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.NONE);
            launcher.setenv ("XCURSOR_PATH", "~/.icons:/usr/share/icons:/usr/share/pixmaps", true);
            var creator = launcher.spawnv ({ "python3", "-c", CURSOR_FIXTURE, "create", workspace });
            creator.wait_check ();
            var unpublished = launcher.spawnv ({ "python3", "-c", CURSOR_FIXTURE, "unpublished", workspace });
            unpublished.wait_check ();
            var binaries = workspace + "/cursor-bin";
            DirUtils.create_with_parents (binaries, 0700);
            FileUtils.set_contents (binaries + "/curl", "#!/bin/sh\n: > \"" + workspace + "/cursor-download\"\nexit 1\n");
            Posix.chmod (binaries + "/curl", 0700);
            Environment.set_variable ("PATH", binaries + ":" + original_path, true);
            var option = catalogue_option ("appearance-fluent-icons");
            inspect_option (option);
            assert (option.state == OptionState.PARTIAL);
            uint applications = 0;
            option.output.connect ((line) => {
                if (line.has_prefix ("Applying "))
                    applications++;
            });
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            foreach (var theme in new string[] { "fluent-dark", "fluent" })
                assert_cmpstr (FileUtils.read_link (workspace + "/.icons/" + theme), CompareOperator.EQ,
                    workspace + "/data/icons/" + theme);
            var published = launcher.spawnv ({ "python3", "-c", CURSOR_FIXTURE, "published", workspace });
            published.wait_check ();
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            assert_cmpuint (applications, CompareOperator.EQ, 1);
            assert (!FileUtils.test (workspace + "/cursor-download", FileTest.EXISTS));
            assert (!FileUtils.test (workspace + "/state/miuutil/backups/appearance-fluent-icons", FileTest.EXISTS));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        } finally {
            Environment.set_variable ("PATH", original_path, true);
            try {
                var cleanup = new Subprocess.newv ({ "rm", "-rf", "--", workspace + "/.icons", workspace + "/cursor-bin" }, SubprocessFlags.NONE);
                cleanup.wait_check ();
            } catch (Error error) {
                Test.message (error.message);
                Test.fail ();
            }
        }
    });

    Test.add_func ("/options/fluent-cursors-preserve-shadowing-themes", () => {
        var original_path = Environment.get_variable ("PATH");
        try {
            var launcher = new SubprocessLauncher (SubprocessFlags.NONE);
            launcher.setenv ("XCURSOR_PATH", "~/.icons:/usr/share/icons:/usr/share/pixmaps", true);
            var creator = launcher.spawnv ({ "python3", "-c", CURSOR_FIXTURE, "create", workspace });
            creator.wait_check ();
            var icons = workspace + "/.icons";
            DirUtils.create_with_parents (icons + "/fluent-dark", 0700);
            FileUtils.set_contents (icons + "/fluent-dark/personal.txt", "existing cursor collection");
            DirUtils.create_with_parents (workspace + "/previous-cursors", 0700);
            FileUtils.set_contents (workspace + "/previous-cursors/personal.txt", "existing symlink target");
            File.new_for_path (icons + "/fluent").make_symbolic_link (workspace + "/previous-cursors");
            DirUtils.create_with_parents (icons + "/personal-theme", 0700);
            FileUtils.set_contents (icons + "/personal-theme/index.theme", "[Icon Theme]\nName=Personal theme\n");
            var asset = File.new_for_path (workspace + "/data/icons/fluent-dark/cursors/left_ptr");
            var before = Checksum.compute_for_bytes (ChecksumType.SHA256, asset.load_bytes ());
            var binaries = workspace + "/cursor-bin";
            DirUtils.create_with_parents (binaries, 0700);
            FileUtils.set_contents (binaries + "/curl", "#!/bin/sh\n: > \"" + workspace + "/cursor-download\"\nexit 1\n");
            Posix.chmod (binaries + "/curl", 0700);
            Environment.set_variable ("PATH", binaries + ":" + original_path, true);
            var option = catalogue_option ("appearance-fluent-icons");
            inspect_option (option);
            assert (option.state == OptionState.PARTIAL);
            apply_option (option);
            assert (option.state == OptionState.MATCHING);
            var published = launcher.spawnv ({ "python3", "-c", CURSOR_FIXTURE, "published", workspace });
            published.wait_check ();
            assert_cmpstr (Checksum.compute_for_bytes (ChecksumType.SHA256, asset.load_bytes ()), CompareOperator.EQ, before);
            string retained;
            FileUtils.get_contents (icons + "/personal-theme/index.theme", out retained);
            assert_cmpstr (retained, CompareOperator.EQ, "[Icon Theme]\nName=Personal theme\n");
            FileUtils.get_contents (workspace + "/previous-cursors/personal.txt", out retained);
            assert_cmpstr (retained, CompareOperator.EQ, "existing symlink target");
            var backups = Dir.open (workspace + "/state/miuutil/backups/appearance-fluent-icons");
            var timestamp = backups.read_name ();
            assert (timestamp != null);
            var backup = workspace + "/state/miuutil/backups/appearance-fluent-icons/" + timestamp;
            FileUtils.get_contents (backup + "/fluent-dark/personal.txt", out retained);
            assert_cmpstr (retained, CompareOperator.EQ, "existing cursor collection");
            assert_cmpstr (FileUtils.read_link (backup + "/fluent"), CompareOperator.EQ, workspace + "/previous-cursors");
            assert (!FileUtils.test (workspace + "/cursor-download", FileTest.EXISTS));
            apply_option (option);
            inspect_option (option);
            assert (option.state == OptionState.MATCHING);
            assert (backups.read_name () == null);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        } finally {
            Environment.set_variable ("PATH", original_path, true);
            try {
                var cleanup = new Subprocess.newv ({ "rm", "-rf", "--", workspace + "/.icons", workspace + "/cursor-bin", workspace + "/previous-cursors" }, SubprocessFlags.NONE);
                cleanup.wait_check ();
            } catch (Error error) {
                Test.message (error.message);
                Test.fail ();
            }
        }
    });

    Test.add_func ("/options/readonly-config-is-unavailable", () => {
        try {
            var path = workspace + "/config/mpv/mpv.conf";
            FileUtils.set_contents (path, "keep-open=no\n");
            Posix.chmod (path, 0400);
            var option = catalogue_option ("applications-mpv");
            option.selected = true;
            inspect_option (option);
            assert (option.state == OptionState.UNAVAILABLE);
            assert (option.current.contains ("read-only"));
            assert (option.selected);
            Posix.chmod (path, 0600);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/options/invalid-json-does-not-overwrite", () => {
        try {
            var directory = workspace + "/invalid-json";
            DirUtils.create_with_parents (directory, 0700);
            var path = directory + "/config.json";
            FileUtils.set_contents (path, "[]");
            var definition = new Json.Parser ();
            definition.load_from_data ("{\"id\":\"test\",\"title\":\"JSON\",\"description\":\"JSON\",\"category\":\"files\",\"scope\":\"Your account\",\"risk\":\"Low\",\"desired\":\"Object\",\"details\":\"\",\"requires_admin\":false,\"dependencies\":[],\"operation\":{\"kind\":\"configuration\",\"files\":[{\"path\":\"" + path + "\",\"format\":\"nautilus\",\"payload\":\"nautilus.json\"}]}}");
            var option = new Option (definition.get_root ().get_object ());
            var loop = new MainLoop ();
            option.detect.begin (null, (object, result) => {
                try {
                    option.detect.end (result);
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
                loop.quit ();
            });
            loop.run ();
            assert (option.state == OptionState.UNAVAILABLE);
            string content;
            FileUtils.get_contents (path, out content);
            assert_cmpstr (content, CompareOperator.EQ, "[]");
            FileUtils.remove (path);
            DirUtils.remove (directory);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    int result = Test.run ();
    try {
        var cleanup = new Subprocess.newv ({ "rm", "-rf", "--", workspace }, SubprocessFlags.NONE);
        cleanup.wait_check ();
    } catch (Error error) {
        warning ("Could not remove test workspace: %s", error.message);
    }
    return result;
}
