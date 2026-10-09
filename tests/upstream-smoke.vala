using MiuUtil;

int main (string[] arguments) {
    if (arguments.length < 2) {
        stderr.printf ("Usage: upstream-smoke UPSTREAM_OR_OPTION_ID...\nRun only in a disposable account or container.\n");
        return 2;
    }
    var loop = new MainLoop ();
    int result = 0;
    run_installations.begin (arguments, (object, response) => {
        try { run_installations.end (response); }
        catch (Error error) { stderr.printf ("%s\n", error.message); result = 1; }
        loop.quit ();
    });
    loop.run ();
    return result;
}

private async void run_installations (string[] arguments) throws Error {
    var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
    var parser = new Json.Parser ();
    parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
    var definitions = parser.get_root ().get_object ().get_array_member ("options");
    for (int i = 1; i < arguments.length; i++) {
        Json.Object? definition = null;
        foreach (var node in definitions.get_elements ()) {
            var candidate = node.get_object ();
            var specification = candidate.get_object_member ("operation");
            if (specification.get_string_member ("kind") != "upstream")
                continue;
            if (candidate.get_string_member ("id") == arguments[i]) {
                definition = candidate;
                break;
            }
            if (specification.get_string_member ("upstream") == arguments[i]) {
                if (definition != null)
                    throw new IOError.INVALID_ARGUMENT ("%s has several catalogue options; provide an option ID.", arguments[i]);
                definition = candidate;
            }
        }
        if (definition == null)
            throw new IOError.INVALID_ARGUMENT ("No upstream catalogue option matches %s.", arguments[i]);
        var operation = new UpstreamOperation (definition.get_string_member ("id"), definition.get_object_member ("operation"));
        operation.output.connect ((text) => stdout.printf ("%s\n", text));
        var before = yield operation.inspect (null);
        stdout.printf ("%s before: %s\n", arguments[i], before.current);
        if (before.state != OptionState.MATCHING)
            yield operation.apply (null);
        var after = yield operation.inspect (null);
        if (after.state != OptionState.MATCHING)
            throw new IOError.FAILED ("%s verification: %s", arguments[i], after.current);
        stdout.printf ("%s verified: %s\n", arguments[i], after.current);
    }
}
