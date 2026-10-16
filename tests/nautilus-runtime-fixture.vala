using MiuUtil;

async int main (string[] arguments) {
    try {
        if (arguments.length != 2 || !(arguments[1] in new string[] { "inspect", "apply" }))
            throw new IOError.INVALID_ARGUMENT ("Expected inspect or apply.");
        var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
        var parser = new Json.Parser ();
        parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
        foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
            var definition = node.get_object ();
            if (definition.get_string_member ("id") != "files-nautilus-actions")
                continue;
            var operation = new ConfigurationOperation ("files-nautilus-actions", definition.get_object_member ("operation"));
            if (arguments[1] == "apply")
                yield operation.apply (null);
            var assessment = yield operation.inspect (null);
            var report = new Json.Object ();
            report.set_string_member ("state", assessment.state.to_string ());
            report.set_string_member ("current", assessment.current);
            report.set_string_member ("libexec", Config.LIBEXEC_DIR);
            var result = new Json.Node (Json.NodeType.OBJECT);
            result.set_object (report);
            stdout.printf ("%s\n", Json.to_string (result, false));
            return 0;
        }
        throw new IOError.NOT_FOUND ("The Nautilus actions option is missing from the catalogue.");
    } catch (Error error) {
        stderr.printf ("%s\n", error.message);
        return 1;
    }
}
