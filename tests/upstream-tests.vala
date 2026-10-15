using MiuUtil;

private string test_home;

int main (string[] arguments) {
    Test.init (ref arguments);
    try {
        test_home = DirUtils.make_tmp ("miuutil-upstream-home-XXXXXX");
    } catch (Error error) {
        critical ("%s", error.message);
        return 1;
    }
    Environment.set_variable ("HOME", test_home, true);
    Environment.set_variable ("XDG_CONFIG_HOME", test_home + "/config", true);
    Environment.set_variable ("XDG_DATA_HOME", test_home + "/data", true);
    Environment.set_variable ("XDG_STATE_HOME", test_home + "/state", true);
    Environment.set_variable ("XDG_DATA_DIRS", test_home + "/system-high:" + test_home + "/system-low", true);
    Test.add_func ("/upstream/immutable-artifacts", () => {
        try {
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/upstreams.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            var root = parser.get_root ().get_object ();
            var artifacts = root.get_object_member ("artifacts");
            foreach (var name in artifacts.get_members ()) {
                var artifact = artifacts.get_object_member (name);
                assert (artifact.get_string_member ("url").has_prefix ("https://"));
                assert_cmpuint (artifact.get_string_member ("sha256").length, CompareOperator.EQ, 64);
                assert (artifact.get_string_member ("version") != "");
                assert (!artifact.get_string_member ("url").contains ("/latest/"));
            }
            var extensions = root.get_object_member ("extensions");
            assert_cmpuint (extensions.get_size (), CompareOperator.EQ, 13);
            foreach (var uuid in extensions.get_members ()) {
                var versions = extensions.get_object_member (uuid);
                assert (versions.has_member ("48"));
                foreach (var shell in versions.get_members ()) {
                    var artifact = versions.get_object_member (shell);
                    assert (artifact.get_string_member ("url").has_prefix ("https://extensions.gnome.org/"));
                    assert_cmpuint (artifact.get_string_member ("sha256").length, CompareOperator.EQ, 64);
                }
            }
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/upstream/rejects-download-before-install", () => {
        string? workspace = null;
        var original_path = Environment.get_variable ("PATH");
        try {
            workspace = DirUtils.make_tmp ("miuutil-upstream-test-XXXXXX");
            var fake_download = Path.build_filename (workspace, "curl");
            FileUtils.set_contents (fake_download,
                "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do\n" +
                "  if [ \"$1\" = --output ]; then printf 'corrupted artifact' > \"$2\"; exit 0; fi\n" +
                "  shift\ndone\nexit 1\n");
            File.new_for_path (fake_download).set_attribute_uint32 (FileAttribute.UNIX_MODE, 0755, FileQueryInfoFlags.NONE);
            Environment.set_variable ("PATH", workspace + ":" + original_path, true);
            var specification = new Json.Object ();
            specification.set_string_member ("kind", "upstream");
            specification.set_string_member ("upstream", "modernz");
            var operation = new UpstreamOperation ("applications-modernz", specification);
            var loop = new MainLoop ();
            bool rejected = false;
            operation.apply.begin (null, (object, result) => {
                try {
                    operation.apply.end (result);
                    Test.fail ();
                } catch (IOError.INVALID_DATA error) {
                    rejected = error.message.contains ("SHA-256");
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
                loop.quit ();
            });
            loop.run ();
            assert (rejected);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        } finally {
            Environment.set_variable ("PATH", original_path, true);
            if (workspace != null) {
                try {
                    var cleanup = new Subprocess.newv ({ "rm", "-rf", "--", workspace }, SubprocessFlags.NONE);
                    cleanup.wait ();
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
            }
        }
    });

    Test.add_func ("/upstream/nautilus-installs-with-configuration", () => {
        if (FileUtils.test ("/usr/share/nautilus-python/extensions/actions-for-nautilus.py", FileTest.EXISTS)) {
            Test.skip ("Actions for Nautilus is installed in the native loader prefix.");
            return;
        }
        string? workspace = null;
        Resource? fixture = null;
        var original_path = Environment.get_variable ("PATH");
        try {
            workspace = DirUtils.make_tmp ("miuutil-nautilus-install-XXXXXX");
            var extension = test_home + "/data/nautilus-python/extensions/actions-for-nautilus.py";
            assert (!FileUtils.test (extension, FileTest.EXISTS));
            var source = workspace + "/release/extensions";
            DirUtils.create_with_parents (source, 0700);
            FileUtils.set_contents (source + "/actions-for-nautilus.py", "verified extension fixture\n");
            var archive = workspace + "/release.tar";
            var pack = new Subprocess.newv ({ "tar", "--create", "--file", archive, "--directory", workspace, "release" }, SubprocessFlags.NONE);
            pack.wait_check ();
            var checksum = Checksum.compute_for_bytes (ChecksumType.SHA256, File.new_for_path (archive).load_bytes ());
            FileUtils.set_contents (workspace + "/upstreams.json", "{\"artifacts\":{\"nautilus-actions\":{\"version\":\"fixture\",\"format\":\"tar-source\",\"url\":\"https://example.test/nautilus.tar\",\"sha256\":\"" + checksum + "\"}}}");
            FileUtils.set_contents (workspace + "/fixture.gresource.xml", "<gresources><gresource prefix=\"/com/rispeng/MiuUtil\"><file>upstreams.json</file></gresource></gresources>");
            var compile = new Subprocess.newv ({ "glib-compile-resources", "--sourcedir", workspace,
                "--target", workspace + "/fixture.gresource", workspace + "/fixture.gresource.xml" }, SubprocessFlags.NONE);
            compile.wait_check ();
            fixture = Resource.load (workspace + "/fixture.gresource");
            resources_register (fixture);

            var download_log = workspace + "/downloads";
            var fake_download = workspace + "/curl";
            FileUtils.set_contents (fake_download, "#!/bin/sh\nprintf 'download\\n' >> " + Shell.quote (download_log) +
                "\nwhile [ \"$#\" -gt 0 ]; do\n" +
                "  if [ \"$1\" = --output ]; then cp " + Shell.quote (archive) + " \"$2\"; exit $?; fi\n" +
                "  shift\ndone\nexit 1\n");
            File.new_for_path (fake_download).set_attribute_uint32 (FileAttribute.UNIX_MODE, 0755, FileQueryInfoFlags.NONE);
            Environment.set_variable ("PATH", workspace + ":" + original_path, true);
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
            var catalogue = new Json.Parser ();
            catalogue.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            Json.Object? definition = null;
            foreach (var node in catalogue.get_root ().get_object ().get_array_member ("options").get_elements ()) {
                if (node.get_object ().get_string_member ("id") == "files-nautilus-actions")
                    definition = node.get_object ();
            }
            assert (definition != null);
            var operation = new UpstreamOperation ("files-nautilus-actions", definition.get_object_member ("operation"));
            var loop = new MainLoop ();
            operation.apply.begin (null, (object, result) => {
                try {
                    operation.apply.end (result);
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
                loop.quit ();
            });
            loop.run ();
            string content;
            FileUtils.get_contents (extension, out content);
            assert_cmpstr (content, CompareOperator.EQ, "verified extension fixture\n");
            var configuration = test_home + "/data/actions-for-nautilus/config.json";
            FileUtils.get_contents (configuration, out content);
            var desired = resources_lookup_data ("/com/rispeng/MiuUtil/payloads/nautilus.json", ResourceLookupFlags.NONE);
            assert_cmpstr (content, CompareOperator.EQ,
                (((string) desired.get_data ()).substring (0, (int) desired.get_size ())).replace ("$LIBEXEC", Config.LIBEXEC_DIR));
            operation.apply.begin (null, (object, result) => {
                try {
                    operation.apply.end (result);
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
                loop.quit ();
            });
            loop.run ();
            FileUtils.get_contents (download_log, out content);
            assert_cmpstr (content, CompareOperator.EQ, "download\n");
            assert (!FileUtils.test (test_home + "/state/miuutil/backups/files-nautilus-actions", FileTest.EXISTS));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        } finally {
            Environment.set_variable ("PATH", original_path, true);
            if (fixture != null)
                resources_unregister (fixture);
            if (workspace != null) {
                try {
                    var cleanup = new Subprocess.newv ({ "rm", "-rf", "--", workspace }, SubprocessFlags.NONE);
                    cleanup.wait_check ();
                } catch (Error error) {
                    Test.message (error.message);
                    Test.fail ();
                }
            }
        }
    });
    int result = Test.run ();
    try {
        var cleanup = new Subprocess.newv ({ "rm", "-rf", "--", test_home }, SubprocessFlags.NONE);
        cleanup.wait_check ();
    } catch (Error error) {
        warning ("Could not remove upstream test workspace: %s", error.message);
    }
    return result;
}
