namespace MiuUtil {
    [GtkTemplate (ui = "/com/rispeng/MiuUtil/ui/option-row.ui")]
    public class OptionRow : Adw.ExpanderRow {
        [GtkChild] private unowned Gtk.CheckButton selection;
        [GtkChild] private unowned Gtk.Label status_label;
        [GtkChild] private unowned Gtk.Label current_label;
        [GtkChild] private unowned Gtk.Label desired_label;
        [GtkChild] private unowned Gtk.Label scope_label;
        [GtkChild] private unowned Gtk.Label risk_label;
        [GtkChild] private unowned Gtk.Label details_label;

        public Option option { get; construct; }
        private bool synchronising;

        public OptionRow (Option option) {
            Object (option: option);
            title = option.title;
            subtitle = option.description;
            selection.update_property (Gtk.AccessibleProperty.LABEL, option.title, -1);
            selection.toggled.connect (() => {
                if (!synchronising)
                    this.option.selected = selection.active;
            });
            option.notify.connect (() => present_option ());
            present_option ();
        }

        private void present_option () {
            synchronising = true;
            selection.active = option.selected;
            selection.sensitive = option.selected ||
                option.state == OptionState.DIFFERENT || option.state == OptionState.PARTIAL;
            selection.tooltip_text = option.selected && option.state == OptionState.UNAVAILABLE
                ? _("Remove this unavailable change from the queue") : _("Queue this change");
            synchronising = false;
            current_label.label = option.current;
            desired_label.label = option.desired;
            scope_label.label = option.requires_admin
                ? _("%s · Administrator approval").printf (option.scope) : option.scope;
            risk_label.label = option.risk;
            details_label.label = option.details;
            status_label.remove_css_class ("success");
            status_label.remove_css_class ("warning");
            status_label.remove_css_class ("dim-label");
            switch (option.state) {
                case OptionState.MATCHING:
                    status_label.label = _("Matching");
                    status_label.add_css_class ("success");
                    break;
                case OptionState.PARTIAL:
                    status_label.label = _("Partly matching");
                    status_label.add_css_class ("warning");
                    break;
                case OptionState.UNAVAILABLE:
                    status_label.label = _("Unavailable");
                    status_label.add_css_class ("dim-label");
                    break;
                default:
                    status_label.label = _("Different");
                    status_label.add_css_class ("dim-label");
                    break;
            }
        }
    }
}
