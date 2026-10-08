namespace MiuUtil {
    public class SettingsOperation : Operation {
        private Json.Object specification;

        public SettingsOperation (Json.Object specification) {
            this.specification = specification;
        }

        public Settings open_settings (Json.Object entry) throws Error {
            var schema_id = entry.get_string_member ("schema");
            SettingsSchemaSource? source = null;
            var data_directories = Environment.get_system_data_dirs ();
            for (int index = data_directories.length - 1; index >= 0; index--) {
                var directory = Path.build_filename (data_directories[index], "glib-2.0", "schemas");
                if (FileUtils.test (Path.build_filename (directory, "gschemas.compiled"), FileTest.EXISTS))
                    source = new SettingsSchemaSource.from_directory (directory, source, false);
            }
            var user_directory = Path.build_filename (Environment.get_user_data_dir (), "glib-2.0", "schemas");
            if (FileUtils.test (Path.build_filename (user_directory, "gschemas.compiled"), FileTest.EXISTS))
                source = new SettingsSchemaSource.from_directory (user_directory, source, false);
            var extra_path = Environment.get_variable ("GSETTINGS_SCHEMA_DIR");
            if (extra_path != null) {
                var extra_directories = extra_path.split (Path.SEARCHPATH_SEPARATOR_S);
                for (int index = extra_directories.length - 1; index >= 0; index--) {
                    if (FileUtils.test (Path.build_filename (extra_directories[index], "gschemas.compiled"), FileTest.EXISTS))
                        source = new SettingsSchemaSource.from_directory (extra_directories[index], source, false);
                }
            }
            SettingsSchema? schema = source == null ? null : source.lookup (schema_id, true);
            if (schema == null) {
                string[] directories = {
                    Path.build_filename (Environment.get_user_data_dir (), "gnome-shell", "extensions"),
                    "/usr/share/gnome-shell/extensions"
                };
                foreach (var directory in directories) {
                    var root = File.new_for_path (directory);
                    if (!root.query_exists ())
                        continue;
                    var children = root.enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
                    FileInfo? child;
                    while ((child = children.next_file ()) != null) {
                        var schemas = Path.build_filename (directory, child.get_name (), "schemas");
                        if (!FileUtils.test (Path.build_filename (schemas, "gschemas.compiled"), FileTest.EXISTS))
                            continue;
                        var extension_source = new SettingsSchemaSource.from_directory (schemas, source, false);
                        schema = extension_source.lookup (schema_id, true);
                        if (schema != null)
                            break;
                    }
                    if (schema != null)
                        break;
                }
            }
            if (schema == null)
                throw new IOError.NOT_SUPPORTED ("The settings schema %s is not installed.", schema_id);
            var key = entry.get_string_member ("key");
            if (!schema.has_key (key))
                throw new IOError.NOT_SUPPORTED ("This version of %s does not provide %s.", schema_id, key);
            var path = entry.has_member ("path") ? entry.get_string_member ("path") : null;
            var settings = new Settings.full (schema, null, path);
            if (entry.has_member ("monitor_layout")) {
                if (!schema.get_key (key).get_value_type ().equal (VariantType.STRING))
                    throw new IOError.NOT_SUPPORTED ("This version of %s does not store %s as a monitor layout.", schema_id, key);
            } else {
                var desired = Variant.parse (schema.get_key (key).get_value_type (), entry.get_string_member ("value").replace ("$LIBEXEC", Config.LIBEXEC_DIR));
                if (!schema.get_key (key).range_check (desired))
                    throw new IOError.NOT_SUPPORTED ("This version of %s does not accept the requested value of %s.", schema_id, key);
            }
            return settings;
        }

        private async string[] connected_panel_monitors (Cancellable? cancellable) throws Error {
            Variant state;
            try {
                var connection = yield Bus.get (BusType.SESSION, cancellable);
                state = yield connection.call ("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                    "org.gnome.Mutter.DisplayConfig", "GetCurrentState", null,
                    new VariantType ("(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"),
                    DBusCallFlags.NONE, 10000, cancellable);
            } catch (IOError.CANCELLED error) {
                throw error;
            } catch (Error error) {
                throw new IOError.NOT_SUPPORTED ("Dash to Panel layout detection requires an active GNOME session with Mutter display information: %s", error.message);
            }
            string[] monitors = {};
            var seen = new HashTable<string, bool> (str_hash, str_equal);
            var logical_monitors = state.get_child_value (2);
            for (uint index = 0; index < logical_monitors.n_children (); index++) {
                var specification = logical_monitors.get_child_value (index).get_child_value (5).get_child_value (0);
                var connector = specification.get_child_value (0).get_string ();
                var vendor = specification.get_child_value (1).get_string ();
                var serial = specification.get_child_value (3).get_string ();
                var identity = vendor != "" && serial != "" ? vendor + "-" + serial : index.to_string ();
                if (seen.contains (identity))
                    identity = connector != "" && !seen.contains (connector) ? connector : index.to_string ();
                seen.insert (identity, true);
                monitors += identity;
            }
            if (monitors.length == 0)
                throw new IOError.NOT_SUPPORTED ("Dash to Panel layout detection requires a connected monitor in an active GNOME session.");
            return monitors;
        }

        private Variant resolve_panel_layout (Settings settings, Json.Object entry, string[] monitors, out bool matches) throws Error {
            var key = entry.get_string_member ("key");
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (settings.get_string (key));
            } catch (Error error) {
                throw new IOError.NOT_SUPPORTED ("Dash to Panel's %s contains invalid monitor JSON: %s", key, error.message);
            }
            if (parser.get_root ().get_node_type () != Json.NodeType.OBJECT)
                throw new IOError.NOT_SUPPORTED ("Dash to Panel's %s must contain a monitor layout object.", key);
            var layout = entry.get_object_member ("monitor_layout");
            var fallback = layout.has_member ("fallback_key") ?
                Json.gvariant_serialize (settings.get_value (layout.get_string_member ("fallback_key"))) : layout.get_member ("default").copy ();
            var desired = layout.has_member ("value") ? layout.get_member ("value") : fallback;
            var values = parser.get_root ().get_object ();
            matches = true;
            for (uint index = 0; index < monitors.length; index++) {
                Json.Node? current = null;
                foreach (var identity in new string[] { monitors[index], index.to_string () }) {
                    if (!values.has_member (identity))
                        continue;
                    var candidate = values.get_member (identity);
                    if (candidate.get_node_type () == Json.NodeType.NULL ||
                        (candidate.get_node_type () == Json.NodeType.VALUE &&
                         ((candidate.get_value_type () == typeof (string) && candidate.get_string () == "") ||
                          (candidate.get_value_type () == typeof (bool) && !candidate.get_boolean ()) ||
                          (candidate.get_value_type () == typeof (int64) && candidate.get_int () == 0) ||
                          (candidate.get_value_type () == typeof (double) && candidate.get_double () == 0))))
                        continue;
                    current = candidate;
                    break;
                }
                if (current == null)
                    current = fallback;
                matches = matches && current.equal (desired);
                if (monitors[index] != index.to_string ())
                    values.remove_member (index.to_string ());
                if (layout.has_member ("value"))
                    values.set_member (monitors[index], desired.copy ());
                else
                    values.remove_member (monitors[index]);
            }
            return new Variant.string (Json.to_string (parser.get_root (), false));
        }

        public override async Assessment inspect (Cancellable? cancellable) throws Error {
            if (specification.has_member ("required_paths")) {
                foreach (var node in specification.get_array_member ("required_paths").get_elements ()) {
                    var path = node.get_string ().replace ("$LIBEXEC", Config.LIBEXEC_DIR);
                    if (!FileUtils.test (path, FileTest.EXISTS))
                        return new Assessment (OptionState.UNAVAILABLE, "Install MiuUtil's shortcut helpers before applying these bindings.");
                }
            }
            uint matches = 0;
            string[] observed = {};
            var entries = specification.get_array_member ("settings");
            try {
                string[] monitors = {};
                foreach (var node in entries.get_elements ()) {
                    if (cancellable != null)
                        cancellable.set_error_if_cancelled ();
                    var entry = node.get_object ();
                    var settings = open_settings (entry);
                    var key = entry.get_string_member ("key");
                    var existing = settings.get_value (key);
                    Variant desired;
                    bool matches_entry;
                    if (entry.has_member ("monitor_layout")) {
                        if (monitors.length == 0)
                            monitors = yield connected_panel_monitors (cancellable);
                        desired = resolve_panel_layout (settings, entry, monitors, out matches_entry);
                    } else {
                        desired = Variant.parse (existing.get_type (), entry.get_string_member ("value").replace ("$LIBEXEC", Config.LIBEXEC_DIR));
                        matches_entry = existing.equal (desired);
                    }
                    if (entry.has_member ("merge") && entry.get_boolean_member ("merge")) {
                        matches_entry = true;
                        foreach (var value in desired.dup_strv ()) {
                            if (!(value in existing.dup_strv ()))
                                matches_entry = false;
                        }
                    }
                    if (entry.has_member ("remove")) {
                        foreach (var value in entry.get_array_member ("remove").get_elements ()) {
                            if (value.get_string () in existing.dup_strv ())
                                matches_entry = false;
                        }
                    }
                    if (matches_entry)
                        matches++;
                    else if (!settings.is_writable (key))
                        return new Assessment (OptionState.UNAVAILABLE, "The administrator has locked %s.".printf (key));
                    observed += "%s = %s".printf (key, existing.print (false));
                }
            } catch (IOError.NOT_SUPPORTED error) {
                return new Assessment (OptionState.UNAVAILABLE, error.message, "", error.message.has_prefix ("The settings schema"));
            }
            return new Assessment (matches == entries.get_length () ? OptionState.MATCHING :
                matches == 0 ? OptionState.DIFFERENT : OptionState.PARTIAL,
                "%u of %u settings match".printf (matches, entries.get_length ()), string.joinv ("\n", observed));
        }

        public override async void apply (Cancellable? cancellable) throws Error {
            string[] monitors = {};
            foreach (var node in specification.get_array_member ("settings").get_elements ()) {
                if (node.get_object ().has_member ("monitor_layout")) {
                    monitors = yield connected_panel_monitors (cancellable);
                    break;
                }
            }
            foreach (var node in specification.get_array_member ("settings").get_elements ()) {
                if (cancellable != null)
                    cancellable.set_error_if_cancelled ();
                var entry = node.get_object ();
                var settings = open_settings (entry);
                var key = entry.get_string_member ("key");
                var existing = settings.get_value (key);
                Variant desired;
                if (entry.has_member ("monitor_layout")) {
                    bool matches;
                    desired = resolve_panel_layout (settings, entry, monitors, out matches);
                } else {
                    desired = Variant.parse (existing.get_type (), entry.get_string_member ("value").replace ("$LIBEXEC", Config.LIBEXEC_DIR));
                }
                if (entry.has_member ("merge") && entry.get_boolean_member ("merge")) {
                    string[] values = existing.dup_strv ();
                    foreach (var value in desired.dup_strv ()) {
                        if (!(value in values))
                            values += value;
                    }
                    if (entry.has_member ("remove")) {
                        string[] retained = {};
                        foreach (var value in values) {
                            bool remove = false;
                            foreach (var excluded in entry.get_array_member ("remove").get_elements ())
                                remove = remove || value == excluded.get_string ();
                            if (!remove)
                                retained += value;
                        }
                        values = retained;
                    }
                    desired = new Variant.strv (values);
                }
                if (!settings.set_value (key, desired))
                    throw new IOError.PERMISSION_DENIED ("Cannot write setting %s", key);
                output ("Set %s".printf (key));
            }
            Settings.sync ();
        }
    }
}
