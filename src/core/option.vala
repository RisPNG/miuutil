namespace MiuUtil {
    public enum OptionState {
        DIFFERENT,
        PARTIAL,
        MATCHING,
        UNAVAILABLE
    }

    public class Assessment : Object {
        public OptionState state { get; construct; }
        public string current { get; construct; }
        public string details { get; construct; }
        public bool dependency_blocked { get; construct; }

        public Assessment (OptionState state, string current, string details = "", bool dependency_blocked = false) {
            Object (state: state, current: current, details: details, dependency_blocked: dependency_blocked);
        }
    }

    public abstract class Operation : Object {
        public signal void output (string text);
        public abstract async Assessment inspect (Cancellable? cancellable) throws Error;
        public abstract async void apply (Cancellable? cancellable) throws Error;

        protected async string run_process (string[] argv, Cancellable? cancellable, bool require_success = true) throws Error {
            var process = new Subprocess.newv (argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            string standard_output = "";
            string standard_error = "";
            Error? stream_error = null;
            uint remaining = 2;
            bool waiting = false;
            capture_process_output.begin (process.get_stdout_pipe (), cancellable, (object, result) => {
                try {
                    standard_output = capture_process_output.end (result);
                } catch (Error error) {
                    stream_error = error;
                    process.force_exit ();
                }
                remaining--;
                if (waiting && remaining == 0)
                    run_process.callback ();
            });
            capture_process_output.begin (process.get_stderr_pipe (), cancellable, (object, result) => {
                try {
                    standard_error = capture_process_output.end (result);
                } catch (Error error) {
                    stream_error = error;
                    process.force_exit ();
                }
                remaining--;
                if (waiting && remaining == 0)
                    run_process.callback ();
            });
            if (remaining > 0) {
                waiting = true;
                yield;
            }
            yield process.wait_async (null);
            if (stream_error != null)
                throw stream_error;
            if (require_success && !process.get_successful ()) {
                var diagnostic = standard_error.strip () != "" ? standard_error.strip () :
                    standard_output.strip () != "" ? standard_output.strip () : "No diagnostic output";
                throw new IOError.FAILED ("%s failed: %s", argv[0], diagnostic);
            }
            return standard_output;
        }

        private async string capture_process_output (InputStream stream, Cancellable? cancellable) throws Error {
            var captured = new StringBuilder ();
            var pending = new StringBuilder ();
            while (true) {
                var bytes = yield stream.read_bytes_async (8192, Priority.DEFAULT, cancellable);
                if (bytes.get_size () == 0)
                    break;
                captured.append_len ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
                if (captured.len > 65536)
                    captured.erase (0, (ssize_t) captured.len - 65536);
                pending.append_len ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
                int newline;
                while ((newline = pending.str.index_of_char ('\n')) >= 0) {
                    var line = pending.str.substring (0, newline).make_valid ().chomp ();
                    if (line != "")
                        output (line);
                    pending.erase (0, newline + 1);
                }
                if (pending.len >= 8192) {
                    output (pending.str.make_valid ((ssize_t) pending.len));
                    pending.truncate (0);
                }
            }
            if (pending.len > 0)
                output (pending.str.make_valid ((ssize_t) pending.len).chomp ());
            return captured.str.make_valid ((ssize_t) captured.len);
        }
    }

    public class Option : Object {
        public string id { get; private set; }
        public string title { get; private set; }
        public string description { get; private set; }
        public string category { get; private set; }
        public string scope { get; private set; }
        public string risk { get; private set; }
        public string current { get; private set; default = "Checking availability…"; }
        public string desired { get; private set; }
        public string details { get; private set; }
        public bool requires_admin { get; private set; }
        public string[] dependencies { get; private set; }
        public bool selected { get; set; default = false; }
        public OptionState state { get; private set; default = OptionState.UNAVAILABLE; }
        public bool blocked_by_dependencies { get; private set; default = false; }
        public signal void output (string text);

        private Operation operation;
        private string explanation;

        public Option (Json.Object definition) throws Error {
            id = definition.get_string_member ("id");
            title = definition.get_string_member ("title");
            description = definition.get_string_member ("description");
            category = definition.get_string_member ("category");
            scope = definition.get_string_member ("scope");
            risk = definition.get_string_member ("risk");
            desired = definition.get_string_member ("desired");
            explanation = definition.get_string_member ("details");
            details = explanation;
            requires_admin = definition.get_boolean_member ("requires_admin");
            string[] requirements = {};
            foreach (var item in definition.get_array_member ("dependencies").get_elements ())
                requirements += item.get_string ();
            dependencies = requirements;

            var specification = definition.get_object_member ("operation");
            switch (specification.get_string_member ("kind")) {
                case "settings":
                    operation = new SettingsOperation (specification);
                    break;
                case "configuration":
                    operation = new ConfigurationOperation (id, specification);
                    break;
                case "apt":
                case "flatpak":
                case "system":
                    operation = new PackageOperation (id, specification);
                    break;
                case "upstream":
                    operation = new UpstreamOperation (id, specification);
                    break;
                default:
                    throw new IOError.INVALID_DATA ("Unknown operation for %s", id);
            }
            Signal.connect_object (operation, "output", (Callback) relay_output, this, ConnectFlags.SWAPPED);
        }

        private static void relay_output (Option option, string text) {
            option.output (text);
        }

        public async void detect (Cancellable? cancellable = null) throws Error {
            Assessment observed;
            try {
                observed = yield operation.inspect (cancellable);
            } catch (IOError.CANCELLED error) {
                throw error;
            } catch (Error error) {
                observed = new Assessment (OptionState.UNAVAILABLE, error.message);
            }
            state = observed.state;
            current = observed.current;
            details = explanation + (observed.details == "" ? "" : "\n\n" + observed.details);
            blocked_by_dependencies = observed.dependency_blocked && dependencies.length > 0;
            if (state == OptionState.UNAVAILABLE && blocked_by_dependencies)
                state = OptionState.PARTIAL;
            if (state == OptionState.MATCHING)
                selected = false;
        }

        public async void apply (Cancellable? cancellable = null) throws Error {
            output ("Checking " + title);
            yield detect (cancellable);
            if (state == OptionState.UNAVAILABLE)
                throw new IOError.NOT_SUPPORTED ("%s: %s", title, current);
            if (state == OptionState.MATCHING) {
                output ("Already matches: " + title);
                return;
            }
            output ("Applying " + title);
            yield operation.apply (cancellable);
            output ("Verifying " + title);
            yield detect (cancellable);
            if (state != OptionState.MATCHING)
                throw new IOError.FAILED ("%s did not reach its desired state: %s", title, current);
            output ("Applied and verified: " + title);
        }
    }
}
