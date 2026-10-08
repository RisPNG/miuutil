namespace MiuUtil {
    public delegate string DebianPackageQuery (string[] arguments, bool report, bool require_success) throws Error;

    public class DebianPackages : Object {
        public string[] requested { get; private set; }
        public string[] supported { get; private set; }
        public string[] omitted { get; private set; }
        public string[] missing { get; private set; }
        public uint installed_count { get; private set; }
        public string state { get; private set; }
        public string current { get; private set; }
        public string details { get; private set; }

        public DebianPackages (Json.Object specification, DebianPackageQuery query) throws Error {
            string[] requested_names = {};
            string[] supported_names = {};
            string[] omitted_names = {};
            string[] missing_names = {};
            string[] command = { "/usr/bin/dpkg-query", "--show", "--showformat=${binary:Package}\t${db:Status-Status}\n" };
            foreach (var node in specification.get_array_member ("packages").get_elements ()) {
                var name = node.get_string ();
                if (!Regex.match_simple ("^[a-z0-9][a-z0-9+.-]*$", name))
                    throw new IOError.INVALID_DATA ("Invalid Debian package name in the catalogue: %s", name);
                requested_names += name;
                command += name;
            }
            var installed = new HashTable<string, bool> (str_hash, str_equal);
            foreach (var line in query (command, false, false).split ("\n")) {
                var columns = line.split ("\t");
                if (columns.length == 2 && columns[1] == "installed")
                    installed.insert (columns[0].split (":")[0], true);
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
            bool available_only = specification.has_member ("available_only") && specification.get_boolean_member ("available_only");
            if ((!available_only && omitted_names.length > 0) || supported_names.length == 0) {
                state = "unavailable";
                current = "Required packages are not provided by the configured Debian repositories.";
            } else {
                state = missing_names.length == 0 ? "matching" : installed_count == 0 ? "different" : "partial";
                current = "%u of %u supported packages installed".printf (installed_count, supported_names.length);
                if (omitted_names.length > 0)
                    current += "; %u unavailable in these repositories".printf (omitted_names.length);
            }
            details = missing_names.length == 0 ? "" : "Packages to install: " + string.joinv (", ", missing_names);
            if (omitted_names.length > 0)
                details += (details == "" ? "" : "\n\n") + "Not provided by the configured repositories: " + string.joinv (", ", omitted_names);
        }
    }
}
