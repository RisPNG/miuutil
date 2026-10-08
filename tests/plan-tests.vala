using MiuUtil;

private Option preference (string id, string key, string value, string dependencies = "[]") throws Error {
    var parser = new Json.Parser ();
    parser.load_from_data ("""
        {"id":"%s","title":"%s","description":"Test preference","category":"desktop",
         "scope":"Your account","risk":"Memory backend","desired":"Test value","details":"Test fixture",
         "requires_admin":false,"dependencies":%s,
         "operation":{"kind":"settings","settings":[{"schema":"com.rispeng.MiuUtil","key":"%s","value":"%s"}]}}
    """.printf (id, id, dependencies, key, value));
    return new Option (parser.get_root ().get_object ());
}

private void detect (Option option) throws Error {
    var loop = new MainLoop ();
    Error? failure = null;
    option.detect.begin (null, (object, result) => {
        try { option.detect.end (result); } catch (Error error) { failure = error; }
        loop.quit ();
    });
    loop.run ();
    if (failure != null) throw failure;
}

private Catalogue fixture () throws Error {
    var settings = new Settings ("com.rispeng.MiuUtil");
    settings.reset ("window-width");
    settings.reset ("window-height");
    settings.reset ("window-maximised");
    var catalogue = new Catalogue ();
    catalogue.options.remove_all ();
    return catalogue;
}

int main (string[] arguments) {
    Test.init (ref arguments);
    Test.add_func ("/plan/orders-shared-dependencies-once", () => {
        try {
            var catalogue = fixture ();
            var parent = preference ("parent", "window-height", "999", "[\"base\"]");
            var sibling = preference ("sibling", "window-maximised", "true", "[\"base\"]");
            var prerequisite = preference ("base", "window-width", "1111");
            foreach (var option in new Option[] { parent, sibling, prerequisite }) {
                catalogue.options.append (option);
                detect (option);
            }
            parent.selected = sibling.selected = true;
            var plan = new ChangePlan (catalogue);
            assert_cmpuint (plan.options.get_n_items (), CompareOperator.EQ, 3);
            assert (((Option) plan.options.get_item (0)).id == "base");
            assert (((Option) plan.options.get_item (1)).id == "parent");
            assert (((Option) plan.options.get_item (2)).id == "sibling");
            assert (!prerequisite.selected);
        } catch (Error error) { Test.message (error.message); Test.fail (); }
    });
    Test.add_func ("/plan/omits-matching-dependencies", () => {
        try {
            var catalogue = fixture ();
            var width = new Settings ("com.rispeng.MiuUtil").get_int ("window-width").to_string ();
            var parent = preference ("parent", "window-height", "999", "[\"base\"]");
            var prerequisite = preference ("base", "window-width", width);
            foreach (var option in new Option[] { parent, prerequisite }) {
                catalogue.options.append (option);
                detect (option);
            }
            parent.selected = true;
            var plan = new ChangePlan (catalogue);
            assert_cmpuint (plan.options.get_n_items (), CompareOperator.EQ, 1);
            assert (((Option) plan.options.get_item (0)).id == "parent");
        } catch (Error error) { Test.message (error.message); Test.fail (); }
    });
    Test.add_func ("/plan/rejects-cycle", () => {
        try {
            var catalogue = fixture ();
            var first = preference ("first", "window-width", "1111", "[\"second\"]");
            catalogue.options.append (first);
            catalogue.options.append (preference ("second", "window-height", "999", "[\"first\"]"));
            first.selected = true;
            new ChangePlan (catalogue);
            Test.fail ();
        } catch (SetupError.INVALID_PLAN error) { assert (error.message.contains ("cycle")); }
        catch (Error error) { Test.message (error.message); Test.fail (); }
    });
    Test.add_func ("/plan/rejects-missing-dependency", () => {
        try {
            var catalogue = fixture ();
            var option = preference ("first", "window-width", "1111", "[\"missing\"]");
            catalogue.options.append (option);
            option.selected = true;
            new ChangePlan (catalogue);
            Test.fail ();
        } catch (SetupError.INVALID_PLAN error) { assert (error.message.contains ("missing")); }
        catch (Error error) { Test.message (error.message); Test.fail (); }
    });
    Test.add_func ("/plan/rejects-unavailable-and-empty", () => {
        try {
            var catalogue = fixture ();
            bool rejected = false;
            try { new ChangePlan (catalogue); }
            catch (SetupError.INVALID_PLAN error) { rejected = true; }
            assert (rejected);
            var option = preference ("first", "window-width", "1111");
            catalogue.options.append (option);
            option.selected = true;
            new ChangePlan (catalogue);
            Test.fail ();
        } catch (SetupError.INVALID_PLAN error) { assert (error.message.contains ("unavailable")); }
        catch (Error error) { Test.message (error.message); Test.fail (); }
    });
    Test.add_func ("/session/failure-preserves-remaining-and-rejects-concurrency", () => {
        string? workspace = null;
        var original_path = Environment.get_variable ("PATH");
        try {
            workspace = DirUtils.make_tmp ("miuutil-session-test-XXXXXX");
            var curl = Path.build_filename (workspace, "curl");
            FileUtils.set_contents (curl, "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do\nif [ \"$1\" = --output ]; then printf corrupted > \"$2\"; exit 0; fi\nshift\ndone\nexit 1\n");
            Posix.chmod (curl, 0755);
            Environment.set_variable ("PATH", workspace + ":" + original_path, true);
            var catalogue = fixture ();
            var first = preference ("first", "window-width", "1111");
            var parser = new Json.Parser ();
            parser.load_from_data ("""
                {"id":"failing","title":"Fetch","description":"Test download","category":"development",
                 "scope":"Your account","risk":"Test corrupt bytes","desired":"Verified fetch","details":"Test fixture",
                 "requires_admin":false,"dependencies":[],"operation":{"kind":"upstream","upstream":"fetch"}}
            """);
            var failing = new Option (parser.get_root ().get_object ());
            var last = preference ("last", "window-height", "999");
            foreach (var option in new Option[] { first, failing, last }) {
                catalogue.options.append (option);
                detect (option);
                option.selected = true;
            }
            var plan = new ChangePlan (catalogue);
            var session = new SetupSession ();
            var loop = new MainLoop ();
            uint successes = 0;
            uint failures = 0;
            bool rejected_parallel = false;
            bool parallel_done = false;
            bool primary_done = false;
            session.completed.connect ((option, success) => {
                if (success) successes++; else failures++;
            });
            session.execute.begin (plan, (object, result) => {
                try { session.execute.end (result); Test.fail (); }
                catch (IOError.INVALID_DATA error) { assert (error.message.contains ("SHA-256")); }
                catch (Error error) { Test.message (error.message); Test.fail (); }
                primary_done = true;
                if (parallel_done) loop.quit ();
            });
            session.execute.begin (plan, (object, result) => {
                try { session.execute.end (result); Test.fail (); }
                catch (SetupError.BUSY error) { rejected_parallel = true; }
                catch (Error error) { Test.message (error.message); Test.fail (); }
                parallel_done = true;
                if (primary_done) loop.quit ();
            });
            loop.run ();
            assert (rejected_parallel && !session.running);
            assert_cmpuint (successes, CompareOperator.EQ, 1);
            assert_cmpuint (failures, CompareOperator.EQ, 1);
            assert (first.state == OptionState.MATCHING && !first.selected);
            assert (failing.selected && last.selected);
            assert (last.state == OptionState.DIFFERENT);
            var retry = new ChangePlan (catalogue);
            assert_cmpuint (retry.options.get_n_items (), CompareOperator.EQ, 2);
        } catch (Error error) { Test.message (error.message); Test.fail (); }
        finally {
            Environment.set_variable ("PATH", original_path, true);
            if (workspace != null) {
                try { new Subprocess.newv ({ "rm", "-rf", "--", workspace }, SubprocessFlags.NONE).wait_check (); }
                catch (Error error) { Test.message (error.message); Test.fail (); }
            }
        }
    });
    return Test.run ();
}
