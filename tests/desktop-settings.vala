using MiuUtil;

private string workspace;
private Settings settings;
private Settings shell_settings;
private Settings tiling_settings;
private Json.Object specification;
private Json.Object catalogue;
private DBusConnection connection;
private uint monitor_filter;
private bool provide_monitors = true;

private Assessment inspect_preferences (Json.Object? preferences = null) {
    Assessment? assessment = null;
    var operation = new SettingsOperation (preferences ?? specification);
    var loop = new MainLoop ();
    operation.inspect.begin (null, (object, result) => {
        try {
            assessment = operation.inspect.end (result);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
        loop.quit ();
    });
    loop.run ();
    assert (assessment != null);
    return assessment;
}

private void apply_preferences (Json.Object? preferences = null) {
    var operation = new SettingsOperation (preferences ?? specification);
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
}

private void reset_layout () {
    foreach (var key in settings.settings_schema.list_keys ())
        settings.reset (key);
}

private Json.Object stored_layout (string key) throws Error {
    var parser = new Json.Parser ();
    parser.load_from_data (settings.get_string (key));
    return parser.get_root ().get_object ();
}

private Json.Node element_layout () {
    foreach (var node in specification.get_array_member ("settings").get_elements ()) {
        var entry = node.get_object ();
        if (entry.get_string_member ("key") == "panel-element-positions")
            return entry.get_object_member ("monitor_layout").get_member ("value").copy ();
    }
    assert_not_reached ();
}

private Json.Object catalogue_preferences (string identity) {
    foreach (var node in catalogue.get_array_member ("options").get_elements ()) {
        if (node.get_object ().get_string_member ("id") == identity)
            return node.get_object ().get_member ("operation").copy ().get_object ();
    }
    assert_not_reached ();
}

int main (string[] arguments) {
    Test.init (ref arguments);
    try {
        workspace = DirUtils.make_tmp ("miuutil-panel-XXXXXX");
        Environment.set_variable ("XDG_DATA_HOME", workspace, true);
        Environment.set_variable ("GSETTINGS_BACKEND", "memory", true);
        Environment.set_variable ("GSETTINGS_SCHEMA_DIR", workspace, true);
        var schemas = new StringBuilder ("""
            <schemalist>
              <schema id="com.rispeng.MiuUtil.PanelFixture" path="/com/rispeng/miuutil/panel-fixture/">
                <key name="panel-anchors" type="s"><default>'{}'</default></key>
                <key name="panel-element-positions" type="s"><default>'{}'</default></key>
                <key name="panel-lengths" type="s"><default>'{}'</default></key>
                <key name="panel-positions" type="s"><default>'{}'</default></key>
                <key name="panel-sizes" type="s"><default>'{}'</default></key>
                <key name="panel-position" type="s"><default>'BOTTOM'</default></key>
                <key name="panel-size" type="i"><default>48</default></key>
                <key name="unrelated" type="b"><default>false</default></key>
              </schema>
              <schema id="org.gnome.shell" path="/org/gnome/shell/">
                <key name="enabled-extensions" type="as"><default>[]</default></key>
                <key name="disabled-extensions" type="as"><default>[]</default></key>
                <key name="disable-user-extensions" type="b"><default>false</default></key>
              </schema>
              <schema id="com.rispeng.MiuUtil.TilingFixture" path="/com/rispeng/miuutil/tiling-fixture/">
            """);
        for (uint index = 0; index < 20; index++)
            schemas.append_printf ("<key name=\"activate-layout%u\" type=\"as\"><default>[]</default></key>\n", index);
        schemas.append ("<key name=\"favorite-layouts\" type=\"as\"><default>[]</default></key></schema></schemalist>");
        FileUtils.set_contents (workspace + "/panel.gschema.xml", schemas.str);
        var compiler = new Subprocess.newv ({ "glib-compile-schemas", workspace }, SubprocessFlags.NONE);
        compiler.wait_check ();
        var source = new SettingsSchemaSource.from_directory (workspace, null, false);
        settings = new Settings.full (source.lookup ("com.rispeng.MiuUtil.PanelFixture", false), null, null);
        shell_settings = new Settings.full (source.lookup ("org.gnome.shell", false), null, null);
        tiling_settings = new Settings.full (source.lookup ("com.rispeng.MiuUtil.TilingFixture", false), null, null);
        var parser = new Json.Parser ();
        var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
        parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
        catalogue = parser.get_root ().get_object ();
        var entries = new Json.Array ();
        foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
            if (node.get_object ().get_string_member ("id") != "desktop-panel")
                continue;
            foreach (var setting in node.get_object ().get_object_member ("operation").get_array_member ("settings").get_elements ()) {
                var key = setting.get_object ().get_string_member ("key");
                if (!setting.get_object ().has_member ("monitor_layout") && key != "panel-position" && key != "panel-size")
                    continue;
                var entry = setting.copy ().get_object ();
                entry.set_string_member ("schema", "com.rispeng.MiuUtil.PanelFixture");
                entries.add_object_element (entry);
            }
        }
        assert_cmpuint (entries.get_length (), CompareOperator.EQ, 7);
        specification = new Json.Object ();
        specification.set_array_member ("settings", entries);
        connection = Bus.get_sync (BusType.SESSION);
        connection.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant ("(su)", "org.gnome.Mutter.DisplayConfig", 0u), new VariantType ("(u)"), DBusCallFlags.NONE, 1000);
        monitor_filter = connection.add_filter ((bus, message, incoming) => {
            if (!incoming || message.get_message_type () != DBusMessageType.METHOD_CALL ||
                message.get_interface () != "org.gnome.Mutter.DisplayConfig" || message.get_member () != "GetCurrentState")
                return message;
            try {
                var response = new DBusMessage.method_reply (message);
                var state = Variant.parse (new VariantType ("(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"), provide_monitors ?
                    "(uint32 7, [], [(0, 0, 1.0, uint32 0, true, [('DP-A', 'DEL', 'Display A', 'shared')], {}), (1920, 0, 1.0, uint32 0, false, [('HDMI-B', 'DEL', 'Display B', 'shared')], {}), (3840, 0, 1.0, uint32 0, false, [('', '', 'Unknown', '')], {}), (5760, 0, 1.0, uint32 0, false, [('DP-D', 'DEL', 'Display D', 'different')], {})], {})" :
                    "(uint32 7, [], [], {})");
                response.set_body (state);
                bus.send_message (response, DBusSendMessageFlags.NONE, null);
            } catch (Error error) {
                critical ("%s", error.message);
            }
            return null;
        });
    } catch (Error error) {
        critical ("%s", error.message);
        return 1;
    }

    Test.add_func ("/desktop-settings/native-identities-and-disconnected-preservation", () => {
        try {
            reset_layout ();
            settings.set_boolean ("unrelated", true);
            settings.set_string ("panel-anchors", "{\"0\":\"START\",\"1\":\"END\",\"DEL-different\":\"START\",\"UNPLUGGED-42\":\"END\"}");
            settings.set_string ("panel-element-positions", "{\"UNPLUGGED-42\":[{\"element\":\"personal\",\"visible\":false,\"position\":\"centered\"}]}");
            foreach (var key in new string[] { "panel-lengths", "panel-sizes" })
                settings.set_string (key, "{\"0\":24,\"1\":32,\"2\":64,\"DEL-different\":72,\"UNPLUGGED-42\":81}");
            settings.set_string ("panel-positions", "{\"0\":\"TOP\",\"HDMI-B\":\"LEFT\",\"2\":\"RIGHT\",\"DEL-different\":\"TOP\",\"UNPLUGGED-42\":\"LEFT\"}");
            assert (inspect_preferences ().state != OptionState.MATCHING);
            var before = stored_layout ("panel-element-positions").get_member ("UNPLUGGED-42").copy ();
            apply_preferences ();
            assert (inspect_preferences ().state == OptionState.MATCHING);
            var anchors = stored_layout ("panel-anchors");
            var elements = stored_layout ("panel-element-positions");
            foreach (var identity in new string[] { "DEL-shared", "HDMI-B", "2", "DEL-different" }) {
                assert_cmpstr (anchors.get_string_member (identity), CompareOperator.EQ, "MIDDLE");
                assert (elements.get_member (identity).equal (element_layout ()));
            }
            assert (!anchors.has_member ("0") && !anchors.has_member ("1"));
            assert_cmpstr (anchors.get_string_member ("UNPLUGGED-42"), CompareOperator.EQ, "END");
            assert (before.equal (elements.get_member ("UNPLUGGED-42")));
            foreach (var key in new string[] { "panel-lengths", "panel-positions", "panel-sizes" }) {
                var retained = stored_layout (key);
                assert_cmpuint (retained.get_size (), CompareOperator.EQ, 1);
                assert (retained.has_member ("UNPLUGGED-42"));
            }
            assert (settings.get_boolean ("unrelated"));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/desktop-settings/semantic-json-and-native-identity-precedence", () => {
        reset_layout ();
        var root = new Json.Node (Json.NodeType.OBJECT);
        var positions = new Json.Object ();
        root.set_object (positions);
        foreach (var identity in new string[] { "DEL-shared", "HDMI-B", "2", "DEL-different" }) {
            var reordered = new Json.Array ();
            foreach (var element in element_layout ().get_array ().get_elements ()) {
                var original = element.get_object ();
                var item = new Json.Object ();
                item.set_string_member ("position", original.get_string_member ("position"));
                item.set_boolean_member ("visible", original.get_boolean_member ("visible"));
                item.set_string_member ("element", original.get_string_member ("element"));
                reordered.add_object_element (item);
            }
            positions.set_array_member (identity, reordered);
        }
        settings.set_string ("panel-element-positions", Json.to_string (root, true));
        settings.set_string ("panel-anchors", "{ \"0\":\"END\", \"DEL-shared\":\"MIDDLE\", \"HDMI-B\":\"MIDDLE\", \"2\":\"MIDDLE\", \"DEL-different\":\"MIDDLE\", \"UNPLUGGED-42\":\"START\" }");
        assert (inspect_preferences ().state == OptionState.MATCHING);
        positions.get_array_member ("HDMI-B").get_object_element (0).set_boolean_member ("visible", true);
        settings.set_string ("panel-element-positions", Json.to_string (root, false));
        assert (inspect_preferences ().state == OptionState.PARTIAL);
    });

    Test.add_func ("/desktop-settings/legacy-layout-uses-miubian-global-preferences", () => {
        try {
            reset_layout ();
            settings.set_string ("panel-position", "TOP");
            settings.set_int ("panel-size", 32);
            var root = new Json.Node (Json.NodeType.OBJECT);
            var positions = new Json.Object ();
            root.set_object (positions);
            foreach (var index in new string[] { "0", "1", "2", "3" })
                positions.set_member (index, element_layout ());
            settings.set_string ("panel-element-positions", Json.to_string (root, false));
            settings.set_string ("panel-positions", "{\"DEL-shared\":\"TOP\",\"1\":\"TOP\",\"2\":\"TOP\",\"3\":\"TOP\",\"UNPLUGGED-42\":\"LEFT\"}");
            settings.set_string ("panel-sizes", "{\"DEL-shared\":32,\"1\":32,\"2\":32,\"3\":32,\"UNPLUGGED-42\":81}");
            assert (inspect_preferences ().state != OptionState.MATCHING);
            settings.set_string ("panel-anchors", "{\"0\":\"START\"}");
            apply_preferences ();
            assert (inspect_preferences ().state == OptionState.MATCHING);
            assert_cmpstr (settings.get_string ("panel-position"), CompareOperator.EQ, "BOTTOM");
            assert_cmpint (settings.get_int ("panel-size"), CompareOperator.EQ, 48);
            assert_cmpuint (stored_layout ("panel-positions").get_size (), CompareOperator.EQ, 1);
            assert_cmpstr (stored_layout ("panel-positions").get_string_member ("UNPLUGGED-42"), CompareOperator.EQ, "LEFT");
            assert_cmpuint (stored_layout ("panel-sizes").get_size (), CompareOperator.EQ, 1);
            assert_cmpint ((int) stored_layout ("panel-sizes").get_int_member ("UNPLUGGED-42"), CompareOperator.EQ, 81);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/desktop-settings/extension-collection-clears-target-disabling-and-retains-unrelated-lists", () => {
        try {
            foreach (var key in shell_settings.settings_schema.list_keys ())
                shell_settings.reset (key);
            var preferences = catalogue_preferences ("desktop-extensions");
            string[] selected = {};
            foreach (var node in preferences.get_array_member ("settings").get_elements ()) {
                var entry = node.get_object ();
                if (entry.get_string_member ("key") == "enabled-extensions")
                    selected = Variant.parse (new VariantType ("as"), entry.get_string_member ("value")).dup_strv ();
            }
            assert_cmpuint (selected.length, CompareOperator.GT, 0);
            string[] disabled = { "unrelated-disabled@example.test" };
            foreach (var identity in selected)
                disabled += identity;
            shell_settings.set_strv ("disabled-extensions", disabled);
            shell_settings.set_strv ("enabled-extensions", { "unrelated-enabled@example.test", "apps-menu@gnome-shell-extensions.gcampax.github.com", selected[0] });
            shell_settings.set_boolean ("disable-user-extensions", true);
            assert (inspect_preferences (preferences).state != OptionState.MATCHING);
            apply_preferences (preferences);
            assert (inspect_preferences (preferences).state == OptionState.MATCHING);
            assert (!shell_settings.get_boolean ("disable-user-extensions"));
            var enabled_after = shell_settings.get_strv ("enabled-extensions");
            var disabled_after = shell_settings.get_strv ("disabled-extensions");
            foreach (var identity in selected) {
                assert (identity in enabled_after);
                assert (!(identity in disabled_after));
            }
            assert ("unrelated-enabled@example.test" in enabled_after);
            assert (!("apps-menu@gnome-shell-extensions.gcampax.github.com" in enabled_after));
            assert_cmpuint (disabled_after.length, CompareOperator.EQ, 1);
            assert_cmpstr (disabled_after[0], CompareOperator.EQ, "unrelated-disabled@example.test");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/desktop-settings/individual-extension-clears-global-disable-and-only-its-own-exclusion", () => {
        try {
            foreach (var key in shell_settings.settings_schema.list_keys ())
                shell_settings.reset (key);
            var preferences = catalogue_preferences ("enable-extension-dash-to-panel");
            var selected = "dash-to-panel@jderose9.github.com";
            shell_settings.set_strv ("enabled-extensions", { "unrelated-enabled@example.test" });
            shell_settings.set_strv ("disabled-extensions", { selected, "arcmenu@arcmenu.com", "unrelated-disabled@example.test" });
            shell_settings.set_boolean ("disable-user-extensions", true);
            assert (inspect_preferences (preferences).state != OptionState.MATCHING);
            apply_preferences (preferences);
            assert (inspect_preferences (preferences).state == OptionState.MATCHING);
            assert (!shell_settings.get_boolean ("disable-user-extensions"));
            var enabled_after = shell_settings.get_strv ("enabled-extensions");
            var disabled_after = shell_settings.get_strv ("disabled-extensions");
            assert (selected in enabled_after);
            assert ("unrelated-enabled@example.test" in enabled_after);
            assert_cmpuint (enabled_after.length, CompareOperator.EQ, 2);
            assert (!(selected in disabled_after));
            assert ("arcmenu@arcmenu.com" in disabled_after);
            assert ("unrelated-disabled@example.test" in disabled_after);
            assert_cmpuint (disabled_after.length, CompareOperator.EQ, 2);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/desktop-settings/tiling-shortcuts-clear-later-layouts-and-retain-saved-layouts", () => {
        try {
            foreach (var key in tiling_settings.settings_schema.list_keys ())
                tiling_settings.reset (key);
            tiling_settings.set_strv ("activate-layout0", { "<Super>0" });
            tiling_settings.set_strv ("activate-layout4", { "<Super>4" });
            tiling_settings.set_strv ("activate-layout19", { "<Super>9" });
            tiling_settings.set_strv ("favorite-layouts", { "personal-saved-layout" });
            var preferences = catalogue_preferences ("desktop-tiling");
            var bindings = new Json.Array ();
            foreach (var node in preferences.get_array_member ("settings").get_elements ()) {
                if (!node.get_object ().get_string_member ("key").has_prefix ("activate-layout"))
                    continue;
                var entry = node.copy ().get_object ();
                entry.set_string_member ("schema", "com.rispeng.MiuUtil.TilingFixture");
                bindings.add_object_element (entry);
            }
            assert_cmpuint (bindings.get_length (), CompareOperator.EQ, 20);
            preferences.set_array_member ("settings", bindings);
            assert (inspect_preferences (preferences).state != OptionState.MATCHING);
            apply_preferences (preferences);
            assert (inspect_preferences (preferences).state == OptionState.MATCHING);
            for (uint index = 0; index < 20; index++)
                assert_cmpuint (tiling_settings.get_strv ("activate-layout%u".printf (index)).length, CompareOperator.EQ, 0);
            var retained = tiling_settings.get_strv ("favorite-layouts");
            assert_cmpuint (retained.length, CompareOperator.EQ, 1);
            assert_cmpstr (retained[0], CompareOperator.EQ, "personal-saved-layout");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/desktop-settings/invalid-map-is-unavailable-without-writing", () => {
        reset_layout ();
        settings.set_string ("panel-anchors", "[]");
        assert (inspect_preferences ().state == OptionState.UNAVAILABLE);
        assert_cmpstr (settings.get_string ("panel-anchors"), CompareOperator.EQ, "[]");
        settings.set_string ("panel-anchors", "invalid json");
        assert (inspect_preferences ().state == OptionState.UNAVAILABLE);
        assert_cmpstr (settings.get_string ("panel-anchors"), CompareOperator.EQ, "invalid json");
    });

    Test.add_func ("/desktop-settings/no-connected-monitor-is-unavailable", () => {
        reset_layout ();
        provide_monitors = false;
        var assessment = inspect_preferences ();
        assert (assessment.state == OptionState.UNAVAILABLE);
        assert (assessment.current.contains ("connected monitor"));
        provide_monitors = true;
    });

    Test.add_func ("/desktop-settings/no-mutter-session-is-unavailable", () => {
        try {
            reset_layout ();
            connection.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                new Variant ("(s)", "org.gnome.Mutter.DisplayConfig"), new VariantType ("(u)"), DBusCallFlags.NONE, 1000);
            var assessment = inspect_preferences ();
            assert (assessment.state == OptionState.UNAVAILABLE);
            assert (assessment.current.contains ("active GNOME session"));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    int result = Test.run ();
    connection.remove_filter (monitor_filter);
    try {
        var cleanup = new Subprocess.newv ({ "rm", "-rf", "--", workspace }, SubprocessFlags.NONE);
        cleanup.wait_check ();
    } catch (Error error) {
        warning ("Could not remove test workspace: %s", error.message);
    }
    return result;
}
