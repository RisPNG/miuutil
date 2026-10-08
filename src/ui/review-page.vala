namespace MiuUtil {
    [GtkTemplate (ui = "/com/rispeng/MiuUtil/ui/review-page.ui")]
    public class ReviewPage : Gtk.Box {
        [GtkChild] private unowned Gtk.Label heading;
        [GtkChild] private unowned Gtk.Label summary_label;
        [GtkChild] private unowned Gtk.Label approval_label;
        [GtkChild] private unowned Adw.PreferencesGroup changes_group;
        [GtkChild] private unowned Adw.PreferencesGroup results_group;
        [GtkChild] private unowned Gtk.Box progress_box;
        [GtkChild] private unowned Gtk.Label current_label;
        [GtkChild] private unowned Gtk.ProgressBar progress_bar;
        [GtkChild] private unowned Gtk.Label stop_label;
        [GtkChild] private unowned Gtk.TextView output_view;
        [GtkChild] private unowned Gtk.Button back_button;
        [GtkChild] private unowned Gtk.Button retry_button;
        [GtkChild] private unowned Gtk.Button stop_button;
        [GtkChild] private unowned Gtk.Button apply_button;

        public Catalogue catalogue { get; construct; }
        public bool running { get { return session.running; } }
        public signal void back_requested ();
        public signal void finished ();

        private SetupSession session;
        private ChangePlan? plan;
        private GenericArray<Gtk.Widget> change_rows = new GenericArray<Gtk.Widget> ();
        private GenericArray<Gtk.Widget> result_widgets = new GenericArray<Gtk.Widget> ();
        private HashTable<string, Adw.ActionRow> result_rows =
            new HashTable<string, Adw.ActionRow> (str_hash, str_equal);
        private HashTable<string, bool> finished_options =
            new HashTable<string, bool> (str_hash, str_equal);
        private uint completed_count;
        private uint failure_count;
        private bool has_started;

        public ReviewPage (Catalogue catalogue) {
            Object (catalogue: catalogue);
            session = new SetupSession ();
            back_button.clicked.connect (() => back_requested ());
            apply_button.clicked.connect (() => apply_plan.begin ());
            stop_button.clicked.connect (() => request_stop ());
            retry_button.clicked.connect (() => {
                try {
                    review_plan (new ChangePlan (this.catalogue));
                } catch (Error error) {
                    summary_label.label = error.message;
                }
            });
            session.notify["running"].connect (() => notify_property ("running"));
            session.progress.connect ((option, text) => {
                current_label.label = option.title;
                record_output ("[%s] %s".printf (option.title, text));
            });
            session.completed.connect ((option, success, text) => {
                completed_count++;
                finished_options.insert (option.id, true);
                if (success)
                    option.selected = false;
                else
                    failure_count++;
                var row = result_rows.lookup (option.id);
                if (row != null) {
                    row.subtitle = text;
                    row.add_suffix (new Gtk.Image.from_icon_name (
                        success ? "emblem-ok-symbolic" : "dialog-warning-symbolic"));
                }
                progress_bar.fraction = (double) completed_count / plan.options.get_n_items ();
                progress_bar.text = _("%u of %u finished").printf (
                    completed_count, plan.options.get_n_items ());
                record_output ("[%s] %s".printf (option.title, text));
            });
        }

        public void review_plan (ChangePlan next_plan) {
            if (running)
                return;
            plan = next_plan;
            has_started = false;
            completed_count = 0;
            failure_count = 0;
            foreach (var row in change_rows)
                changes_group.remove (row);
            change_rows = new GenericArray<Gtk.Widget> ();
            foreach (var row in result_widgets)
                results_group.remove (row);
            result_widgets = new GenericArray<Gtk.Widget> ();
            result_rows.remove_all ();
            finished_options.remove_all ();
            output_view.buffer.text = "";
            heading.label = _("Review changes");
            summary_label.label = plan.summary;
            approval_label.visible = plan.requires_admin;
            changes_group.visible = true;
            results_group.visible = false;
            progress_box.visible = false;
            stop_label.visible = false;
            progress_bar.fraction = 0;
            back_button.sensitive = true;
            retry_button.visible = false;
            stop_button.visible = false;
            apply_button.visible = true;
            apply_button.sensitive = plan.options.get_n_items () > 0;
            for (uint i = 0; i < plan.options.get_n_items (); i++) {
                var option = (Option) plan.options.get_item (i);
                var row = new Adw.ExpanderRow ();
                row.title = option.title;
                row.subtitle = option.requires_admin
                    ? _("%s · Administrator approval").printf (option.scope) : option.scope;
                if (!option.selected)
                    row.subtitle = _("Required dependency · %s").printf (row.subtitle);
                row.title_lines = 0;
                row.subtitle_lines = 0;
                row.use_markup = false;
                row.expanded = true;
                var details = new Gtk.Label (_("Miubian: %s\n\n%s\n\n%s").printf (
                    option.desired, option.details, option.risk));
                details.xalign = 0;
                details.wrap = true;
                details.wrap_mode = Pango.WrapMode.WORD_CHAR;
                details.selectable = true;
                details.margin_start = 18;
                details.margin_end = 18;
                details.margin_top = 12;
                details.margin_bottom = 18;
                row.add_row (details);
                changes_group.add (row);
                change_rows.add (row);
            }
        }

        public void request_stop () {
            session.stop_requested = true;
            stop_label.visible = true;
            stop_button.sensitive = false;
        }

        private async void apply_plan () {
            if (plan == null || running || has_started)
                return;
            has_started = true;
            changes_group.visible = false;
            results_group.visible = true;
            progress_box.visible = true;
            heading.label = _("Applying changes");
            summary_label.label = _("Changes are applied in order and checked afterwards.");
            back_button.sensitive = false;
            apply_button.visible = false;
            stop_button.visible = true;
            stop_button.sensitive = true;
            progress_bar.text = _("0 of %u finished").printf (plan.options.get_n_items ());
            for (uint i = 0; i < plan.options.get_n_items (); i++) {
                var option = (Option) plan.options.get_item (i);
                var row = new Adw.ActionRow ();
                row.title = option.title;
                row.subtitle = _("Waiting");
                row.title_lines = 0;
                row.subtitle_lines = 0;
                row.use_markup = false;
                results_group.add (row);
                result_widgets.add (row);
                result_rows.insert (option.id, row);
            }
            try {
                yield session.execute (plan);
                if (session.stop_requested && completed_count < plan.options.get_n_items ()) {
                    heading.label = _("Stopped");
                    summary_label.label = _("The current change finished. Remaining changes are still selected.");
                } else if (failure_count > 0) {
                    heading.label = _("Some changes need attention");
                    summary_label.label = _("Successful changes were verified. Review the remaining choices to try again.");
                } else {
                    heading.label = _("Changes complete");
                    summary_label.label = _("All changes in this plan were applied and verified.");
                }
            } catch (Error error) {
                heading.label = failure_count > 0
                    ? _("Some changes need attention") : _("Could not apply changes");
                summary_label.label = error.message;
                record_output (error.message);
            }
            for (uint i = 0; i < plan.options.get_n_items (); i++) {
                var option = (Option) plan.options.get_item (i);
                if (!finished_options.contains (option.id))
                    result_rows.lookup (option.id).subtitle = _("Not applied");
            }
            current_label.label = _("%u changes finished; %u failed.").printf (
                completed_count, failure_count);
            back_button.sensitive = true;
            stop_button.visible = false;
            stop_label.visible = false;
            uint remaining = 0;
            for (uint i = 0; i < catalogue.options.get_n_items (); i++) {
                var option = (Option) catalogue.options.get_item (i);
                if (option.selected)
                    remaining++;
            }
            retry_button.visible = remaining > 0;
            finished ();
        }

        private void record_output (string text) {
            var buffer = output_view.buffer;
            Gtk.TextIter end;
            buffer.get_end_iter (out end);
            buffer.insert (ref end, text.has_suffix ("\n") ? text : text + "\n", -1);
            if (buffer.get_char_count () > 200000) {
                Gtk.TextIter start;
                Gtk.TextIter cutoff;
                buffer.get_start_iter (out start);
                buffer.get_iter_at_offset (out cutoff, buffer.get_char_count () - 200000);
                buffer.delete (ref start, ref cutoff);
            }
            buffer.get_end_iter (out end);
            output_view.scroll_to_iter (end, 0, false, 0, 1);
        }
    }
}
