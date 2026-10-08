using MiuUtil;

int main (string[] arguments) {
    if (arguments.length < 2) {
        stderr.printf ("Usage: upstream-smoke UPSTREAM...\nRun only in a disposable account or container.\n");
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
    for (int i = 1; i < arguments.length; i++) {
        var specification = new Json.Object ();
        specification.set_string_member ("kind", "upstream");
        specification.set_string_member ("upstream", arguments[i]);
        var operation = new UpstreamOperation ("smoke-" + arguments[i], specification);
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
