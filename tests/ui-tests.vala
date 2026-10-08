private MiuUtil.Application application;

private MiuUtil.Option settings_option (string id, string category, string entries,
                                       string dependencies = "[]",
                                       string details = "Changes the named test preferences.") throws GLib.Error {
    var parser = new Json.Parser ();
    parser.load_from_data ("""
        {
          "id": "%s", "title": "%s choice", "description": "Test preference",
          "category": "%s", "scope": "Your account", "risk": "Test memory settings",
          "desired": "Test target", "details": "%s",
          "requires_admin": false, "dependencies": %s,
          "operation": {"kind": "settings", "settings": %s}
        }
    """.printf (id, id, category, details, dependencies, entries));
    return new MiuUtil.Option (parser.get_root ().get_object ());
}

private MiuUtil.Catalogue fixture_catalogue () throws GLib.Error {
    var settings = new GLib.Settings ("com.rispeng.MiuUtil");
    settings.reset ("window-width");
    settings.reset ("window-height");
    settings.reset ("window-maximised");
    string default_width = settings.get_int ("window-width").to_string ();
    var catalogue = new MiuUtil.Catalogue ();
    catalogue.options.remove_all ();
    catalogue.options.append (settings_option ("desktop", "desktop", """
      [{"schema":"com.rispeng.MiuUtil","key":"window-width","value":"1111"}]
    """));
    catalogue.options.append (settings_option ("matching", "desktop", """
      [{"schema":"com.rispeng.MiuUtil","key":"window-width","value":"%s"}]
    """.printf (default_width)));
    catalogue.options.append (settings_option ("unavailable", "desktop", """
      [{"schema":"com.rispeng.MissingTestSchema","key":"missing","value":"true"}]
    """));
    catalogue.options.append (settings_option ("appearance", "appearance", """
      [{"schema":"com.rispeng.MiuUtil","key":"window-width","value":"%s"},
       {"schema":"com.rispeng.MiuUtil","key":"window-height","value":"999"}]
    """.printf (default_width)));
    catalogue.options.append (settings_option ("browser", "browsers", """
      [{"schema":"com.rispeng.MiuUtil","key":"window-height","value":"900"}]
    """));
    catalogue.options.append (settings_option ("application", "applications", """
      [{"schema":"com.rispeng.MiuUtil","key":"window-maximised","value":"true"}]
    """, "[\"desktop\"]"));
    bool done = false;
    GLib.Error? failure = null;
    catalogue.detect_all.begin (null, (object, result) => {
        try {
            catalogue.detect_all.end (result);
        } catch (GLib.Error error) {
            failure = error;
        }
        done = true;
    });
    while (!done)
        GLib.MainContext.default ().iteration (true);
    if (failure != null)
        throw failure;
    return catalogue;
}

private void bulk_selection () {
    try {
        var theme = Gtk.IconTheme.get_for_display (Gdk.Display.get_default ());
        assert (theme.has_icon ("select-all-symbolic"));
        var catalogue = fixture_catalogue ();
        var window = new MiuUtil.Window (application, catalogue);
        var sidebar = (Gtk.Button) window.get_template_child (typeof (MiuUtil.Window), "sidebar_button");
        assert (theme.has_icon (sidebar.icon_name));
        var bulk = (Gtk.Button) window.get_template_child (typeof (MiuUtil.Window), "bulk_button");
        var navigation = (Gtk.ListBox) window.get_template_child (typeof (MiuUtil.Window), "navigation");
        var filter = (Gtk.DropDown) window.get_template_child (typeof (MiuUtil.Window), "status_filter");
        var selected = (Gtk.Label) window.get_template_child (typeof (MiuUtil.Window), "selected_label");
        bulk.clicked ();
        assert (((MiuUtil.Option) catalogue.options.get_item (0)).selected);
        assert (!((MiuUtil.Option) catalogue.options.get_item (1)).selected);
        assert (!((MiuUtil.Option) catalogue.options.get_item (2)).selected);
        assert (((MiuUtil.Option) catalogue.options.get_item (3)).selected);
        assert (((MiuUtil.Option) catalogue.options.get_item (4)).selected);
        assert (((MiuUtil.Option) catalogue.options.get_item (5)).selected);
        assert (selected.label == "4 changes selected");
        navigation.select_row (navigation.get_row_at_index (4));
        bulk.clicked ();
        assert (!((MiuUtil.Option) catalogue.options.get_item (4)).selected);
        assert (((MiuUtil.Option) catalogue.options.get_item (0)).selected);
        assert (((MiuUtil.Option) catalogue.options.get_item (3)).selected);
        assert (((MiuUtil.Option) catalogue.options.get_item (5)).selected);
        assert (selected.label == "3 changes selected");
        navigation.select_row (navigation.get_row_at_index (0));
        filter.selected = 2;
        assert (!bulk.sensitive);
        assert (!((MiuUtil.Option) catalogue.options.get_item (1)).selected);
        assert (selected.label == "3 changes selected");
        window.destroy ();
    } catch (GLib.Error error) {
        GLib.error ("UI selection test failed: %s", error.message);
    }
}

private void search_and_status () {
    try {
        var catalogue = fixture_catalogue ();
        var window = new MiuUtil.Window (application, catalogue);
        var search = (Gtk.SearchEntry) window.get_template_child (typeof (MiuUtil.Window), "search_entry");
        var filter = (Gtk.DropDown) window.get_template_child (typeof (MiuUtil.Window), "status_filter");
        var shown = (Gtk.Label) window.get_template_child (typeof (MiuUtil.Window), "shown_label");
        var bulk = (Gtk.Button) window.get_template_child (typeof (MiuUtil.Window), "bulk_button");
        assert (shown.label == "6 settings shown");
        filter.selected = 1;
        assert (shown.label == "4 settings shown");
        search.text = "APPEARANCE";
        search.search_changed ();
        assert (shown.label == "1 setting shown");
        assert (bulk.sensitive);
        bulk.clicked ();
        search.text = "";
        search.search_changed ();
        filter.selected = 3;
        assert (shown.label == "1 setting shown");
        assert (!bulk.sensitive);
        assert (((MiuUtil.Option) catalogue.options.get_item (3)).selected);
        window.destroy ();
    } catch (GLib.Error error) {
        GLib.error ("UI filter test failed: %s", error.message);
    }
}

private void remove_unavailable_selection () {
    try {
        var catalogue = fixture_catalogue ();
        var option = (MiuUtil.Option) catalogue.options.get_item (2);
        option.selected = true;
        var row = new MiuUtil.OptionRow (option);
        var selection = (Gtk.CheckButton) row.get_template_child (typeof (MiuUtil.OptionRow), "selection");
        assert (selection.active);
        assert (selection.sensitive);
        selection.active = false;
        assert (!option.selected);
        assert (!selection.sensitive);
    } catch (GLib.Error error) {
        GLib.error ("UI unavailable selection test failed: %s", error.message);
    }
}

private uint expander_count (Gtk.Widget widget) {
    uint count = (widget is Adw.ExpanderRow) ? 1 : 0;
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ())
        count += expander_count (child);
    return count;
}

private void global_review () {
    try {
        var catalogue = fixture_catalogue ();
        ((MiuUtil.Option) catalogue.options.get_item (5)).selected = true;
        var window = new MiuUtil.Window (application, catalogue);
        var navigation = (Gtk.ListBox) window.get_template_child (typeof (MiuUtil.Window), "navigation");
        var button = (Gtk.Button) window.get_template_child (typeof (MiuUtil.Window), "review_button");
        var pages = (Gtk.Stack) window.get_template_child (typeof (MiuUtil.Window), "page_stack");
        navigation.select_row (navigation.get_row_at_index (2));
        assert (button.sensitive);
        button.clicked ();
        assert (pages.visible_child_name == "review");
        var review = (MiuUtil.ReviewPage) pages.get_child_by_name ("review");
        var changes = (Adw.PreferencesGroup) review.get_template_child (typeof (MiuUtil.ReviewPage), "changes_group");
        assert (expander_count (changes) == 2);
        var back = (Gtk.Button) review.get_template_child (typeof (MiuUtil.ReviewPage), "back_button");
        back.clicked ();
        assert (pages.visible_child_name == "preferences");
        assert (((MiuUtil.Option) catalogue.options.get_item (5)).selected);
        window.destroy ();
    } catch (GLib.Error error) {
        GLib.error ("UI review test failed: %s", error.message);
    }
}

private void apply_and_verify () {
    try {
        var catalogue = fixture_catalogue ();
        var option = (MiuUtil.Option) catalogue.options.get_item (0);
        option.selected = true;
        var review = new MiuUtil.ReviewPage (catalogue);
        review.review_plan (new MiuUtil.ChangePlan (catalogue));
        var apply = (Gtk.Button) review.get_template_child (typeof (MiuUtil.ReviewPage), "apply_button");
        var heading = (Gtk.Label) review.get_template_child (typeof (MiuUtil.ReviewPage), "heading");
        bool done = false;
        review.finished.connect (() => done = true);
        apply.clicked ();
        while (!done)
            GLib.MainContext.default ().iteration (true);
        assert (!review.running);
        assert (heading.label == "Changes complete");
        assert (option.state == MiuUtil.OptionState.MATCHING);
        assert (!option.selected);
        assert (new GLib.Settings ("com.rispeng.MiuUtil").get_int ("window-width") == 1111);
    } catch (GLib.Error error) {
        GLib.error ("UI apply test failed: %s", error.message);
    }
}

private void stop_after_current () {
    try {
        var catalogue = fixture_catalogue ();
        var first = (MiuUtil.Option) catalogue.options.get_item (0);
        var second = (MiuUtil.Option) catalogue.options.get_item (4);
        first.selected = true;
        second.selected = true;
        var review = new MiuUtil.ReviewPage (catalogue);
        review.review_plan (new MiuUtil.ChangePlan (catalogue));
        var stop = (Gtk.Button) review.get_template_child (typeof (MiuUtil.ReviewPage), "stop_button");
        first.output.connect (() => stop.clicked ());
        var apply = (Gtk.Button) review.get_template_child (typeof (MiuUtil.ReviewPage), "apply_button");
        var heading = (Gtk.Label) review.get_template_child (typeof (MiuUtil.ReviewPage), "heading");
        var retry = (Gtk.Button) review.get_template_child (typeof (MiuUtil.ReviewPage), "retry_button");
        bool done = false;
        review.finished.connect (() => done = true);
        apply.clicked ();
        while (!done)
            GLib.MainContext.default ().iteration (true);
        assert (heading.label == "Stopped");
        assert (!first.selected);
        assert (first.state == MiuUtil.OptionState.MATCHING);
        assert (second.selected);
        assert (second.state == MiuUtil.OptionState.DIFFERENT);
        var settings = new GLib.Settings ("com.rispeng.MiuUtil");
        assert (settings.get_int ("window-height") == settings.get_default_value ("window-height").get_int32 ());
        assert (retry.visible);
        retry.clicked ();
        assert (heading.label == "Review changes");
        assert (expander_count ((Gtk.Widget) review.get_template_child (
            typeof (MiuUtil.ReviewPage), "changes_group")) == 1);
    } catch (GLib.Error error) {
        GLib.error ("UI stop test failed: %s", error.message);
    }
}

private void narrow_navigation () {
    try {
        var catalogue = fixture_catalogue ();
        catalogue.options.append (settings_option ("long-path", "desktop", """
          [{"schema":"com.rispeng.MiuUtil","key":"window-width","value":"1111"}]
        """, "[]", "Read /usr/local/share/miubian/configuration/this-is-a-long-unbroken-configuration-path-used-to-check-that-technical-details-fit-the-narrow-window.toml"));
        var window = new MiuUtil.Window (application, catalogue);
        window.set_default_size (360, 760);
        bool allocated = false;
        window.add_tick_callback (() => {
            if (window.get_width () == 0)
                return GLib.Source.CONTINUE;
            allocated = true;
            return GLib.Source.REMOVE;
        });
        window.present ();
        while (!allocated)
            GLib.MainContext.default ().iteration (true);
        var split = (Adw.OverlaySplitView) window.get_template_child (typeof (MiuUtil.Window), "split");
        var sidebar = (Gtk.Button) window.get_template_child (typeof (MiuUtil.Window), "sidebar_button");
        var review = (Gtk.Button) window.get_template_child (typeof (MiuUtil.Window), "review_button");
        assert (split.collapsed);
        assert (!split.show_sidebar);
        assert (sidebar.visible);
        assert (window.get_width () <= 360);
        Graphene.Rect bounds;
        assert (review.compute_bounds (window, out bounds));
        assert (bounds.origin.x >= 0);
        assert (bounds.origin.x + bounds.size.width <= window.get_width ());
        sidebar.clicked ();
        assert (split.show_sidebar);
        var navigation = (Gtk.ListBox) window.get_template_child (typeof (MiuUtil.Window), "navigation");
        navigation.select_row (navigation.get_row_at_index (1));
        navigation.row_activated (navigation.get_row_at_index (1));
        assert (!split.show_sidebar);
        ((MiuUtil.Option) catalogue.options.get_item (0)).selected = true;
        review.clicked ();
        allocated = false;
        window.add_tick_callback (() => {
            allocated = true;
            return GLib.Source.REMOVE;
        });
        while (!allocated)
            GLib.MainContext.default ().iteration (true);
        var pages = (Gtk.Stack) window.get_template_child (typeof (MiuUtil.Window), "page_stack");
        var review_page = (MiuUtil.ReviewPage) pages.get_child_by_name ("review");
        Gtk.Button[] controls = {
            (Gtk.Button) review_page.get_template_child (typeof (MiuUtil.ReviewPage), "back_button"),
            (Gtk.Button) review_page.get_template_child (typeof (MiuUtil.ReviewPage), "apply_button")
        };
        foreach (var control in controls) {
            assert (control.compute_bounds (window, out bounds));
            assert (bounds.origin.x >= 0);
            assert (bounds.origin.x + bounds.size.width <= window.get_width ());
        }
        window.destroy ();
    } catch (GLib.Error error) {
        GLib.error ("UI narrow navigation test failed: %s", error.message);
    }
}

int main (string[] args) {
    string runtime;
    try {
        runtime = GLib.DirUtils.make_tmp ("miuutil-ui-runtime-XXXXXX");
    } catch (GLib.Error error) {
        GLib.error ("Could not create the UI test runtime: %s", error.message);
    }
    GLib.Environment.set_variable ("XDG_RUNTIME_DIR", runtime, true);
    GLib.Test.init (ref args);
    Adw.init ();
    application = new MiuUtil.Application ();
    try {
        application.register ();
    } catch (GLib.Error error) {
        GLib.error ("Could not register the UI test application: %s", error.message);
    }
    GLib.Test.add_func ("/ui/bulk-selection-retains-hidden-choices", bulk_selection);
    GLib.Test.add_func ("/ui/search-and-status-filter", search_and_status);
    GLib.Test.add_func ("/ui/remove-unavailable-selection", remove_unavailable_selection);
    GLib.Test.add_func ("/ui/global-review-resolves-dependencies", global_review);
    GLib.Test.add_func ("/ui/apply-and-verify", apply_and_verify);
    GLib.Test.add_func ("/ui/stop-after-current-and-review-remaining", stop_after_current);
    GLib.Test.add_func ("/ui/narrow-navigation-and-footer", narrow_navigation);
    int result = GLib.Test.run ();
    GLib.DirUtils.remove (runtime);
    return result;
}
