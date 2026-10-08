namespace MiuUtil {
    public class Application : Adw.Application {
        private Catalogue? catalogue;
        private SimpleAction refresh_action;

        public Application () {
            Object (application_id: "com.rispeng.MiuUtil", flags: ApplicationFlags.DEFAULT_FLAGS);
        }

        protected override void startup () {
            base.startup ();
            var display = Gdk.Display.get_default ();
            var stylesheet = new Gtk.CssProvider ();
            stylesheet.load_from_resource ("/com/rispeng/MiuUtil/ui/style.css");
            Gtk.StyleContext.add_provider_for_display (
                display, stylesheet, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            Gtk.IconTheme.get_for_display (display).add_resource_path (
                "/com/rispeng/MiuUtil/icons");
            var quit_action = new SimpleAction ("quit", null);
            quit_action.activate.connect (() => {
                var window = active_window as Window;
                if (window != null)
                    window.request_stop_and_wait ();
                else
                    quit ();
            });
            add_action (quit_action);
            set_accels_for_action ("app.quit", { "<primary>q" });
            refresh_action = new SimpleAction ("refresh", null);
            refresh_action.activate.connect (() => {
                var window = active_window as Window;
                if (window != null)
                    window.refresh.begin ();
            });
            add_action (refresh_action);
            set_accels_for_action ("app.refresh", { "<primary>r", "F5" });
            var about_action = new SimpleAction ("about", null);
            about_action.activate.connect (() => {
                var about = new Adw.AboutDialog ();
                about.application_name = "MiuUtil";
                about.application_icon = "com.rispeng.MiuUtil";
                about.version = Config.VERSION;
                about.developer_name = "Ris Peng";
                about.developers = { "Ris Peng <hello@rispeng.com>" };
                about.comments = _("Debian GNOME setup utility for Miubian.");
                about.license_type = Gtk.License.CUSTOM;
                about.license = "BSD Zero Clause License\n\nPermission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.";
                about.present (active_window);
            });
            add_action (about_action);
        }

        protected override void activate () {
            if (active_window != null) {
                active_window.present ();
                return;
            }
            try {
                if (catalogue == null)
                    catalogue = new Catalogue ();
                var window = new Window (this, catalogue);
                window.notify["busy"].connect (() => {
                    var current = active_window as Window;
                    if (current != null)
                        refresh_action.set_enabled (!current.busy);
                });
                window.present ();
                window.refresh.begin ();
            } catch (Error error) {
                var page = new Adw.StatusPage ();
                page.title = _("MiuUtil could not start");
                page.description = error.message;
                page.icon_name = "dialog-error-symbolic";
                var window = new Adw.ApplicationWindow (this);
                window.title = "MiuUtil";
                window.default_width = 600;
                window.default_height = 400;
                window.content = page;
                refresh_action.set_enabled (false);
                window.present ();
            }
        }
    }
}
