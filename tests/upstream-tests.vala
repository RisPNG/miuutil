using MiuUtil;

int main (string[] arguments) {
    Test.init (ref arguments);
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
            specification.set_string_member ("upstream", "fetch");
            var operation = new UpstreamOperation ("development-fetch", specification);
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
    return Test.run ();
}
