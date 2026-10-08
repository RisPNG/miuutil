namespace MiuUtil {
    public class Catalogue : Object {
        public ListStore options { get; private set; }

        public Catalogue () throws Error {
            options = new ListStore (typeof (Option));
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            var root = parser.get_root ().get_object ();
            var identities = new HashTable<string, bool> (str_hash, str_equal);
            foreach (var node in root.get_array_member ("options").get_elements ()) {
                var option = new Option (node.get_object ());
                if (identities.contains (option.id))
                    throw new IOError.INVALID_DATA ("Duplicate option: %s", option.id);
                identities.insert (option.id, true);
                options.append (option);
            }
            for (uint index = 0; index < options.get_n_items (); index++) {
                var option = (Option) options.get_item (index);
                foreach (var dependency in option.dependencies) {
                    if (!identities.contains (dependency))
                        throw new IOError.INVALID_DATA ("%s depends on unknown option %s", option.id, dependency);
                }
            }
        }

        public async void detect_all (Cancellable? cancellable = null) throws Error {
            for (uint index = 0; index < options.get_n_items (); index++) {
                if (cancellable != null)
                    cancellable.set_error_if_cancelled ();
                yield ((Option) options.get_item (index)).detect (cancellable);
                Idle.add (() => {
                    detect_all.callback ();
                    return Source.REMOVE;
                });
                yield;
            }
        }
    }
}
