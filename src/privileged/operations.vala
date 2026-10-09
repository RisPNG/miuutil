namespace MiuUtil {
    public class PrivilegedChange : Object {
        private const string APT_SNAPSHOT_HOOK = "DPkg::Pre-Install-Pkgs { \"%s\"; };\nDPkg::Tools::Options::%s::Version \"2\";\n";
        private const string RECOVERY_START_UNIT = "[Unit]\nDescription=Initialise Timeshift scheduling\nConditionPathExists=/etc/timeshift/timeshift.json\nConditionKernelCommandLine=!boot=live\nConditionKernelCommandLine=!boot=casper\nBefore=cron.service\n\n[Service]\nType=oneshot\nExecStart=%s\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n";
        public string id { get; private set; }
        public Json.Object definition { get; private set; }
        public Json.Object specification { get; private set; }

        public PrivilegedChange (string id) throws Error {
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
                var candidate = node.get_object ();
                if (candidate.get_string_member ("id") != id)
                    continue;
                var operation = candidate.get_object_member ("operation");
                var kind = operation.get_string_member ("kind");
                if (kind != "apt" && kind != "system" && !(kind == "upstream" && id == "development-homebrew" && operation.get_string_member ("upstream") == "homebrew"))
                    throw new IOError.PERMISSION_DENIED ("%s is a user operation, not an administrator operation", id);
                if (kind == "system") {
                    switch (id) {
                        case "system-zram":
                        case "system-timesync":
                        case "system-monitor-controls":
                        case "system-passwordless-admin":
                        case "recovery-timeshift":
                        case "recovery-grub-snapshots":
                        case "browsers-vivaldi-install":
                        case "development-vscode":
                        case "development-pacstall":
                        case "applications-harmonoid":
                        case "system-default-browser":
                        case "system-default-terminal":
                        case "system-default-editor":
                        case "system-root-mc-skin":
                            break;
                        default:
                            throw new IOError.NOT_SUPPORTED ("Unknown administrator operation: %s", id);
                    }
                }
                this.id = id;
                definition = candidate;
                specification = operation;
                return;
            }
            throw new IOError.NOT_FOUND ("Unknown setup option: %s", id);
        }

        public Json.Object plan () throws Error {
            var plan = new Json.Object ();
            plan.set_string_member ("id", id);
            plan.set_string_member ("title", definition.get_string_member ("title"));
            var packages = new Json.Array ();
            var files = new Json.Array ();
            var services = new Json.Array ();
            if (specification.get_string_member ("kind") == "apt") {
                var selection = new DebianPackages (specification, execute);
                var requested_packages = new Json.Array ();
                foreach (var name in selection.requested)
                    requested_packages.add_string_element (name);
                foreach (var name in selection.supported)
                    packages.add_string_element (name);
                var install_packages = new Json.Array ();
                foreach (var name in selection.missing)
                    install_packages.add_string_element (name);
                var omitted_packages = new Json.Array ();
                foreach (var name in selection.omitted)
                    omitted_packages.add_string_element (name);
                plan.set_array_member ("requested_packages", requested_packages);
                plan.set_array_member ("install_packages", install_packages);
                plan.set_array_member ("omitted_packages", omitted_packages);
                plan.set_string_member ("state", selection.state);
                plan.set_string_member ("current", selection.current);
                plan.set_string_member ("details", selection.details);
            } else {
                switch (id) {
                    case "system-zram":
                        packages.add_string_element ("systemd-zram-generator");
                        files.add_string_element ("/etc/systemd/zram-generator.conf.d/50-miuutil.conf");
                        services.add_string_element ("Persist zram configuration; restart if systemd does not activate it during reload");
                        break;
                    case "system-timesync":
                        packages.add_string_element ("systemd-timesyncd");
                        services.add_string_element ("Enable and start systemd-timesyncd.service");
                        break;
                    case "system-monitor-controls":
                        packages.add_string_element ("ddcutil");
                        packages.add_string_element ("i2c-tools");
                        files.add_string_element ("/etc/modules-load.d/miuutil-i2c.conf");
                        services.add_string_element ("Load i2c-dev and add the calling account to i2c; sign out afterwards");
                        break;
                    case "system-passwordless-admin":
                        packages.add_string_element ("sudo");
                        files.add_string_element ("/etc/sudoers.d/99-miuutil-admin");
                        files.add_string_element ("/etc/polkit-1/rules.d/00-miuutil-admin.rules");
                        break;
                    case "recovery-timeshift":
                        packages.add_string_element ("timeshift");
                        packages.add_string_element ("btrfs-progs");
                        packages.add_string_element ("cron");
                        files.add_string_element ("/etc/timeshift/timeshift.json");
                        files.add_string_element ("/etc/apt/apt.conf.d/80-miuutil-snapshots");
                        files.add_string_element ("/etc/systemd/system/miuutil-recovery-start.service");
                        services.add_string_element ("Enable Timeshift boot scheduling; retain existing GRUB recovery integration");
                        break;
                    case "recovery-grub-snapshots":
                        packages.add_string_element ("overlayroot");
                        packages.add_string_element ("inotify-tools");
                        packages.add_string_element ("initramfs-tools");
                        packages.add_string_element ("grub2-common");
                        files.add_string_element ("/etc/grub.d/41_snapshots-btrfs");
                        files.add_string_element ("/etc/default/grub-btrfs/config");
                        files.add_string_element ("/etc/default/grub.d/99-miuutil-snapshots.cfg");
                        files.add_string_element ("/etc/systemd/system/miuutil-grub-btrfsd.service");
                        services.add_string_element ("Rebuild initramfs and GRUB; keep Timeshift snapshot entries updated");
                        break;
                    case "browsers-vivaldi-install":
                        packages.add_string_element ("vivaldi-stable");
                        files.add_string_element ("/etc/apt/keyrings/miuutil-vivaldi.asc");
                        files.add_string_element ("/etc/apt/sources.list.d/vivaldi.sources");
                        break;
                    case "development-vscode":
                        packages.add_string_element ("code");
                        files.add_string_element ("/etc/apt/keyrings/miuutil-microsoft.asc");
                        files.add_string_element ("/etc/apt/sources.list.d/vscode.sources");
                        break;
                    case "development-pacstall":
                    case "applications-harmonoid":
                        packages.add_string_element ("curl");
                        packages.add_string_element ("ca-certificates");
                        if (id == "applications-harmonoid") {
                            packages.add_string_element ("mpv");
                            packages.add_string_element ("libmpv-dev");
                            packages.add_string_element ("xdg-desktop-portal");
                            packages.add_string_element ("xdg-desktop-portal-gtk");
                            services.add_string_element ("Install verified official Harmonoid 0.3.32 release package");
                        } else
                            services.add_string_element ("Install verified official Pacstall 6.4.2 release package");
                        break;
                    case "development-homebrew":
                        packages.add_string_element ("build-essential");
                        packages.add_string_element ("procps");
                        packages.add_string_element ("curl");
                        packages.add_string_element ("git");
                        packages.add_string_element ("file");
                        packages.add_string_element ("ca-certificates");
                        files.add_string_element ("/home/linuxbrew/.linuxbrew");
                        services.add_string_element ("Prepare the standard prefix for the calling account; install Homebrew and GCC in that user's session");
                        break;
                    case "system-default-terminal":
                        packages.add_string_element ("gnome-console");
                        packages.add_string_element ("xdg-terminal-exec");
                        services.add_string_element ("Set x-terminal-emulator to the Console tab preference through xdg-terminal-exec and update-alternatives");
                        break;
                    case "system-default-browser":
                        packages.add_string_element ("vivaldi-stable");
                        services.add_string_element ("Set x-www-browser and gnome-www-browser to Vivaldi through update-alternatives");
                        break;
                    case "system-default-editor":
                        packages.add_string_element ("mc");
                        services.add_string_element ("Set the native terminal editor alternative to mcedit");
                        break;
                    case "system-root-mc-skin":
                        packages.add_string_element ("mc");
                        files.add_string_element ("/root/.config/mc/ini");
                        break;
                }
            }
            plan.set_array_member ("packages", packages);
            plan.set_array_member ("files", files);
            plan.set_array_member ("services", services);
            plan.set_boolean_member ("requires_admin", true);
            return plan;
        }

        public Json.Object inspect () throws Error {
            var result = new Json.Object ();
            result.set_string_member ("state", "different");
            result.set_string_member ("current", "Not configured");
            result.set_string_member ("details", "");
            if (!is_debian ()) {
                result.set_string_member ("state", "unavailable");
                result.set_string_member ("current", "This administrator operation requires Debian or a Debian-based distribution");
                return result;
            }
            if (id == "system-zram" || id == "system-monitor-controls") {
                var module = id == "system-zram" ? "zram" : "i2c-dev";
                if (!kernel_supports (module)) {
                    result.set_string_member ("state", "unavailable");
                    result.set_string_member ("current", "The running kernel does not provide %s support".printf (module));
                    return result;
                }
            }
            if (specification.get_string_member ("kind") == "apt") {
                var selection = new DebianPackages (specification, execute);
                result.set_string_member ("state", selection.state);
                result.set_string_member ("current", selection.current);
                result.set_string_member ("details", selection.details);
                return result;
            }
            bool matching = false;
            string[] configuration_paths = {};
            switch (id) {
                case "system-zram":
                    configuration_paths = {"/etc/systemd/zram-generator.conf.d/50-miuutil.conf", "/usr/lib/systemd/zram-generator.conf.d/50-miubomz.conf"};
                    break;
                case "system-monitor-controls":
                    configuration_paths = {"/etc/modules-load.d/miuutil-i2c.conf", "/etc/modules-load.d/miubomz-i2c.conf"};
                    break;
                case "system-passwordless-admin":
                    if (Posix.geteuid () != 0)
                        throw new IOError.PERMISSION_DENIED ("Use the read-only authorised inspector for administrator rules");
                    configuration_paths = {"/etc/polkit-1/rules.d/00-miuutil-admin.rules", "/etc/polkit-1/rules.d/00-miubomz-admin.rules",
                                           "/etc/sudoers.d/99-miuutil-admin", "/etc/sudoers.d/99-miubomz-admin"};
                    break;
                case "recovery-timeshift":
                    configuration_paths = {"/etc/apt/apt.conf.d/80-miuutil-snapshots", "/etc/apt/apt.conf.d/80-miubomz-snapshots",
                                           "/etc/systemd/system/miuutil-recovery-start.service", "/usr/lib/systemd/system/miubomz-recovery-start.service"};
                    break;
                case "recovery-grub-snapshots":
                    configuration_paths = {"/etc/default/grub-btrfs/config", "/etc/default/grub.d/99-miuutil-snapshots.cfg", "/etc/default/grub.d/99-miubomz-snapshots.cfg"};
                    break;
            }
            var configurations = new HashTable<string, string> (str_hash, str_equal);
            foreach (var path in configuration_paths) {
                string contents = "";
                try {
                    FileUtils.get_contents (path, out contents);
                } catch (FileError error) {
                    if (!(error is FileError.NOENT))
                        throw error;
                    contents = "";
                }
                configurations.insert (path, contents);
            }
            switch (id) {
                case "system-zram":
                    matching = configurations.lookup ("/etc/systemd/zram-generator.conf.d/50-miuutil.conf").contains ("[zram0]") ||
                               configurations.lookup ("/usr/lib/systemd/zram-generator.conf.d/50-miubomz.conf").contains ("[zram0]");
                    var swap = execute ({"/usr/sbin/swapon", "--show", "--noheadings", "--output=NAME"}, false, false).strip ().split ("\n");
                    result.set_string_member ("details", "/dev/zram0" in swap
                        ? "zram is active and configured for future boots. Existing disk swap is preserved."
                        : "Configuration is saved for future boots. Restart if zram remains inactive. Existing disk swap is preserved.");
                    break;
                case "system-timesync":
                    matching = time_synchronisation_ready (execute);
                    break;
                case "system-monitor-controls":
                    matching = configurations.lookup ("/etc/modules-load.d/miuutil-i2c.conf").contains ("i2c-dev") ||
                               configurations.lookup ("/etc/modules-load.d/miubomz-i2c.conf").contains ("i2c-dev");
                    var groups = execute ({"/usr/bin/id", "--groups", "--name", Environment.get_user_name ()}, false, false);
                    matching = matching && (" " + groups.strip () + " ").contains (" i2c ");
                    result.set_string_member ("details", "Sign out after adding the account to i2c. Monitor DDC/CI support is still required.");
                    break;
                case "system-passwordless-admin":
                    matching = (configurations.lookup ("/etc/sudoers.d/99-miuutil-admin").strip () == "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" ||
                                configurations.lookup ("/etc/sudoers.d/99-miubomz-admin").strip () == "%sudo ALL=(ALL:ALL) NOPASSWD: ALL");
                    bool polkit_matches = false;
                    foreach (var path in new string[] {"/etc/polkit-1/rules.d/00-miuutil-admin.rules", "/etc/polkit-1/rules.d/00-miubomz-admin.rules"}) {
                        var rule = configurations.lookup (path);
                        polkit_matches = polkit_matches || (rule.contains ("subject.isInGroup(\"sudo\")") && rule.contains ("subject.local") &&
                            rule.contains ("subject.active") && rule.contains ("return polkit.Result.YES;"));
                    }
                    matching = matching && polkit_matches;
                    result.set_string_member ("details", "Members of sudo in an active local session can obtain administrator access without another password prompt.");
                    break;
                case "recovery-timeshift":
                    string filesystem_uuid;
                    try {
                        filesystem_uuid = recovery_filesystem ();
                    } catch (Error error) {
                        result.set_string_member ("state", "unavailable");
                        result.set_string_member ("current", error.message);
                        return result;
                    }
                    if (FileUtils.test ("/etc/timeshift/timeshift.json", FileTest.EXISTS)) {
                        var parser = new Json.Parser ();
                        parser.load_from_file ("/etc/timeshift/timeshift.json");
                        var settings = parser.get_root ().get_object ();
                        matching = settings.has_member ("btrfs_mode") && settings.get_string_member ("btrfs_mode") == "true" &&
                                   settings.get_string_member ("backup_device_uuid") == filesystem_uuid &&
                                   settings.get_string_member ("include_btrfs_home_for_backup") == "false" &&
                                   settings.get_string_member ("include_btrfs_home_for_restore") == "false" &&
                                   settings.get_string_member ("count_weekly") == "7" && settings.get_string_member ("count_daily") == "8" &&
                                   settings.get_string_member ("count_boot") == "2" &&
                                   settings.get_string_member ("schedule_weekly") == "true" && settings.get_string_member ("schedule_daily") == "true" &&
                                   settings.get_string_member ("schedule_boot") == "true" && settings.get_string_member ("schedule_hourly") == "false" &&
                                   settings.get_string_member ("schedule_monthly") == "false";
                    }
                    var hook = Path.build_filename (Config.LIBEXEC_DIR, "apt-pre-snapshot");
                    var start = Path.build_filename (Config.LIBEXEC_DIR, "recovery-start");
                    bool hook_ready = FileUtils.test (hook, FileTest.IS_EXECUTABLE) &&
                        configurations.lookup ("/etc/apt/apt.conf.d/80-miuutil-snapshots").strip () == APT_SNAPSHOT_HOOK.printf (hook, hook).strip ();
                    bool startup_ready = FileUtils.test (start, FileTest.IS_EXECUTABLE) &&
                        configurations.lookup ("/etc/systemd/system/miuutil-recovery-start.service").strip () == RECOVERY_START_UNIT.printf (start).strip () &&
                        services_ready ({"miuutil-recovery-start.service"}, {}, execute);
                    if (FileUtils.test ("/var/lib/miubomz/installed", FileTest.EXISTS)) {
                        hook = "/usr/lib/miubomz/apt-pre-snapshot";
                        hook_ready = hook_ready || (FileUtils.test (hook, FileTest.IS_EXECUTABLE) &&
                            configurations.lookup ("/etc/apt/apt.conf.d/80-miubomz-snapshots").strip () == APT_SNAPSHOT_HOOK.printf (hook, hook).strip ());
                        var legacy_unit = configurations.lookup ("/usr/lib/systemd/system/miubomz-recovery-start.service");
                        startup_ready = startup_ready || (FileUtils.test ("/usr/lib/miubomz/recovery-start", FileTest.IS_EXECUTABLE) &&
                            Regex.match_simple ("^Type=oneshot$", legacy_unit, RegexCompileFlags.MULTILINE) &&
                            Regex.match_simple ("^ExecStart=/usr/lib/miubomz/recovery-start$", legacy_unit, RegexCompileFlags.MULTILINE) &&
                            services_ready ({"miubomz-recovery-start.service"}, {}, execute));
                    }
                    matching = matching && hook_ready && startup_ready && services_ready ({"cron.service"}, {"cron.service"}, execute);
                    result.set_string_member ("details", FileUtils.test (Path.build_filename (Config.LIBEXEC_DIR, "grub-btrfsd"), FileTest.IS_EXECUTABLE) ||
                        FileUtils.test ("/usr/bin/grub-btrfsd", FileTest.IS_EXECUTABLE)
                        ? "Existing grub-btrfs integration is retained. Home remains outside system restoration."
                        : "Timeshift scheduling and APT snapshots are supported. GRUB snapshot previews can be installed with the separate recovery option.");
                    break;
                case "recovery-grub-snapshots":
                    try {
                        recovery_filesystem ();
                        var boot = execute ({"/usr/bin/findmnt", "--noheadings", "--output", "FSROOT", "--target", "/boot"}, false, true).strip ();
                        if (boot != "/@" || !FileUtils.test ("/boot/grub/grub.cfg", FileTest.EXISTS) ||
                            !FileUtils.test ("/usr/sbin/update-grub", FileTest.IS_EXECUTABLE))
                            throw new IOError.NOT_SUPPORTED ("Snapshot previews require GRUB with /boot inside the Btrfs @ root");
                    } catch (Error error) {
                        result.set_string_member ("state", "unavailable");
                        result.set_string_member ("current", error.message);
                        return result;
                    }
                    matching = FileUtils.test ("/etc/grub.d/41_snapshots-btrfs", FileTest.IS_EXECUTABLE) &&
                               configurations.lookup ("/etc/default/grub-btrfs/config").contains ("overlayroot=tmpfs:recurse=0") &&
                               ((configurations.lookup ("/etc/default/grub.d/99-miuutil-snapshots.cfg").contains ("GRUB_TIMEOUT=5") &&
                                 services_ready ({"miuutil-grub-btrfsd.service"}, {"miuutil-grub-btrfsd.service"}, execute)) ||
                                (FileUtils.test ("/var/lib/miubomz/installed", FileTest.EXISTS) &&
                                 configurations.lookup ("/etc/default/grub.d/99-miubomz-snapshots.cfg").contains ("GRUB_TIMEOUT=5") &&
                                 services_ready ({"grub-btrfsd.service"}, {"grub-btrfsd.service"}, execute)));
                    result.set_string_member ("details", "Root writes in a snapshot preview stay in RAM. Separately mounted home, EFI, logs and caches remain writable; use Timeshift Restore for a permanent rollback.");
                    break;
                case "browsers-vivaldi-install":
                case "development-vscode":
                    var package = id == "development-vscode" ? "code" : "vivaldi-stable";
                    matching = execute ({"/usr/bin/dpkg-query", "--show", "--showformat=${db:Status-Status}", package}, false, false).strip () == "installed";
                    result.set_string_member ("details", "Installs from the vendor's signed APT repository, which remains available for normal updates.");
                    break;
                case "development-pacstall":
                    matching = execute ({"/usr/bin/dpkg-query", "--show", "--showformat=${db:Status-Status}", "pacstall"}, false, false).strip () == "installed" ||
                               FileUtils.test ("/usr/bin/pacstall", FileTest.IS_EXECUTABLE);
                    result.set_string_member ("details", "Installs the verified official Pacstall 6.4.2 release package through APT.");
                    break;
                case "applications-harmonoid":
                    matching = execute ({"/usr/bin/dpkg-query", "--show", "--showformat=${db:Status-Status}", "harmonoid"}, false, false).strip () == "installed";
                    if (!matching && execute ({"/usr/bin/dpkg", "--print-architecture"}, false, true).strip () != "amd64") {
                        result.set_string_member ("state", "unavailable");
                        result.set_string_member ("current", "This verified Harmonoid package supports x86-64 systems.");
                        return result;
                    }
                    result.set_string_member ("details", "Installs the verified official Harmonoid 0.3.32 release package and its dependencies through APT. Existing installations are preserved.");
                    break;
                case "development-homebrew":
                    matching = FileUtils.test ("/home/linuxbrew/.linuxbrew/bin/brew", FileTest.IS_EXECUTABLE);
                    result.set_string_member ("details", "Homebrew and GCC are installed as the signed-in user after the standard prefix is prepared.");
                    break;
                case "system-default-terminal":
                    matching = execute ({"/usr/bin/update-alternatives", "--query", "x-terminal-emulator"}, false, false).contains ("\nValue: /usr/bin/xdg-terminal-exec\n");
                    break;
                case "system-default-browser":
                    matching = true;
                    foreach (var alternative in new string[] { "x-www-browser", "gnome-www-browser" })
                        matching = execute ({"/usr/bin/update-alternatives", "--query", alternative}, false, false).contains ("\nValue: /usr/bin/vivaldi-stable\n") && matching;
                    break;
                case "system-default-editor":
                    matching = execute ({"/usr/bin/update-alternatives", "--query", "editor"}, false, false).contains ("\nValue: /usr/bin/mcedit\n");
                    break;
                case "system-root-mc-skin":
                    if (Posix.geteuid () != 0)
                        throw new IOError.PERMISSION_DENIED ("Use the read-only authorised inspector for root's Midnight Commander preferences");
                    if (FileUtils.test ("/root/.config/mc/ini", FileTest.EXISTS)) {
                        var preferences = new KeyFile ();
                        preferences.load_from_file ("/root/.config/mc/ini", KeyFileFlags.NONE);
                        matching = preferences.has_group ("Midnight-Commander") && preferences.has_key ("Midnight-Commander", "skin") &&
                                   preferences.get_string ("Midnight-Commander", "skin") == "yadt256-defbg";
                    }
                    result.set_string_member ("details", "The inspector returns only whether root's skin matches; it does not expose other root preferences.");
                    break;
            }
            result.set_string_member ("state", matching ? "matching" : "different");
            result.set_string_member ("current", matching ? "Desired system setup is present" : "Desired system setup is not fully configured");
            return result;
        }

        public void apply () throws Error {
            if (Posix.geteuid () != 0)
                throw new IOError.PERMISSION_DENIED ("Administrator authorisation is required");
            if (!is_debian ())
                throw new IOError.NOT_SUPPORTED ("This operation requires Debian or a Debian-based distribution");
            if (!FileUtils.test ("/run/systemd/system", FileTest.IS_DIR))
                throw new IOError.NOT_SUPPORTED ("Administrator operations require an installed systemd system");
            string command_line;
            FileUtils.get_contents ("/proc/cmdline", out command_line);
            if (command_line.contains ("boot=live") || command_line.contains ("boot=casper") || command_line.contains ("overlayroot="))
                throw new IOError.NOT_SUPPORTED ("Boot the installed system before applying administrator operations");
            if (id == "applications-harmonoid") {
                if (execute ({"/usr/bin/dpkg-query", "--show", "--showformat=${db:Status-Status}", "harmonoid"}, false, false).strip () == "installed")
                    return;
                if (execute ({"/usr/bin/dpkg", "--print-architecture"}, false, true).strip () != "amd64")
                    throw new IOError.NOT_SUPPORTED ("This verified Harmonoid package supports x86-64 systems.");
            }
            if (id == "system-zram" || id == "system-monitor-controls") {
                var module = id == "system-zram" ? "zram" : "i2c-dev";
                if (!kernel_supports (module))
                    throw new IOError.NOT_SUPPORTED ("The running kernel does not provide %s support", module);
            }
            string? uuid = null;
            if (id == "recovery-timeshift")
                uuid = recovery_filesystem ();
            if (id == "recovery-grub-snapshots") {
                recovery_filesystem ();
                var boot = execute ({"/usr/bin/findmnt", "--noheadings", "--output", "FSROOT", "--target", "/boot"}, false, true).strip ();
                if (boot != "/@" || !FileUtils.test ("/boot/grub/grub.cfg", FileTest.EXISTS) ||
                    !FileUtils.test ("/usr/sbin/update-grub", FileTest.IS_EXECUTABLE))
                    throw new IOError.NOT_SUPPORTED ("Snapshot previews require existing GRUB with /boot inside the Btrfs @ root");
                var timeshift = new PrivilegedChange ("recovery-timeshift");
                if (timeshift.inspect ().get_string_member ("state") != "matching")
                    throw new IOError.NOT_SUPPORTED ("Configure Timeshift recovery before enabling snapshot previews");
            }
            string? caller = null;
            Posix.uid_t caller_uid = 0;
            Posix.gid_t caller_gid = 0;
            if (id == "system-monitor-controls" || id == "development-homebrew") {
                uint64 uid = 0;
                var identity = Environment.get_variable ("PKEXEC_UID");
                if (identity == null || !uint64.try_parse (identity, out uid) || uid == 0 || uid > uint32.MAX)
                    throw new IOError.PERMISSION_DENIED ("This operation requires the account authorised by pkexec");
                unowned Posix.Passwd? account = Posix.getpwuid ((Posix.uid_t) uid);
                if (account == null)
                    throw new IOError.NOT_FOUND ("The authorised account no longer exists");
                caller = account.pw_name;
                caller_uid = account.pw_uid;
                caller_gid = account.pw_gid;
                if (id == "development-homebrew") {
                    var prefix = File.new_for_path ("/home/linuxbrew/.linuxbrew");
                    if (prefix.query_exists ()) {
                        var information = prefix.query_info ("standard::type,unix::uid", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                        if (information.get_file_type () != FileType.DIRECTORY || information.get_attribute_uint32 ("unix::uid") != caller_uid)
                            throw new IOError.PERMISSION_DENIED ("The Homebrew prefix belongs to another account or is not a directory; existing installations are preserved");
                    }
                }
            }
            var plan = plan ();
            bool package_operation = specification.get_string_member ("kind") == "apt";
            if (package_operation) {
                if (plan.get_string_member ("state") == "unavailable")
                    throw new IOError.NOT_SUPPORTED ("%s\n%s", plan.get_string_member ("current"), plan.get_string_member ("details"));
                if (plan.get_string_member ("state") == "matching") {
                    stdout.printf ("%s\n%s\n", plan.get_string_member ("current"), plan.get_string_member ("details"));
                    return;
                }
            }
            if (id == "browsers-vivaldi-install" || id == "development-vscode") {
                var vendor = id == "development-vscode" ? "microsoft" : "vivaldi";
                var source = id == "development-vscode" ? "vscode" : "vivaldi";
                var address = id == "development-vscode" ? "https://packages.microsoft.com/repos/code" : "https://repo.vivaldi.com/stable/deb";
                bool configured = false;
                var sources = Dir.open ("/etc/apt/sources.list.d");
                string? name;
                while ((name = sources.read_name ()) != null) {
                    if (!name.has_suffix (".list") && !name.has_suffix (".sources"))
                        continue;
                    string contents;
                    FileUtils.get_contents (Path.build_filename ("/etc/apt/sources.list.d", name), out contents);
                    if (name.has_suffix (".list")) {
                        configured = configured || Regex.match_simple ("^\\s*deb\\s+(?:\\[[^\\]]+\\]\\s+)?" + Regex.escape_string (address) + "(?:/|\\s|$)", contents, RegexCompileFlags.MULTILINE);
                    } else {
                        foreach (var stanza in Regex.split_simple ("\\n\\s*\\n", contents)) {
                            if (!Regex.match_simple ("^Enabled:\\s*no\\s*$", stanza, RegexCompileFlags.MULTILINE | RegexCompileFlags.CASELESS) &&
                                Regex.match_simple ("^Types:\\s+deb(?:\\s|$)", stanza, RegexCompileFlags.MULTILINE))
                                configured = configured || Regex.match_simple ("^URIs:\\s+" + Regex.escape_string (address) + "(?:/|\\s|$)", stanza, RegexCompileFlags.MULTILINE);
                        }
                    }
                }
                if (FileUtils.test ("/etc/apt/sources.list", FileTest.EXISTS)) {
                    string contents;
                    FileUtils.get_contents ("/etc/apt/sources.list", out contents);
                    configured = configured || Regex.match_simple ("^\\s*deb\\s+(?:\\[[^\\]]+\\]\\s+)?" + Regex.escape_string (address) + "(?:/|\\s|$)", contents, RegexCompileFlags.MULTILINE);
                }
                if (!configured) {
                    var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/keys/%s.asc".printf (vendor), ResourceLookupFlags.NONE);
                    var key_path = "/etc/apt/keyrings/miuutil-%s.asc".printf (vendor);
                    replace_configuration (key_path, (string) bytes.get_data (), 0644);
                    replace_configuration ("/etc/apt/sources.list.d/%s.sources".printf (source),
                        "Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nSigned-By: %s\n".printf (address, key_path), 0644);
                }
            }
            execute ({"/usr/bin/apt-get", "update"}, true, true);
            string[] packages = {"/usr/bin/apt-get", "--yes", "--no-remove", "-o", "Dpkg::Options::=--force-confold", "install"};
            if (package_operation) {
                var selection = new DebianPackages (specification, execute);
                if (selection.state == "unavailable")
                    throw new IOError.NOT_SUPPORTED ("%s\n%s", selection.current, selection.details);
                stdout.printf ("%s\n%s\n", selection.current, selection.details);
                foreach (var name in selection.missing)
                    packages += name;
                if (selection.missing.length > 0)
                    execute (packages, true, true);
                return;
            }
            foreach (var node in plan.get_array_member ("packages").get_elements ())
                packages += node.get_string ();
            execute (packages, true, true);
            switch (id) {
                case "system-zram":
                    replace_configuration ("/etc/systemd/zram-generator.conf.d/50-miuutil.conf", "[zram0]\n", 0644);
                    execute ({"/usr/bin/systemctl", "daemon-reload"}, true, true);
                    stdout.printf ("zram configuration saved. Restart the computer if zram remains inactive.\n");
                    break;
                case "system-timesync":
                    execute ({"/usr/bin/systemctl", "enable", "--now", "systemd-timesyncd.service"}, true, true);
                    execute ({"/usr/bin/timedatectl", "set-ntp", "true"}, true, true);
                    break;
                case "system-monitor-controls":
                    replace_configuration ("/etc/modules-load.d/miuutil-i2c.conf", "i2c-dev\n", 0644);
                    execute ({"/usr/sbin/modprobe", "i2c-dev"}, true, true);
                    if (Posix.getgrnam ("i2c") == null)
                        execute ({"/usr/sbin/groupadd", "--system", "i2c"}, true, true);
                    execute ({"/usr/sbin/usermod", "--append", "--groups", "i2c", caller}, true, true);
                    stdout.printf ("Monitor permissions saved. Sign out and sign in to use the new group.\n");
                    break;
                case "system-passwordless-admin":
                    replace_configuration ("/etc/sudoers.d/99-miuutil-admin", "%sudo ALL=(ALL:ALL) NOPASSWD: ALL\n", 0440);
                    execute ({"/usr/sbin/visudo", "--check", "--file", "/etc/sudoers.d/99-miuutil-admin"}, true, true);
                    replace_configuration ("/etc/polkit-1/rules.d/00-miuutil-admin.rules",
                        "polkit.addRule(function(action, subject) {\n    if (subject.isInGroup(\"sudo\") && subject.local && subject.active) {\n        return polkit.Result.YES;\n    }\n});\n", 0644);
                    break;
                case "recovery-timeshift":
                    var settings = new Json.Object ();
                    if (FileUtils.test ("/etc/timeshift/timeshift.json", FileTest.EXISTS)) {
                        var parser = new Json.Parser ();
                        parser.load_from_file ("/etc/timeshift/timeshift.json");
                        settings = parser.get_root ().get_object ();
                    }
                    settings.set_string_member ("backup_device_uuid", uuid);
                    settings.set_string_member ("parent_device_uuid", "");
                    settings.set_string_member ("do_first_run", "false");
                    settings.set_string_member ("btrfs_mode", "true");
                    settings.set_string_member ("include_btrfs_home_for_backup", "false");
                    settings.set_string_member ("include_btrfs_home_for_restore", "false");
                    settings.set_string_member ("stop_cron_emails", "true");
                    settings.set_string_member ("schedule_monthly", "false");
                    settings.set_string_member ("schedule_weekly", "true");
                    settings.set_string_member ("schedule_daily", "true");
                    settings.set_string_member ("schedule_hourly", "false");
                    settings.set_string_member ("schedule_boot", "true");
                    settings.set_string_member ("count_weekly", "7");
                    settings.set_string_member ("count_daily", "8");
                    settings.set_string_member ("count_boot", "2");
                    if (!settings.has_member ("exclude"))
                        settings.set_array_member ("exclude", new Json.Array ());
                    if (!settings.has_member ("exclude-apps"))
                        settings.set_array_member ("exclude-apps", new Json.Array ());
                    var node = new Json.Node (Json.NodeType.OBJECT);
                    node.set_object (settings);
                    replace_configuration ("/etc/timeshift/timeshift.json", Json.to_string (node, true) + "\n", 0644);
                    bool miubian = FileUtils.test ("/var/lib/miubomz/installed", FileTest.EXISTS);
                    bool legacy_hook = miubian && FileUtils.test ("/etc/apt/apt.conf.d/80-miubomz-snapshots", FileTest.EXISTS) &&
                        FileUtils.test ("/usr/lib/miubomz/apt-pre-snapshot", FileTest.IS_EXECUTABLE);
                    var hook = legacy_hook ? "/usr/lib/miubomz/apt-pre-snapshot" : Path.build_filename (Config.LIBEXEC_DIR, "apt-pre-snapshot");
                    replace_configuration (legacy_hook ? "/etc/apt/apt.conf.d/80-miubomz-snapshots" : "/etc/apt/apt.conf.d/80-miuutil-snapshots",
                        APT_SNAPSHOT_HOOK.printf (hook, hook), 0644);
                    string startup_service;
                    if (miubian && FileUtils.test ("/usr/lib/systemd/system/miubomz-recovery-start.service", FileTest.EXISTS)) {
                        startup_service = "miubomz-recovery-start.service";
                    } else {
                        replace_configuration ("/etc/systemd/system/miuutil-recovery-start.service",
                            RECOVERY_START_UNIT.printf (Path.build_filename (Config.LIBEXEC_DIR, "recovery-start")), 0644);
                        execute ({"/usr/bin/systemctl", "daemon-reload"}, true, true);
                        startup_service = "miuutil-recovery-start.service";
                    }
                    execute ({"/usr/bin/systemctl", "enable", startup_service}, true, true);
                    execute ({"/usr/bin/systemctl", "enable", "--now", "cron.service"}, true, true);
                    stdout.printf ("Timeshift schedule saved. Initial and due snapshots use Timeshift's normal scheduling.\n");
                    break;
                case "recovery-grub-snapshots":
                    var menu_script = resources_lookup_data ("/com/rispeng/MiuUtil/recovery/grub-btrfs/41_snapshots-btrfs", ResourceLookupFlags.NONE);
                    replace_configuration ("/etc/grub.d/41_snapshots-btrfs", (string) menu_script.get_data (), 0755);
                    var monitor_script = resources_lookup_data ("/com/rispeng/MiuUtil/recovery/grub-btrfs/grub-btrfsd", ResourceLookupFlags.NONE);
                    replace_configuration (Path.build_filename (Config.LIBEXEC_DIR, "grub-btrfsd"), (string) monitor_script.get_data (), 0755);
                    var recovery_config = resources_lookup_data ("/com/rispeng/MiuUtil/recovery/grub-btrfs/config", ResourceLookupFlags.NONE);
                    replace_configuration ("/etc/default/grub-btrfs/config", (string) recovery_config.get_data (), 0644);
                    replace_configuration ("/etc/default/grub.d/99-miuutil-snapshots.cfg", "GRUB_TIMEOUT_STYLE=menu\nGRUB_TIMEOUT=5\n", 0644);
                    replace_configuration ("/etc/systemd/system/miuutil-grub-btrfsd.service",
                        "[Unit]\nDescription=Update GRUB Timeshift snapshot entries\nConditionPathExists=/etc/timeshift/timeshift.json\nConditionKernelCommandLine=!boot=live\nConditionKernelCommandLine=!boot=casper\nConditionKernelCommandLine=!overlayroot=tmpfs:recurse=0\nAfter=miuutil-recovery-start.service\n\n[Service]\nType=simple\nTimeoutStartSec=5min\nEnvironment=\"PATH=/usr/sbin:/usr/bin:/sbin:/bin\"\nEnvironmentFile=/etc/default/grub-btrfs/config\nExecStart=%s --syslog --timeshift-auto\nRestart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n".printf (Path.build_filename (Config.LIBEXEC_DIR, "grub-btrfsd")), 0644);
                    execute ({"/usr/sbin/update-initramfs", "-u", "-k", "all"}, true, true);
                    execute ({"/usr/sbin/update-grub"}, true, true);
                    execute ({"/usr/bin/systemctl", "daemon-reload"}, true, true);
                    execute ({"/usr/bin/systemctl", "enable", "--now", "miuutil-grub-btrfsd.service"}, true, true);
                    if (FileUtils.test ("/usr/lib/systemd/system/grub-btrfsd.service", FileTest.EXISTS) ||
                        FileUtils.test ("/etc/systemd/system/grub-btrfsd.service", FileTest.EXISTS))
                        execute ({"/usr/bin/systemctl", "disable", "--now", "grub-btrfsd.service"}, true, true);
                    stdout.printf ("GRUB snapshot previews configured. Use Timeshift Restore for a permanent rollback.\n");
                    break;
                case "development-pacstall":
                case "applications-harmonoid":
                    var release_name = id == "applications-harmonoid" ? "harmonoid" : "pacstall";
                    var inputs = resources_lookup_data ("/com/rispeng/MiuUtil/upstreams.json", ResourceLookupFlags.NONE);
                    var manifest = new Json.Parser ();
                    manifest.load_from_data ((string) inputs.get_data (), (ssize_t) inputs.get_size ());
                    var artifact = manifest.get_root ().get_object ().get_object_member ("artifacts").get_object_member (release_name);
                    var temporary = DirUtils.make_tmp ("miuutil-" + release_name + "-XXXXXX");
                    var archive = Path.build_filename (temporary, release_name + ".deb");
                    try {
                        execute ({"/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--max-filesize", artifact.get_int_member ("bytes").to_string (), "--output", archive,
                            artifact.get_string_member ("url")}, true, true);
                        var file = File.new_for_path (archive);
                        uint8[] contents;
                        file.load_contents (null, out contents, null);
                        var checksum = Checksum.compute_for_data (ChecksumType.SHA256, contents);
                        if (checksum != artifact.get_string_member ("sha256"))
                            throw new IOError.INVALID_DATA ("The %s release package failed SHA-256 verification", release_name);
                        execute ({"/usr/bin/apt-get", "--yes", "--no-remove", "-o", "Dpkg::Options::=--force-confold", "install", archive}, true, true);
                    } finally {
                        FileUtils.unlink (archive);
                        DirUtils.remove (temporary);
                    }
                    break;
                case "development-homebrew":
                    var prefix = File.new_for_path ("/home/linuxbrew/.linuxbrew");
                    if (!prefix.query_exists ()) {
                        var parent = File.new_for_path ("/home/linuxbrew");
                        if (!parent.query_exists ()) {
                            parent.make_directory ();
                            Posix.chmod (parent.get_path (), 0755);
                        }
                        var information = parent.query_info ("standard::type,unix::uid,unix::mode", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                        if (information.get_file_type () != FileType.DIRECTORY || information.get_attribute_uint32 ("unix::uid") != 0 ||
                            (information.get_attribute_uint32 ("unix::mode") & 0022) != 0)
                            throw new IOError.PERMISSION_DENIED ("The Homebrew parent directory must be a root-owned directory without group or other write access");
                        prefix.make_directory ();
                        if (Posix.chown (prefix.get_path (), caller_uid, caller_gid) != 0 || Posix.chmod (prefix.get_path (), 0755) != 0)
                            throw new IOError.FAILED ("Cannot prepare the Homebrew prefix for %s", caller);
                    }
                    stdout.printf ("Homebrew's standard prefix is ready for %s. Installation continues as that account.\n", caller);
                    break;
                case "system-default-terminal":
                case "system-default-editor":
                case "system-default-browser":
                    string[] alternatives = id == "system-default-browser" ? new string[] { "x-www-browser", "gnome-www-browser" } :
                        id == "system-default-terminal" ? new string[] { "x-terminal-emulator" } : new string[] { "editor" };
                    var destination = id == "system-default-browser" ? "/usr/bin/vivaldi-stable" :
                        id == "system-default-terminal" ? "/usr/bin/xdg-terminal-exec" : "/usr/bin/mcedit";
                    foreach (var alternative in alternatives) {
                        var registered = execute ({"/usr/bin/update-alternatives", "--query", alternative}, false, false);
                        if (!registered.contains ("\nAlternative: " + destination + "\n"))
                            execute ({"/usr/bin/update-alternatives", "--install", "/usr/bin/" + alternative, alternative, destination, "40"}, true, true);
                        execute ({"/usr/bin/update-alternatives", "--set", alternative, destination}, true, true);
                    }
                    break;
                case "system-root-mc-skin":
                    var preferences = new KeyFile ();
                    if (FileUtils.test ("/root/.config/mc/ini", FileTest.EXISTS))
                        preferences.load_from_file ("/root/.config/mc/ini", KeyFileFlags.KEEP_COMMENTS);
                    preferences.set_string ("Midnight-Commander", "skin", "yadt256-defbg");
                    replace_configuration ("/root/.config/mc/ini", preferences.to_data (), 0600);
                    break;
            }
        }

        public static bool services_ready (string[] enabled_units, string[] active_units, DebianPackageQuery query) throws Error {
            foreach (var unit in enabled_units) {
                var response = query ({"/usr/bin/systemctl", "show", "--property=LoadState,UnitFileState,ActiveState", unit}, false, false);
                var properties = response.strip ().split ("\n");
                if (!("LoadState=loaded" in properties) || !("UnitFileState=enabled" in properties) ||
                    (unit in active_units && !("ActiveState=active" in properties)))
                    return false;
            }
            return true;
        }

        public static bool time_synchronisation_ready (DebianPackageQuery query) throws Error {
            return services_ready ({"systemd-timesyncd.service"}, {"systemd-timesyncd.service"}, query) &&
                query ({"/usr/bin/timedatectl", "show", "--property=NTP"}, false, false).strip () == "NTP=yes";
        }

        private static bool is_debian () throws Error {
            string release;
            FileUtils.get_contents ("/etc/os-release", out release);
            foreach (var line in release.split ("\n")) {
                var assignment = line.split ("=", 2);
                if (assignment.length != 2 || (assignment[0] != "ID" && assignment[0] != "ID_LIKE"))
                    continue;
                var identity = assignment[1].strip ().replace ("\"", "").replace ("'", "");
                foreach (var parent in identity.split (" ")) {
                    if (parent == "debian")
                        return true;
                }
            }
            return false;
        }

        private static bool kernel_supports (string module) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            launcher.set_environ ({"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C.UTF-8", "LC_ALL=C.UTF-8"});
            var process = launcher.spawnv ({"/usr/sbin/modprobe", "--dry-run", "--quiet", module});
            process.wait ();
            return process.get_successful ();
        }

        private static string recovery_filesystem () throws Error {
            var root = execute ({"/usr/bin/findmnt", "--noheadings", "--output", "FSTYPE,FSROOT,UUID", "--target", "/"}, false, true);
            var home = execute ({"/usr/bin/findmnt", "--noheadings", "--output", "FSTYPE,FSROOT,UUID", "--target", "/home"}, false, true);
            var root_fields = Regex.split_simple ("\\s+", root.strip ());
            var home_fields = Regex.split_simple ("\\s+", home.strip ());
            if (root_fields.length != 3 || home_fields.length != 3 || root_fields[0] != "btrfs" || home_fields[0] != "btrfs" ||
                root_fields[1] != "/@" || home_fields[1] != "/@home" || root_fields[2] != home_fields[2])
                throw new IOError.NOT_SUPPORTED ("Timeshift requires an existing Btrfs @ root and separate @home on the same filesystem");
            return root_fields[2];
        }

        public static string execute (string[] arguments, bool report, bool require_success) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.set_environ ({"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root", "USER=root", "LOGNAME=root", "LANG=C.UTF-8", "LC_ALL=C.UTF-8", "DEBIAN_FRONTEND=noninteractive"});
            var process = launcher.spawnv (arguments);
            var stream = new DataInputStream (process.get_stdout_pipe ());
            var captured = new StringBuilder ();
            var diagnostics = new StringBuilder ();
            Error? diagnostic_error = null;
            var diagnostic_reader = new Thread<void*> ("miuutil-helper-stderr", () => {
                try {
                    var errors = new DataInputStream (process.get_stderr_pipe ());
                    string? line;
                    while ((line = errors.read_line ()) != null) {
                        if (report) {
                            stdout.printf ("%s\n", line);
                            stdout.flush ();
                        }
                        if (diagnostics.len < 65536)
                            diagnostics.append_len (line + "\n", (ssize_t) size_t.min ((line + "\n").length, 65536 - diagnostics.len));
                    }
                } catch (Error error) {
                    diagnostic_error = error;
                    process.force_exit ();
                }
                return null;
            });
            try {
                string? line;
                while ((line = stream.read_line ()) != null) {
                    if (report) {
                        stdout.printf ("%s\n", line);
                        stdout.flush ();
                    }
                    if (captured.len < 65536)
                        captured.append_len (line + "\n", (ssize_t) size_t.min ((line + "\n").length, 65536 - captured.len));
                }
            } catch (Error error) {
                process.force_exit ();
                diagnostic_reader.join ();
                process.wait ();
                throw error;
            }
            diagnostic_reader.join ();
            process.wait ();
            if (diagnostic_error != null)
                throw diagnostic_error;
            if (require_success && !process.get_successful ())
                throw new IOError.FAILED ("%s failed: %s\n%s", arguments[0], captured.str.strip (), diagnostics.str.strip ());
            return captured.str;
        }

        private static void replace_configuration (string path, string contents, uint mode) throws Error {
            var parent = File.new_for_path (Path.get_dirname (path));
            if (!parent.query_exists ())
                parent.make_directory_with_parents ();
            var destination = File.new_for_path (path);
            destination.replace_contents (contents.data, null, true, FileCreateFlags.REPLACE_DESTINATION, null, null);
            if (Posix.chmod (path, (Posix.mode_t) mode) != 0)
                throw new IOError.FAILED ("Cannot set permissions for %s", path);
        }
    }
}
