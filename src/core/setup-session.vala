namespace MiuUtil {
    public class SetupSession : Object {
        public bool running { get; private set; }
        public bool stop_requested { get; set; }

        public signal void progress (Option option, string text);
        public signal void completed (Option option, bool success, string text);

        public async void execute (ChangePlan plan) throws Error {
            if (running) {
                throw new SetupError.BUSY ("A setup session is already running.");
            }
            running = true;
            stop_requested = false;
            try {
                for (uint i = 0; i < plan.options.get_n_items (); i++) {
                    if (stop_requested) {
                        break;
                    }
                    var option = (Option) plan.options.get_item (i);
                    ulong output_handler = option.output.connect ((text) => progress (option, text));
                    try {
                        progress (option, "Applying and verifying the reviewed change...");
                        yield option.apply ();
                        option.selected = false;
                        completed (option, true, "Applied and verified.");
                    } catch (Error error) {
                        completed (option, false, error.message);
                        throw error;
                    } finally {
                        option.disconnect (output_handler);
                    }
                }
            } finally {
                running = false;
            }
        }
    }
}
