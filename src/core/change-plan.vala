namespace MiuUtil {
    public errordomain SetupError {
        INVALID_PLAN,
        BUSY
    }

    public class ChangePlan : Object {
        public ListStore options { get; private set; }
        public string summary { get; private set; }
        public bool requires_admin { get; private set; }

        public ChangePlan (Catalogue catalogue) throws Error {
            options = new ListStore (typeof (Option));
            var index = new HashTable<string, Option> (str_hash, str_equal);
            var included = new HashTable<string, bool> (str_hash, str_equal);
            var visiting = new HashTable<string, bool> (str_hash, str_equal);
            uint selected_count = 0;
            for (uint i = 0; i < catalogue.options.get_n_items (); i++) {
                var option = (Option) catalogue.options.get_item (i);
                index.insert (option.id, option);
            }
            for (uint i = 0; i < catalogue.options.get_n_items (); i++) {
                var option = (Option) catalogue.options.get_item (i);
                if (option.selected) {
                    selected_count++;
                    include_dependencies (option, index, included, visiting);
                }
            }
            if (selected_count == 0) {
                throw new SetupError.INVALID_PLAN ("Select at least one change before reviewing.");
            }
            if (options.get_n_items () == 0) {
                throw new SetupError.INVALID_PLAN ("The selected options already match their desired state.");
            }
            summary = ngettext ("%u selected option", "%u selected options", selected_count).printf (selected_count) + "; " +
                ngettext ("%u change including prerequisites.", "%u changes including prerequisites.", options.get_n_items ()).printf (options.get_n_items ());
        }

        private void include_dependencies (Option option,
                                           HashTable<string, Option> index,
                                           HashTable<string, bool> included,
                                           HashTable<string, bool> visiting) throws Error {
            if (included.contains (option.id)) {
                return;
            }
            if (visiting.contains (option.id)) {
                throw new SetupError.INVALID_PLAN ("The catalogue contains a dependency cycle at %s.", option.title);
            }
            visiting.insert (option.id, true);
            foreach (var dependency in option.dependencies) {
                var prerequisite = index.lookup (dependency);
                if (prerequisite == null) {
                    throw new SetupError.INVALID_PLAN ("%s requires the missing option %s.", option.title, dependency);
                }
                include_dependencies (prerequisite, index, included, visiting);
            }
            visiting.remove (option.id);
            if (option.state == OptionState.UNAVAILABLE && !option.blocked_by_dependencies) {
                throw new SetupError.INVALID_PLAN ("%s is unavailable: %s", option.title, option.current);
            }
            included.insert (option.id, true);
            if (option.state != OptionState.MATCHING) {
                options.append (option);
                requires_admin = requires_admin || option.requires_admin;
            }
        }
    }
}
