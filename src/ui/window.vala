namespace MiuUtil {
    [GtkTemplate (ui = "/com/rispeng/MiuUtil/ui/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
        [GtkChild] private unowned Adw.OverlaySplitView split;
        [GtkChild] private unowned Gtk.ListBox navigation;
        [GtkChild] private unowned Gtk.Button sidebar_button;
        [GtkChild] private unowned Gtk.Stack header_stack;
        [GtkChild] private unowned Gtk.SearchEntry search_entry;
        [GtkChild] private unowned Gtk.MenuButton menu_button;
        [GtkChild] private unowned Gtk.Stack page_stack;
        [GtkChild] private unowned Adw.Banner banner;
        [GtkChild] private unowned Gtk.Label category_title;
        [GtkChild] private unowned Gtk.Label category_description;
        [GtkChild] private unowned Gtk.DropDown status_filter;
        [GtkChild] private unowned Gtk.Button bulk_button;
        [GtkChild] private unowned Gtk.Label bulk_label;
        [GtkChild] private unowned Gtk.Label shown_label;
        [GtkChild] private unowned Gtk.Box groups_box;
        [GtkChild] private unowned Adw.StatusPage empty_state;
        [GtkChild] private unowned Gtk.Label selected_label;
        [GtkChild] private unowned Gtk.Button review_button;

        public Catalogue catalogue { get; construct; }
        public bool busy { get { return detecting || review_page.running; } }
        private ReviewPage review_page;
        private bool detecting;
        private bool close_after_current;
        private Cancellable? detection_cancellable;
        private string active_category = "all";
        private string query = "";
        private OptionFilter visibility_filter = new OptionFilter ();
        private GLib.Settings preferences;

        private const string[] CATEGORY_IDS = {
            "all", "desktop", "appearance", "applications", "browsers",
            "development", "files", "system", "recovery"
        };
        private const string[] CATEGORY_ICONS = {
            "view-grid-symbolic", "user-desktop-symbolic", "applications-graphics-symbolic",
            "view-app-grid-symbolic", "web-browser-symbolic", "utilities-terminal-symbolic",
            "folder-symbolic", "preferences-system-symbolic", "document-revert-symbolic"
        };

        public Window (Application application, Catalogue catalogue) {
            Object (application: application, catalogue: catalogue);
            preferences = new GLib.Settings ("com.rispeng.MiuUtil");
            set_default_size (preferences.get_int ("window-width"), preferences.get_int ("window-height"));
            if (preferences.get_boolean ("window-maximised"))
                maximize ();
            var menu = new Menu ();
            menu.append (_("About MiuUtil"), "app.about");
            menu.append (_("Quit"), "app.quit");
            menu_button.menu_model = menu;
            review_page = new ReviewPage (catalogue);
            page_stack.add_named (review_page, "review");
            review_page.back_requested.connect (() => {
                page_stack.visible_child_name = "preferences";
                header_stack.visible_child_name = "search";
                update_selection ();
            });
            review_page.notify["running"].connect (() => {
                notify_property ("busy");
                update_selection ();
            });
            review_page.finished.connect (() => {
                update_filters ();
                if (close_after_current)
                    close ();
            });
            for (uint i = 0; i < CATEGORY_IDS.length; i++) {
                var row = new Gtk.ListBoxRow ();
                var contents = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
                contents.margin_start = 12;
                contents.margin_end = 12;
                contents.margin_top = 10;
                contents.margin_bottom = 10;
                contents.append (new Gtk.Image.from_icon_name (CATEGORY_ICONS[i]));
                var label = new Gtk.Label (category_name (CATEGORY_IDS[i]));
                label.xalign = 0;
                label.wrap = true;
                contents.append (label);
                row.child = contents;
                if (i == 0)
                    row.margin_bottom = 12;
                navigation.append (row);
                if (i == 0)
                    navigation.select_row (row);
            }
            navigation.row_selected.connect ((row) => {
                if (row == null)
                    return;
                active_category = CATEGORY_IDS[row.get_index ()];
                category_title.label = category_name (active_category);
                category_description.label = category_description_for (active_category);
                search_entry.placeholder_text = active_category == "all"
                    ? _("Search all categories") : _("Search this category");
                if (!review_page.running) {
                    page_stack.visible_child_name = "preferences";
                    header_stack.visible_child_name = "search";
                }
                update_filters ();
            });
            navigation.row_activated.connect (() => {
                if (split.collapsed)
                    split.show_sidebar = false;
            });
            sidebar_button.clicked.connect (() => split.show_sidebar = !split.show_sidebar);
            search_entry.search_changed.connect (() => {
                query = search_entry.text.strip ().casefold ();
                update_filters ();
            });
            status_filter.notify["selected"].connect (() => update_filters ());
            banner.button_clicked.connect (() => refresh.begin ());
            bulk_button.clicked.connect (() => {
                bool all_selected = true;
                for (uint i = 0; i < this.catalogue.options.get_n_items (); i++) {
                    var option = (Option) this.catalogue.options.get_item (i);
                    if (visibility_filter.match (option) &&
                        (option.state == OptionState.DIFFERENT || option.state == OptionState.PARTIAL))
                        all_selected = all_selected && option.selected;
                }
                for (uint i = 0; i < this.catalogue.options.get_n_items (); i++) {
                    var option = (Option) this.catalogue.options.get_item (i);
                    if (visibility_filter.match (option) &&
                        (option.state == OptionState.DIFFERENT || option.state == OptionState.PARTIAL))
                        option.selected = !all_selected;
                }
            });
            review_button.clicked.connect (() => {
                try {
                    review_page.review_plan (new ChangePlan (this.catalogue));
                    page_stack.visible_child_name = "review";
                    header_stack.visible_child_name = "review";
                } catch (Error error) {
                    toast_overlay.add_toast (new Adw.Toast (error.message));
                }
            });
            for (uint i = 1; i < CATEGORY_IDS.length; i++) {
                string category = CATEGORY_IDS[i];
                var category_filter = new Gtk.StringFilter (new Gtk.PropertyExpression (
                    typeof (Option), null, "category"));
                category_filter.search = category;
                category_filter.match_mode = Gtk.StringFilterMatchMode.EXACT;
                category_filter.ignore_case = false;
                var filter = new Gtk.EveryFilter ();
                filter.append (visibility_filter);
                filter.append (category_filter);
                var model = new Gtk.FilterListModel (catalogue.options, filter);
                var group = new Adw.PreferencesGroup ();
                group.title = Markup.escape_text (category_name (category));
                var list = new Gtk.ListBox ();
                list.selection_mode = Gtk.SelectionMode.NONE;
                list.add_css_class ("boxed-list");
                list.bind_model (model, create_option_row);
                bind_property ("busy", list, "sensitive",
                    BindingFlags.SYNC_CREATE | BindingFlags.INVERT_BOOLEAN);
                group.add (list);
                model.bind_property ("n-items", group, "visible", BindingFlags.SYNC_CREATE, group_has_options);
                groups_box.append (group);
            }
            for (uint i = 0; i < catalogue.options.get_n_items (); i++) {
                var option = (Option) catalogue.options.get_item (i);
                option.notify.connect ((property) => {
                    if (property.name == "state")
                        update_filters ();
                    else if (property.name == "selected")
                        update_selection ();
                });
            }
            close_request.connect (() => {
                if (review_page.running) {
                    request_stop_and_wait ();
                    return true;
                }
                if (detection_cancellable != null)
                    detection_cancellable.cancel ();
                preferences.set_boolean ("window-maximised", maximized);
                if (!maximized) {
                    preferences.set_int ("window-width", default_width);
                    preferences.set_int ("window-height", default_height);
                }
                return false;
            });
            update_selection ();
        }

        public async void refresh () {
            if (busy)
                return;
            detecting = true;
            detection_cancellable = new Cancellable ();
            notify_property ("busy");
            banner.title = _("Checking current settings…");
            banner.revealed = true;
            update_selection ();
            try {
                yield catalogue.detect_all (detection_cancellable);
                banner.revealed = false;
            } catch (Error error) {
                if (!(error is IOError.CANCELLED)) {
                    banner.title = error.message;
                    banner.revealed = true;
                }
            } finally {
                detecting = false;
                detection_cancellable = null;
                notify_property ("busy");
                update_filters ();
            }
        }

        public void request_stop_and_wait () {
            if (!review_page.running) {
                close ();
                return;
            }
            close_after_current = true;
            review_page.request_stop ();
            page_stack.visible_child_name = "review";
            header_stack.visible_child_name = "review";
            toast_overlay.add_toast (new Adw.Toast (_("Finishing the current change before closing.")));
        }

        private static Gtk.Widget create_option_row (Object item) {
            return new OptionRow ((Option) item);
        }

        private static bool group_has_options (Binding binding, Value source, ref Value target) {
            target.set_boolean (source.get_uint () > 0);
            return true;
        }

        private void update_filters () {
            visibility_filter.category = active_category;
            visibility_filter.query = query;
            visibility_filter.status = status_filter.selected;
            visibility_filter.changed (Gtk.FilterChange.DIFFERENT);
            update_selection ();
        }

        private void update_selection () {
            uint shown = 0;
            uint eligible = 0;
            uint visible_selected = 0;
            uint selected = 0;
            uint unavailable_selected = 0;
            for (uint i = 0; i < catalogue.options.get_n_items (); i++) {
                var option = (Option) catalogue.options.get_item (i);
                if (option.selected)
                    selected++;
                if (option.selected && option.state == OptionState.UNAVAILABLE)
                    unavailable_selected++;
                if (!visibility_filter.match (option))
                    continue;
                shown++;
                if (option.state == OptionState.DIFFERENT || option.state == OptionState.PARTIAL) {
                    eligible++;
                    if (option.selected)
                        visible_selected++;
                }
            }
            bool all_selected = eligible > 0 && eligible == visible_selected;
            bulk_label.label = all_selected ? _("Deselect all") : _("Select all");
            bulk_button.tooltip_text = all_selected
                ? _("Deselect all eligible settings in this view")
                : _("Select all eligible settings in this view");
            bulk_button.sensitive = !busy && eligible > 0;
            shown_label.label = ngettext ("%u setting shown", "%u settings shown", shown).printf (shown);
            selected_label.label = selected == 0 ? _("No changes selected")
                : ngettext ("%u change selected", "%u changes selected", selected).printf (selected);
            if (unavailable_selected > 0)
                selected_label.label += _(" · %u unavailable").printf (unavailable_selected);
            review_button.sensitive = !busy && selected > 0;
            empty_state.visible = shown == 0;
            navigation.sensitive = !review_page.running;
        }

        private string category_name (string category) {
            switch (category) {
                case "desktop": return _("Desktop");
                case "appearance": return _("Appearance");
                case "applications": return _("Applications");
                case "browsers": return _("Browsers");
                case "development": return _("Terminal & development");
                case "files": return _("Files & shortcuts");
                case "system": return _("System");
                case "recovery": return _("Recovery");
                default: return _("All categories");
            }
        }

        private string category_description_for (string category) {
            switch (category) {
                case "desktop": return _("Panel, application menu and window behaviour.");
                case "appearance": return _("Themes, icons, fonts and application blur.");
                case "applications": return _("Individual applications from their usual sources.");
                case "browsers": return _("Tabs, defaults and privacy choices kept separate.");
                case "development": return _("Console, Bash and selected development tools.");
                case "files": return _("File-manager actions and keyboard shortcuts.");
                case "system": return _("Memory, monitor controls and administrator access.");
                case "recovery": return _("Snapshots on an existing compatible filesystem.");
                default: return _("Choose changes from across the Miubian setup.");
            }
        }
    }

    public class OptionFilter : Gtk.Filter {
        public string category { get; set; default = "all"; }
        public string query { get; set; default = ""; }
        public uint status { get; set; default = 0; }

        public override bool match (Object? item) {
            var option = (Option) item;
            if (category != "all" && option.category != category)
                return false;
            if (query != "" && !(option.title + " " + option.description + " " + option.details)
                .casefold ().contains (query))
                return false;
            switch (status) {
                case 1:
                    return option.state == OptionState.DIFFERENT || option.state == OptionState.PARTIAL;
                case 2:
                    return option.state == OptionState.MATCHING;
                case 3:
                    return option.state == OptionState.UNAVAILABLE;
                default:
                    return true;
            }
        }

        public override Gtk.FilterMatch get_strictness () {
            return Gtk.FilterMatch.SOME;
        }
    }
}
