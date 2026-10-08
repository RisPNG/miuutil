int main (string[] arguments) {
    if (arguments.length != 3) {
        stderr.printf ("Usage: miuutil-helper --apply|--inspect|--plan OPTION_ID\n");
        return 2;
    }
    try {
        bool read_only = arguments[1] != "--apply";
        if (arguments[1] != "--apply" && arguments[1] != "--inspect" && arguments[1] != "--plan")
            throw new IOError.INVALID_ARGUMENT ("Only --apply, --inspect and --plan are supported");
        var change = new MiuUtil.PrivilegedChange (arguments[2]);
        if (read_only) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (arguments[1] == "--plan" ? change.plan () : change.inspect ());
            stdout.printf ("%s\n", Json.to_string (node, false));
        } else {
            change.apply ();
        }
        return 0;
    } catch (Error error) {
        if (arguments[1] == "--inspect" && Posix.geteuid () == 0)
            stderr.printf ("The predefined system settings could not be inspected.\n");
        else
            stderr.printf ("%s\n", error.message);
        return 1;
    }
}
