namespace MiuUtil {
    public class PackageOperation : Operation {
        private string identity;
        private Json.Object specification;

        public PackageOperation (string identity, Json.Object specification) {
            this.identity = identity;
            this.specification = specification;
        }

        public override async Assessment inspect (Cancellable? cancellable) throws Error {
            var kind = specification.get_string_member ("kind");
            if (kind == "apt" || kind == "system") {
                if (!FileUtils.test (Config.HELPER_PATH, FileTest.IS_EXECUTABLE))
                    return new Assessment (OptionState.UNAVAILABLE, "Install MiuUtil's administrator helper to manage this system option.");
                string[] inspection = identity == "system-root-mc-skin" || identity == "system-passwordless-admin" ?
                    new string[] { "pkexec", "--disable-internal-agent", Config.HELPER_PATH, "--inspect", identity } :
                    new string[] { Config.HELPER_PATH, "--inspect", identity };
                var report = yield run_process (inspection, cancellable);
                var parser = new Json.Parser ();
                parser.load_from_data (report);
                var result = parser.get_root ().get_object ();
                OptionState state;
                switch (result.get_string_member ("state")) {
                    case "matching": state = OptionState.MATCHING; break;
                    case "different": state = OptionState.DIFFERENT; break;
                    case "partial": state = OptionState.PARTIAL; break;
                    default: state = OptionState.UNAVAILABLE; break;
                }
                return new Assessment (state, result.get_string_member ("current"), result.get_string_member ("details"));
            }
            if (Environment.find_program_in_path ("flatpak") == null)
                return new Assessment (OptionState.UNAVAILABLE, "Install Flatpak support before selecting this application.", "", true);
            var installed = yield run_process ({ "flatpak", "list", "--app", "--columns=application" }, cancellable);
            var application = specification.get_string_member ("application");
            if (!(application in installed.strip ().split ("\n"))) {
                var remotes = yield run_process ({ "flatpak", "remotes", "--user", "--columns=name,url" }, cancellable);
                foreach (var line in remotes.split ("\n")) {
                    var columns = line.split ("\t");
                    if (columns.length == 2 && columns[0].strip () == "flathub" && columns[1].strip () != "https://dl.flathub.org/repo/")
                        return new Assessment (OptionState.UNAVAILABLE, "Your user remote named flathub does not point to the official Flathub repository.");
                }
            }
            return new Assessment (application in installed.strip ().split ("\n") ? OptionState.MATCHING : OptionState.DIFFERENT,
                application in installed.strip ().split ("\n") ? "Installed" : "Not installed",
                "Installs from Flathub for your account. Existing system installations also count as installed.");
        }

        public override async void apply (Cancellable? cancellable) throws Error {
            var kind = specification.get_string_member ("kind");
            if (kind == "apt" || kind == "system") {
                if (Environment.find_program_in_path ("pkexec") == null)
                    throw new IOError.NOT_SUPPORTED ("polkit's pkexec command is not available.");
                yield run_process ({ "pkexec", Config.HELPER_PATH, "--apply", identity }, null);
                return;
            }
            yield run_process ({ "flatpak", "remote-add", "--user", "--if-not-exists", "flathub", "https://dl.flathub.org/repo/flathub.flatpakrepo" }, cancellable);
            yield run_process ({ "flatpak", "install", "--user", "--noninteractive", "--assumeyes", "flathub", specification.get_string_member ("application") }, null);
        }
    }
}
