namespace MiuUtil {
    private class FirefoxProfileLock : Object {
        private int descriptor = -1;

        public FirefoxProfileLock (string directory, bool acquire) throws Error {
            var path = Path.build_filename (directory, ".parentlock");
            descriptor = Posix.open (path, acquire ? Posix.O_RDWR | Posix.O_CREAT | Posix.O_CLOEXEC : Posix.O_RDONLY | Posix.O_CLOEXEC, 0600);
            if (descriptor < 0 && (acquire || Posix.errno != Posix.ENOENT))
                throw new IOError.NOT_SUPPORTED ("Firefox's native profile lock cannot be inspected: %s", Posix.strerror (Posix.errno));
            bool kernel_checked = descriptor >= 0;
            if (kernel_checked) {
                var native_lock = Posix.Flock () { l_type = Posix.F_WRLCK, l_whence = Posix.SEEK_SET, l_start = 0, l_len = 0 };
                if (Posix.fcntl (descriptor, Posix.F_GETLK, &native_lock) < 0)
                    throw new IOError.NOT_SUPPORTED ("This filesystem does not support Firefox's native profile lock.");
                if (native_lock.l_type != Posix.F_UNLCK)
                    throw new IOError.BUSY ("Close Firefox before changing its profile preferences.");
                if (acquire) {
                    native_lock.l_type = Posix.F_WRLCK;
                    if (Posix.fcntl (descriptor, Posix.F_SETLK, &native_lock) < 0) {
                        if (Posix.errno == Posix.EAGAIN || Posix.errno == Posix.EACCES)
                            throw new IOError.BUSY ("Close Firefox before changing its profile preferences.");
                        throw new IOError.NOT_SUPPORTED ("This filesystem does not support Firefox's native profile lock.");
                    }
                }
            }
            var legacy = Path.build_filename (directory, "lock");
            if (FileUtils.test (legacy, FileTest.IS_SYMLINK)) {
                var signature = new Regex ("^([^:]+):(\\+?)([0-9]+)$");
                MatchInfo match;
                if (!signature.match (FileUtils.read_link (legacy), 0, out match))
                    throw new IOError.NOT_SUPPORTED ("Firefox's legacy profile lock cannot be verified.");
                if (match.fetch (2) == "+" && kernel_checked)
                    return;
                var address = new InetAddress.from_string (match.fetch (1));
                int process = 0;
                if (address == null || !address.is_loopback || !int.try_parse (match.fetch (3), out process) || process <= 0)
                    throw new IOError.NOT_SUPPORTED ("Firefox's legacy profile lock is remote or cannot be verified.");
                if (Posix.kill (process, 0) == 0 || Posix.errno != Posix.ESRCH)
                    throw new IOError.BUSY ("Close Firefox before changing its profile preferences.");
            }
        }

        ~FirefoxProfileLock () {
            if (descriptor >= 0)
                Posix.close (descriptor);
        }
    }

    public class ConfigurationOperation : Operation {
        private string identity;
        private Json.Object specification;
        private bool preserve_json_arrays;

        public ConfigurationOperation (string identity, Json.Object specification) {
            this.identity = identity;
            this.specification = specification;
            preserve_json_arrays = specification.has_member ("preserve_arrays") && specification.get_boolean_member ("preserve_arrays");
        }

        private string profile_directory (bool create = false) throws Error {
            var directory = Path.build_filename (Environment.get_home_dir (), ".mozilla", "firefox");
            var profiles = new KeyFile ();
            var index = Path.build_filename (directory, "profiles.ini");
            if (!FileUtils.test (index, FileTest.EXISTS)) {
                if (!create)
                    throw new IOError.NOT_FOUND ("A clean Firefox profile will be created when applying this option.");
                DirUtils.create_with_parents (Path.build_filename (directory, "miuutil.default"), 0700);
                profiles.set_string ("Profile0", "Name", "MiuUtil");
                profiles.set_integer ("Profile0", "IsRelative", 1);
                profiles.set_string ("Profile0", "Path", "miuutil.default");
                profiles.set_integer ("Profile0", "Default", 1);
                File.new_for_path (index).replace_contents (profiles.to_data ().data, null, false, FileCreateFlags.NONE, null, null);
                return Path.build_filename (directory, "miuutil.default");
            }
            profiles.load_from_file (index, KeyFileFlags.NONE);
            foreach (var group in profiles.get_groups ()) {
                if (group.has_prefix ("Install") && profiles.has_key (group, "Default")) {
                    var default_path = profiles.get_string (group, "Default");
                    return Path.is_absolute (default_path) ? default_path : Path.build_filename (directory, default_path);
                }
            }
            string? fallback = null;
            foreach (var group in profiles.get_groups ()) {
                if (!group.has_prefix ("Profile"))
                    continue;
                var path = profiles.get_string (group, "Path");
                if (profiles.get_integer (group, "IsRelative") == 1)
                    path = Path.build_filename (directory, path);
                fallback = path;
                if (profiles.has_key (group, "Default") && profiles.get_integer (group, "Default") == 1)
                    return path;
            }
            if (fallback == null)
                throw new IOError.NOT_SUPPORTED ("Start Firefox once to create a profile, then close it before applying preferences.");
            return fallback;
        }

        private bool configuration_matches (Json.Node existing, Json.Node desired) {
            if (desired.get_node_type () != existing.get_node_type ())
                return false;
            if (desired.get_node_type () == Json.NodeType.OBJECT) {
                var current = existing.get_object ();
                var target = desired.get_object ();
                foreach (var name in target.get_members ()) {
                    if (!current.has_member (name) || !configuration_matches (current.get_member (name), target.get_member (name)))
                        return false;
                }
                return true;
            }
            if (desired.get_node_type () == Json.NodeType.ARRAY) {
                var current = existing.get_array ();
                var target = desired.get_array ();
                if (preserve_json_arrays) {
                    bool named_entries = true;
                    bool text_entries = true;
                    foreach (var item in target.get_elements ()) {
                        named_entries = named_entries && item.get_node_type () == Json.NodeType.OBJECT && item.get_object ().has_member ("id");
                        text_entries = text_entries && item.get_node_type () == Json.NodeType.VALUE && item.get_value_type () == typeof (string);
                    }
                    if (named_entries) {
                        foreach (var item in target.get_elements ()) {
                            bool found = false;
                            foreach (var candidate in current.get_elements ()) {
                                if (candidate.get_node_type () == Json.NodeType.OBJECT && candidate.get_object ().has_member ("id") &&
                                    configuration_matches (candidate.get_object ().get_member ("id"), item.get_object ().get_member ("id")))
                                    found = found || configuration_matches (candidate, item);
                            }
                            if (!found)
                                return false;
                        }
                        return true;
                    }
                    if (text_entries) {
                        if (current.get_length () < target.get_length ())
                            return false;
                        for (uint index = 0; index < target.get_length (); index++) {
                            if (!configuration_matches (current.get_element (index), target.get_element (index)))
                                return false;
                        }
                        return true;
                    }
                }
                if (current.get_length () != target.get_length ())
                    return false;
                for (uint index = 0; index < target.get_length (); index++) {
                    if (!configuration_matches (current.get_element (index), target.get_element (index)))
                        return false;
                }
                return true;
            }
            return Json.to_string (existing, false) == Json.to_string (desired, false);
        }

        private void merge_configuration (Json.Object current, Json.Object desired) {
            foreach (var name in desired.get_members ()) {
                var value = desired.get_member (name);
                if (value.get_node_type () == Json.NodeType.OBJECT && current.has_member (name) &&
                    current.get_member (name).get_node_type () == Json.NodeType.OBJECT)
                    merge_configuration (current.get_object_member (name), value.get_object ());
                else if (preserve_json_arrays && value.get_node_type () == Json.NodeType.ARRAY && current.has_member (name) &&
                    current.get_member (name).get_node_type () == Json.NodeType.ARRAY) {
                    var expected = value.get_array ();
                    var previous = current.get_array_member (name);
                    bool named_entries = true;
                    bool text_entries = true;
                    foreach (var item in expected.get_elements ()) {
                        named_entries = named_entries && item.get_node_type () == Json.NodeType.OBJECT && item.get_object ().has_member ("id");
                        text_entries = text_entries && item.get_node_type () == Json.NodeType.VALUE && item.get_value_type () == typeof (string);
                    }
                    if (!named_entries && !text_entries) {
                        current.set_member (name, value.copy ());
                        continue;
                    }
                    var merged = new Json.Array ();
                    foreach (var item in expected.get_elements ()) {
                        var replacement = item.copy ();
                        if (named_entries) {
                            foreach (var old in previous.get_elements ()) {
                                if (old.get_node_type () == Json.NodeType.OBJECT && old.get_object ().has_member ("id") &&
                                    configuration_matches (old.get_object ().get_member ("id"), item.get_object ().get_member ("id"))) {
                                    replacement = old.copy ();
                                    merge_configuration (replacement.get_object (), item.get_object ());
                                    break;
                                }
                            }
                        }
                        merged.add_element (replacement);
                    }
                    foreach (var old in previous.get_elements ()) {
                        bool managed = false;
                        foreach (var item in expected.get_elements ()) {
                            if (named_entries && old.get_node_type () == Json.NodeType.OBJECT && old.get_object ().has_member ("id"))
                                managed = managed || configuration_matches (old.get_object ().get_member ("id"), item.get_object ().get_member ("id"));
                            else if (text_entries)
                                managed = managed || configuration_matches (old, item);
                        }
                        if (!managed)
                            merged.add_element (old.copy ());
                    }
                    current.set_array_member (name, merged);
                }
                else
                    current.set_member (name, value.copy ());
            }
        }

        private async bool browser_theme_is_installed (Json.Object entry, string path, Cancellable? cancellable) throws Error {
            try {
                var manifest = yield run_process ({ "python3", "-c",
                    "import sys,zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read('manifest.json'))", path }, cancellable);
                var parser = new Json.Parser ();
                parser.load_from_data (manifest);
                if (parser.get_root ().get_node_type () != Json.NodeType.OBJECT)
                    return false;
                var addon = parser.get_root ().get_object ();
                var metadata_key = addon.has_member ("browser_specific_settings") ? "browser_specific_settings" : "applications";
                if (!addon.has_member ("theme") || !addon.has_member (metadata_key) ||
                    addon.get_member (metadata_key).get_node_type () != Json.NodeType.OBJECT)
                    return false;
                var metadata = addon.get_object_member (metadata_key);
                if (!metadata.has_member ("gecko") || metadata.get_member ("gecko").get_node_type () != Json.NodeType.OBJECT)
                    return false;
                var gecko = metadata.get_object_member ("gecko");
                return gecko.has_member ("id") && gecko.get_member ("id").get_value_type () == typeof (string) &&
                    gecko.get_string_member ("id") == entry.get_string_member ("extension_id");
            } catch (IOError.CANCELLED error) {
                throw error;
            } catch (Error error) {
                return false;
            }
        }

        private async Bytes download_browser_theme (Json.Object entry, Cancellable? cancellable) throws Error {
            FileIOStream temporary_stream;
            var temporary = File.new_tmp ("miuutil-addon-XXXXXX", out temporary_stream);
            temporary_stream.close ();
            try {
                yield run_process ({ "curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", temporary.get_path (), entry.get_string_member ("url") }, cancellable);
                var bytes = temporary.load_bytes (cancellable);
                if (Checksum.compute_for_bytes (ChecksumType.SHA256, bytes) != entry.get_string_member ("sha256"))
                    throw new IOError.INVALID_DATA ("The downloaded browser theme failed its SHA-256 verification.");
                return bytes;
            } finally {
                try {
                    temporary.delete ();
                } catch (Error cleanup_error) {
                    output ("Could not remove temporary download: " + cleanup_error.message);
                }
            }
        }

        private string configured_content (Json.Object entry, string existing) throws Error {
            var kind = entry.get_string_member ("format");
            var source = entry.has_member ("payload") ? entry.get_string_member ("payload") : "";
            string desired = "";
            if (source != "") {
                var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/payloads/" + source, ResourceLookupFlags.NONE);
                if (bytes.get_size () > 0)
                    desired = ((string) bytes.get_data ()).substring (0, (int) bytes.get_size ());
                desired = (desired).replace ("$HOME", Environment.get_home_dir ())
                    .replace ("$CONFIG", Environment.get_user_config_dir ())
                    .replace ("$DATA", Environment.get_user_data_dir ())
                    .replace ("$STATE", Environment.get_user_state_dir ())
                    .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
            }
            if (kind == "copy")
                return desired;
            if (kind == "json" || kind == "nautilus") {
                var target = new Json.Parser ();
                target.load_from_data (desired);
                var current = new Json.Parser ();
                current.load_from_data (existing.strip () == "" ? "{}" : existing);
                if (current.get_root ().get_node_type () != Json.NodeType.OBJECT)
                    throw new IOError.INVALID_DATA ("The selected JSON configuration must contain an object.");
                if (kind == "nautilus") {
                    var configuration = current.get_root ().get_object ();
                    if (!configuration.has_member ("actions"))
                        configuration.set_array_member ("actions", new Json.Array ());
                    if (configuration.get_member ("actions").get_node_type () != Json.NodeType.ARRAY)
                        throw new IOError.INVALID_DATA ("The Nautilus configuration actions must be an array.");
                    var retained = new Json.Array ();
                    foreach (var action in configuration.get_array_member ("actions").get_elements ()) {
                        bool managed = false;
                        foreach (var replacement in target.get_root ().get_object ().get_array_member ("actions").get_elements ())
                            managed = managed || (action.get_node_type () == Json.NodeType.OBJECT && action.get_object ().has_member ("label") &&
                                action.get_object ().get_member ("label").get_value_type () == typeof (string) &&
                                action.get_object ().get_string_member ("label") == replacement.get_object ().get_string_member ("label"));
                        if (!managed)
                            retained.add_element (action.copy ());
                    }
                    foreach (var action in target.get_root ().get_object ().get_array_member ("actions").get_elements ())
                        retained.add_element (action.copy ());
                    configuration.set_array_member ("actions", retained);
                } else
                    merge_configuration (current.get_root ().get_object (), target.get_root ().get_object ());
                return Json.to_string (current.get_root (), true) + "\n";
            }
            if (kind == "ini" || kind == "desktop" || kind == "gearlever") {
                if (kind == "gearlever")
                    desired = desired.replace ("$QVIEW_ID", Checksum.compute_for_string (ChecksumType.MD5,
                        Path.build_filename (Environment.get_home_dir (), "AppImages", "qview.appimage")));
                var current = new KeyFile ();
                if (existing != "")
                    current.load_from_data (existing, existing.length, KeyFileFlags.KEEP_COMMENTS);
                else if (kind == "desktop")
                    current.load_from_file ((entry.get_string_member ("base_path")).replace ("$HOME", Environment.get_home_dir ())
                        .replace ("$CONFIG", Environment.get_user_config_dir ())
                        .replace ("$DATA", Environment.get_user_data_dir ())
                        .replace ("$STATE", Environment.get_user_state_dir ())
                        .replace ("$LIBEXEC", Config.LIBEXEC_DIR), KeyFileFlags.KEEP_COMMENTS);
                var target = new KeyFile ();
                target.load_from_data (desired, desired.length, KeyFileFlags.NONE);
                foreach (var group in target.get_groups ()) {
                    foreach (var key in target.get_keys (group)) {
                        if (kind == "desktop" && key == "Exec" && entry.has_member ("launch_flags")) {
                            var command = current.has_group (group) && current.has_key (group, key) ?
                                current.get_string (group, key) : target.get_string (group, key);
                            foreach (var item in entry.get_array_member ("launch_flags").get_elements ()) {
                                var argument = item.get_string ();
                                var separator = argument.index_of ("=");
                                var name = argument.substring (0, separator);
                                var expression = new Regex ("(^|\\s)" + Regex.escape_string (name) + "=([^\\s]+)");
                                MatchInfo match;
                                if (expression.match (command, 0, out match)) {
                                    var value = argument.substring (separator + 1);
                                    if (name == "--enable-features") {
                                        var existing_features = match.fetch (2).replace ("\"", "");
                                        if (!(value in existing_features.split (",")))
                                            value = existing_features + "," + value;
                                        else
                                            value = existing_features;
                                    }
                                    int begin;
                                    int end;
                                    match.fetch_pos (0, out begin, out end);
                                    command = command.substring (0, begin) + match.fetch (1) + name + "=" + value + command.substring (end);
                                } else {
                                    var field_code = new Regex ("\\s%[uUfF](?:\\s|$)");
                                    if (field_code.match (command, 0, out match)) {
                                        int begin;
                                        int end;
                                        match.fetch_pos (0, out begin, out end);
                                        command = command.substring (0, begin) + " " + argument + command.substring (begin);
                                    } else
                                        command += " " + argument;
                                }
                            }
                            current.set_string (group, key, command);
                        } else
                            current.set_value (group, key, target.get_value (group, key));
                    }
                }
                return current.to_data ();
            }
            if (kind == "text-keys") {
                var keys = new HashTable<string, string> (str_hash, str_equal);
                foreach (var line in desired.split ("\n")) {
                    int separator = line.index_of ("=");
                    if (separator > 0)
                        keys.insert (line.substring (0, separator).strip (), line);
                }
                var merged = new StringBuilder ();
                foreach (var line in existing.split ("\n")) {
                    int separator = line.index_of ("=");
                    if (separator > 0 && keys.contains (line.substring (0, separator).strip ()))
                        continue;
                    if (line != "" || merged.len > 0)
                        merged.append (line + "\n");
                }
                return merged.str.strip () + "\n" + desired;
            }
            if (kind == "terminal-list") {
                var merged = new StringBuilder (desired);
                foreach (var line in existing.split ("\n")) {
                    if (line.strip () != "" && line.strip () != desired.strip ())
                        merged.append (line + "\n");
                }
                return merged.str;
            }
            if (kind == "block" || kind == "firefox") {
                string remaining = existing;
                string prefix = kind == "firefox" ? "//" : "#";
                var start = "%s BEGIN MiuUtil %s".printf (prefix, identity);
                var finish = "%s END MiuUtil %s".printf (prefix, identity);
                var beginning = new Regex ("^" + Regex.escape_string (start) + "\\r?$", RegexCompileFlags.MULTILINE);
                MatchInfo start_match;
                if (beginning.match (remaining, 0, out start_match)) {
                    int begin;
                    int content_begin;
                    start_match.fetch_pos (0, out begin, out content_begin);
                    var ending = new Regex ("^" + Regex.escape_string (finish) + "\\r?$", RegexCompileFlags.MULTILINE);
                    MatchInfo end_match;
                    if (!ending.match_full (remaining, -1, content_begin, 0, out end_match))
                        throw new IOError.INVALID_DATA ("The existing MiuUtil configuration block is incomplete.");
                    int content_end;
                    int end;
                    end_match.fetch_pos (0, out content_end, out end);
                    remaining = remaining.substring (0, begin) + remaining.substring (end);
                }
                return remaining + (remaining.has_suffix ("\n") ? "\n" : "\n\n") + start + "\n" + desired + "\n" + finish + "\n";
            }
            throw new IOError.INVALID_DATA ("Unknown configuration format %s", kind);
        }

        public override async Assessment inspect (Cancellable? cancellable) throws Error {
            if (specification.has_member ("required_paths")) {
                foreach (var node in specification.get_array_member ("required_paths").get_elements ()) {
                    var path = (node.get_string ()).replace ("$HOME", Environment.get_home_dir ())
                        .replace ("$CONFIG", Environment.get_user_config_dir ())
                        .replace ("$DATA", Environment.get_user_data_dir ())
                        .replace ("$STATE", Environment.get_user_state_dir ())
                        .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                    if (!FileUtils.test (path, FileTest.EXISTS))
                        return new Assessment (OptionState.UNAVAILABLE, "Required file is not installed: " + path);
                }
            }
            if (specification.has_member ("required_programs")) {
                foreach (var node in specification.get_array_member ("required_programs").get_elements ()) {
                    if (Environment.find_program_in_path (node.get_string ()) == null)
                        return new Assessment (OptionState.UNAVAILABLE, "Install %s before applying this setup.".printf (node.get_string ()), "", true);
                }
            }
            uint matches = 0;
            string[] observed = {};
            var files = specification.get_array_member ("files");
            foreach (var node in files.get_elements ()) {
                if (cancellable != null)
                    cancellable.set_error_if_cancelled ();
                var entry = node.get_object ();
                var format = entry.get_string_member ("format");
                string path;
                if (entry.get_string_member ("path").has_prefix ("$FIREFOX")) {
                    try {
                        var directory = profile_directory ();
                        new FirefoxProfileLock (directory, false);
                        path = entry.get_string_member ("path").replace ("$FIREFOX", directory);
                    } catch (IOError.NOT_FOUND error) {
                        return new Assessment (OptionState.DIFFERENT, error.message);
                    } catch (Error error) {
                        return new Assessment (OptionState.UNAVAILABLE, error.message);
                    }
                } else
                    path = (entry.get_string_member ("path")).replace ("$HOME", Environment.get_home_dir ())
                        .replace ("$CONFIG", Environment.get_user_config_dir ())
                        .replace ("$DATA", Environment.get_user_data_dir ())
                        .replace ("$STATE", Environment.get_user_state_dir ())
                        .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                if (path.contains ("/vivaldi/") && FileUtils.test (Path.build_filename (Environment.get_user_config_dir (), "vivaldi", "SingletonLock"), FileTest.IS_SYMLINK))
                    return new Assessment (OptionState.UNAVAILABLE, "Close Vivaldi before changing its profile preferences.");
                bool match = false;
                if (format == "link") {
                    var target = (entry.get_string_member ("target")).replace ("$HOME", Environment.get_home_dir ())
                        .replace ("$CONFIG", Environment.get_user_config_dir ())
                        .replace ("$DATA", Environment.get_user_data_dir ())
                        .replace ("$STATE", Environment.get_user_state_dir ())
                        .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                    if (!FileUtils.test (target, FileTest.EXISTS) && entry.has_member ("alternatives")) {
                        foreach (var alternative in entry.get_array_member ("alternatives").get_elements ()) {
                            var candidate = (alternative.get_string ()).replace ("$HOME", Environment.get_home_dir ())
                                .replace ("$CONFIG", Environment.get_user_config_dir ())
                                .replace ("$DATA", Environment.get_user_data_dir ())
                                .replace ("$STATE", Environment.get_user_state_dir ())
                                .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                            if (FileUtils.test (candidate, FileTest.EXISTS)) {
                                target = candidate;
                                break;
                            }
                        }
                    }
                    if (!FileUtils.test (target, FileTest.EXISTS))
                        return new Assessment (OptionState.UNAVAILABLE, "Install the selected theme before applying its links.", "", true);
                    if (FileUtils.test (path, FileTest.IS_SYMLINK))
                        match = FileUtils.read_link (path) == target;
                } else if (format == "binary") {
                    if (FileUtils.test (path, FileTest.EXISTS)) {
                        if (entry.has_member ("extension_id")) {
                            if (Environment.find_program_in_path ("python3") == null)
                                return new Assessment (OptionState.UNAVAILABLE, "Install Python support to inspect the existing browser theme.", "", true);
                            match = yield browser_theme_is_installed (entry, path, cancellable);
                            if (!match)
                                return new Assessment (OptionState.UNAVAILABLE, "The existing theme extension cannot be verified and will be retained.");
                        } else {
                            var existing = File.new_for_path (path).load_bytes (cancellable);
                            if (entry.has_member ("sha256"))
                                match = Checksum.compute_for_bytes (ChecksumType.SHA256, existing) == entry.get_string_member ("sha256");
                            else {
                                var desired = resources_lookup_data ("/com/rispeng/MiuUtil/payloads/" + entry.get_string_member ("payload"), ResourceLookupFlags.NONE);
                                match = existing.compare (desired) == 0;
                            }
                        }
                    }
                } else {
                    string existing = "";
                    if (FileUtils.test (path, FileTest.EXISTS))
                        FileUtils.get_contents (path, out existing);
                    if (format == "block" || format == "firefox") {
                        var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/payloads/" + entry.get_string_member ("payload"), ResourceLookupFlags.NONE);
                        var desired = (((string) bytes.get_data ()).substring (0, (int) bytes.get_size ())).replace ("$HOME", Environment.get_home_dir ())
                            .replace ("$CONFIG", Environment.get_user_config_dir ())
                            .replace ("$DATA", Environment.get_user_data_dir ())
                            .replace ("$STATE", Environment.get_user_state_dir ())
                            .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                        match = existing.contains (desired);
                    } else if (format == "json" || format == "nautilus") {
                        var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/payloads/" + entry.get_string_member ("payload"), ResourceLookupFlags.NONE);
                        var desired = new Json.Parser ();
                        desired.load_from_data ((((string) bytes.get_data ()).substring (0, (int) bytes.get_size ())).replace ("$HOME", Environment.get_home_dir ())
                            .replace ("$CONFIG", Environment.get_user_config_dir ())
                            .replace ("$DATA", Environment.get_user_data_dir ())
                            .replace ("$STATE", Environment.get_user_state_dir ())
                            .replace ("$LIBEXEC", Config.LIBEXEC_DIR));
                        var current = new Json.Parser ();
                        if (existing.strip () != "") {
                            current.load_from_data (existing);
                            if (current.get_root ().get_node_type () != Json.NodeType.OBJECT)
                                throw new IOError.INVALID_DATA ("The selected JSON configuration must contain an object.");
                            if (format == "nautilus") {
                                match = current.get_root ().get_object ().has_member ("actions");
                                if (match) {
                                    if (current.get_root ().get_object ().get_member ("actions").get_node_type () != Json.NodeType.ARRAY)
                                        throw new IOError.INVALID_DATA ("The Nautilus configuration actions must be an array.");
                                    foreach (var expected in desired.get_root ().get_object ().get_array_member ("actions").get_elements ()) {
                                        bool found = false;
                                        foreach (var action in current.get_root ().get_object ().get_array_member ("actions").get_elements ())
                                            found = found || configuration_matches (action, expected);
                                        match = match && found;
                                    }
                                }
                            } else
                                match = configuration_matches (current.get_root (), desired.get_root ());
                        }
                    } else
                        match = FileUtils.test (path, FileTest.EXISTS) && configured_content (entry, existing).strip () == existing.strip ();
                }
                if (match)
                    matches++;
                else if (format != "link" && FileUtils.test (path, FileTest.EXISTS) &&
                    !File.new_for_path (path).query_info (FileAttribute.ACCESS_CAN_WRITE, FileQueryInfoFlags.NONE, cancellable).get_attribute_boolean (FileAttribute.ACCESS_CAN_WRITE))
                    return new Assessment (OptionState.UNAVAILABLE, "The selected configuration file is read-only: " + path);
                observed += path;
            }
            return new Assessment (matches == files.get_length () ? OptionState.MATCHING :
                matches == 0 ? OptionState.DIFFERENT : OptionState.PARTIAL,
                "%u of %u files match".printf (matches, files.get_length ()), string.joinv ("\n", observed));
        }

        public override async void apply (Cancellable? cancellable) throws Error {
            var timestamp = new DateTime.now_utc ().format ("%Y%m%dT%H%M%S%fZ");
            FirefoxProfileLock? profile_lock = null;
            string? profile = null;
            try {
                foreach (var node in specification.get_array_member ("files").get_elements ()) {
                    if (cancellable != null)
                        cancellable.set_error_if_cancelled ();
                    var entry = node.get_object ();
                    var path = entry.get_string_member ("path");
                    if (path.has_prefix ("$FIREFOX")) {
                        if (profile_lock == null) {
                            profile = profile_directory (true);
                            profile_lock = new FirefoxProfileLock (profile, true);
                        }
                        path = path.replace ("$FIREFOX", profile);
                    } else
                        path = path.replace ("$HOME", Environment.get_home_dir ())
                        .replace ("$CONFIG", Environment.get_user_config_dir ())
                        .replace ("$DATA", Environment.get_user_data_dir ())
                        .replace ("$STATE", Environment.get_user_state_dir ())
                        .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                    var destination = File.new_for_path (path);
                    if (entry.get_string_member ("format") == "binary" && entry.has_member ("extension_id") && destination.query_exists ()) {
                        if (!(yield browser_theme_is_installed (entry, path, cancellable)))
                            throw new IOError.NOT_SUPPORTED ("The existing theme extension cannot be verified and will be retained.");
                        output ("Retained the existing Firefox theme extension.");
                        continue;
                    }
                    var parent = destination.get_parent ();
                    if (!parent.query_exists ())
                        parent.make_directory_with_parents (cancellable);
                    if (destination.query_exists () || FileUtils.test (path, FileTest.IS_SYMLINK)) {
                        var backup = File.new_for_path (Path.build_filename (Environment.get_user_state_dir (), "miuutil", "backups", identity, timestamp, Path.get_basename (path)));
                        if (!backup.get_parent ().query_exists ())
                            backup.get_parent ().make_directory_with_parents (cancellable);
                        var flags = entry.get_string_member ("format") == "link" ? FileCopyFlags.NOFOLLOW_SYMLINKS | FileCopyFlags.OVERWRITE : FileCopyFlags.OVERWRITE;
                        if (destination.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS, cancellable) == FileType.DIRECTORY)
                            destination.move (backup, FileCopyFlags.OVERWRITE, cancellable);
                        else
                            destination.copy (backup, flags, cancellable);
                    }
                    var format = entry.get_string_member ("format");
                    if (format == "link") {
                        var target = (entry.get_string_member ("target")).replace ("$HOME", Environment.get_home_dir ())
                            .replace ("$CONFIG", Environment.get_user_config_dir ())
                            .replace ("$DATA", Environment.get_user_data_dir ())
                            .replace ("$STATE", Environment.get_user_state_dir ())
                            .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                        if (!FileUtils.test (target, FileTest.EXISTS) && entry.has_member ("alternatives")) {
                            foreach (var alternative in entry.get_array_member ("alternatives").get_elements ()) {
                                var candidate = (alternative.get_string ()).replace ("$HOME", Environment.get_home_dir ())
                                    .replace ("$CONFIG", Environment.get_user_config_dir ())
                                    .replace ("$DATA", Environment.get_user_data_dir ())
                                    .replace ("$STATE", Environment.get_user_state_dir ())
                                    .replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                                if (FileUtils.test (candidate, FileTest.EXISTS)) {
                                    target = candidate;
                                    break;
                                }
                            }
                        }
                        if (!FileUtils.test (target, FileTest.EXISTS))
                            throw new IOError.NOT_FOUND ("Theme file is not installed: %s", target);
                        if (destination.query_exists () || FileUtils.test (path, FileTest.IS_SYMLINK))
                            destination.delete (cancellable);
                        destination.make_symbolic_link (target, cancellable);
                    } else if (format == "binary") {
                        Bytes bytes;
                        if (entry.has_member ("url"))
                            bytes = yield download_browser_theme (entry, cancellable);
                        else
                            bytes = resources_lookup_data ("/com/rispeng/MiuUtil/payloads/" + entry.get_string_member ("payload"), ResourceLookupFlags.NONE);
                        destination.replace_contents (bytes.get_data (), null, false, FileCreateFlags.REPLACE_DESTINATION, null, cancellable);
                    } else {
                        string existing = "";
                        if (destination.query_exists ())
                            FileUtils.get_contents (path, out existing);
                        var merged = configured_content (entry, existing);
                        destination.replace_contents (merged.data, null, false, FileCreateFlags.NONE, null, cancellable);
                    }
                    output ("Updated " + path);
                }
            } finally {
                profile_lock = null;
            }
        }
    }
}
