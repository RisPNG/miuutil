namespace MiuUtil {
    public delegate string DebianPackageQuery (string[] arguments, bool report, bool require_success) throws Error;

    public class DebianPackages : Object {
        public string[] requested { get; private set; }
        public string[] supported { get; private set; }
        public string[] omitted { get; private set; }
        public string[] missing { get; private set; }
        public string[] requested_removals { get; private set; }
        public string[] installed_removals { get; private set; }
        public uint installed_count { get; private set; }
        public string state { get; private set; }
        public string current { get; private set; }
        public string details { get; private set; }

        public DebianPackages (Json.Object specification, DebianPackageQuery query) throws Error {
            string[] requested_names = {};
            string[] supported_names = {};
            string[] omitted_names = {};
            string[] missing_names = {};
            string[] removal_names = {};
            string[] installed_removal_names = {};
            string[] command = { "/usr/bin/dpkg-query", "--show", "--showformat=${binary:Package}\t${db:Status-Status}\n" };
            foreach (var member in new string[] { "packages", "remove_packages" }) {
                if (!specification.has_member (member))
                    continue;
                foreach (var node in specification.get_array_member (member).get_elements ()) {
                    var name = node.get_string ();
                    if (!Regex.match_simple ("^[a-z0-9][a-z0-9+.-]*$", name))
                        throw new IOError.INVALID_DATA ("Invalid Debian package name in the catalogue: %s", name);
                    if (member == "packages")
                        requested_names += name;
                    else
                        removal_names += name;
                    command += name;
                }
            }
            foreach (var name in removal_names) {
                if (name in requested_names)
                    throw new IOError.INVALID_DATA ("Debian package is both required and excluded in the catalogue: %s", name);
            }
            var installed = new HashTable<string, bool> (str_hash, str_equal);
            if (requested_names.length + removal_names.length > 0) {
                foreach (var line in query (command, false, false).split ("\n")) {
                    var columns = line.split ("\t");
                    if (columns.length != 2 || columns[1] != "installed")
                        continue;
                    var name = columns[0].split (":")[0];
                    installed.insert (name, true);
                    if (name in removal_names && !(columns[0] in installed_removal_names))
                        installed_removal_names += columns[0];
                }
            }
            string[] candidates_needed = {};
            foreach (var name in requested_names) {
                if (!installed.contains (name))
                    candidates_needed += name;
            }
            var candidates = new HashTable<string, bool> (str_hash, str_equal);
            for (int offset = 0; offset < candidates_needed.length; offset += 32) {
                command = new string[] { "/usr/bin/env", "LC_ALL=C", "/usr/bin/apt-cache", "policy" };
                for (int index = offset; index < int.min (offset + 32, candidates_needed.length); index++)
                    command += candidates_needed[index];
                string package = "";
                foreach (var line in query (command, false, false).split ("\n")) {
                    if (line.has_suffix (":") && !line.has_prefix (" "))
                        package = line.substring (0, line.length - 1).split (":")[0];
                    else if (line.strip ().has_prefix ("Candidate:") && line.strip ().substring ("Candidate:".length).strip () != "(none)")
                        candidates.insert (package, true);
                }
            }
            foreach (var name in requested_names) {
                if (installed.contains (name)) {
                    supported_names += name;
                    installed_count++;
                } else if (candidates.contains (name)) {
                    supported_names += name;
                    missing_names += name;
                } else
                    omitted_names += name;
            }
            requested = requested_names;
            supported = supported_names;
            omitted = omitted_names;
            missing = missing_names;
            requested_removals = removal_names;
            installed_removals = installed_removal_names;
            if (installed_removal_names.length > 0) {
                command = new string[] { "/usr/bin/apt-get", "--simulate", "--yes", "--no-auto-remove", "remove" };
                foreach (var name in installed_removal_names)
                    command += name;
                var planned_removals = new bool[installed_removal_names.length];
                foreach (var line in query (command, false, true).split ("\n")) {
                    if (line.has_prefix ("Inst ") || line.has_prefix ("Conf "))
                        throw new IOError.NOT_SUPPORTED ("Removing conflicting packages would install or configure another package: %s", line);
                    if (!line.has_prefix ("Remv "))
                        continue;
                    var name = line.substring (5).split (" ")[0];
                    int match = -1;
                    for (int index = 0; index < installed_removal_names.length; index++) {
                        if (!planned_removals[index] && installed_removal_names[index] == name) {
                            match = index;
                            break;
                        }
                    }
                    if (match < 0 && !name.contains (":")) {
                        for (int index = 0; index < installed_removal_names.length; index++) {
                            if (!planned_removals[index] && installed_removal_names[index].split (":")[0] == name) {
                                match = index;
                                break;
                            }
                        }
                    }
                    if (match < 0)
                        throw new IOError.NOT_SUPPORTED ("Removing conflicting packages would also remove another package: %s", name);
                    planned_removals[match] = true;
                }
                foreach (var planned in planned_removals) {
                    if (!planned)
                        throw new IOError.NOT_SUPPORTED ("APT did not confirm the requested conflicting package removal");
                }
            }
            bool available_only = specification.has_member ("available_only") && specification.get_boolean_member ("available_only");
            if ((!available_only && omitted_names.length > 0) || (supported_names.length == 0 && removal_names.length == 0)) {
                state = "unavailable";
                current = "Required packages are not provided by the configured Debian repositories.";
            } else {
                uint absent_count = 0;
                foreach (var name in removal_names) {
                    if (!installed.contains (name))
                        absent_count++;
                }
                state = missing_names.length + installed_removal_names.length == 0 ? "matching" :
                    installed_count + absent_count == 0 ? "different" : "partial";
                current = supported_names.length == 0 ? "" : "%u of %u supported packages installed".printf (installed_count, supported_names.length);
                if (removal_names.length > 0)
                    current += (current == "" ? "" : "; ") + "%u of %u conflicting packages absent".printf (absent_count, removal_names.length);
                if (omitted_names.length > 0)
                    current += "; %u unavailable in these repositories".printf (omitted_names.length);
            }
            details = missing_names.length == 0 ? "" : "Packages to install: " + string.joinv (", ", missing_names);
            if (installed_removal_names.length > 0)
                details += (details == "" ? "" : "\n\n") + "Packages to remove: " + string.joinv (", ", installed_removal_names);
            if (omitted_names.length > 0)
                details += (details == "" ? "" : "\n\n") + "Not provided by the configured repositories: " + string.joinv (", ", omitted_names);
        }
    }
}
