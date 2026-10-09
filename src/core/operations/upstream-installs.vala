namespace MiuUtil {
    public class UpstreamOperation : Operation {
        private string identity;
        private string upstream;
        private Json.Object specification;
        private Json.Object manifest;
        private string shell_version = "";
        private ConfigurationOperation? cursor_links;

        public UpstreamOperation (string identity, Json.Object specification) throws Error {
            this.identity = identity;
            this.specification = specification;
            upstream = specification.get_string_member ("upstream");
            var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/upstreams.json", ResourceLookupFlags.NONE);
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            manifest = parser.get_root ().get_object ();
            if (upstream == "fluent-icons" && specification.has_member ("files")) {
                cursor_links = new ConfigurationOperation (identity, specification);
                Signal.connect_object (cursor_links, "output", (Callback) relay_output, this, ConnectFlags.SWAPPED);
            }
        }

        private static void relay_output (UpstreamOperation operation, string text) {
            operation.output (text);
        }

        public override async Assessment inspect (Cancellable? cancellable) throws Error {
            var home = Environment.get_home_dir ();
            var data = Environment.get_user_data_dir ();
            var config = Environment.get_user_config_dir ();
            string? installed_path = null;
            string? program = null;
            switch (upstream) {
                case "fluent-gtk":
                    installed_path = Path.build_filename (data, "themes", "Fluent-round-Dark-compact", "gtk-4.0", "gtk.css");
                    if (FileUtils.test ("/usr/share/themes/Fluent-round-Dark-compact/gtk-4.0/gtk.css", FileTest.EXISTS))
                        return new Assessment (OptionState.MATCHING, "Fluent GTK theme is installed system-wide.");
                    break;
                case "fluent-icons":
                    bool icons_installed = FileUtils.test ("/usr/share/icons/Fluent-dark/index.theme", FileTest.EXISTS) ||
                        FileUtils.test (Path.build_filename (data, "icons", "Fluent-dark", "index.theme"), FileTest.EXISTS);
                    var dark = Path.build_filename (data, "icons", "fluent-dark");
                    var light = Path.build_filename (data, "icons", "fluent");
                    bool dark_installed = FileUtils.test (Path.build_filename (
                        FileUtils.test (dark, FileTest.EXISTS) ? dark : "/usr/share/icons/fluent-dark", "cursors"), FileTest.IS_DIR);
                    bool light_installed = FileUtils.test (Path.build_filename (
                        FileUtils.test (light, FileTest.EXISTS) ? light : "/usr/share/icons/fluent", "cursors"), FileTest.IS_DIR);
                    if (icons_installed && dark_installed && light_installed) {
                        if (cursor_links == null)
                            return new Assessment (OptionState.MATCHING, "Fluent icons and cursors are installed.");
                        var links = yield cursor_links.inspect (cancellable);
                        if (links.state == OptionState.UNAVAILABLE)
                            return links;
                        return new Assessment (links.state == OptionState.MATCHING ? OptionState.MATCHING : OptionState.PARTIAL,
                            links.state == OptionState.MATCHING ? "Fluent icons and cursors are available to desktop applications." :
                            "Fluent icons and cursors are installed; native cursor links need updating.", links.details);
                    }
                    break;
                case "blesh":
                    if (FileUtils.test ("/usr/share/blesh/ble.sh", FileTest.EXISTS))
                        return new Assessment (OptionState.MATCHING, "ble.sh is installed system-wide.");
                    installed_path = Path.build_filename (data, "blesh", "ble.sh");
                    break;
                case "uosc":
                    installed_path = Path.build_filename (config, "mpv", "scripts", "uosc", "main.lua");
                    break;
                case "qview":
                    installed_path = Path.build_filename (home, "AppImages", "qview.appimage");
                    break;
                case "nautilus-actions":
                    installed_path = Path.build_filename (data, "nautilus-python", "extensions", "actions-for-nautilus.py");
                    break;
                case "homebrew":
                    installed_path = "/home/linuxbrew/.linuxbrew/bin/brew";
                    if (FileUtils.test (installed_path, FileTest.IS_EXECUTABLE)) {
                        var gcc = yield run_process ({ installed_path, "list", "--formula", "gcc" }, cancellable, false);
                        return new Assessment (gcc.strip () != "" ? OptionState.MATCHING : OptionState.PARTIAL,
                            gcc.strip () != "" ? "Homebrew and GCC are installed." : "Homebrew is installed; GCC is missing.");
                    }
                    if (!FileUtils.test (Config.HELPER_PATH, FileTest.IS_EXECUTABLE))
                        return new Assessment (OptionState.UNAVAILABLE, "Install MiuUtil's administrator helper to prepare Homebrew's standard prefix.");
                    break;
                case "extension":
                    var uuid = specification.get_string_member ("uuid");
                    if (Environment.find_program_in_path ("gnome-shell") == null)
                        return new Assessment (OptionState.UNAVAILABLE, "GNOME Shell is required for this extension.");
                    var report = (yield run_process ({ "gnome-shell", "--version" }, cancellable)).strip ().split (" ");
                    shell_version = report[report.length - 1].split (".")[0];
                    var locations = new string[] {
                        Path.build_filename (data, "gnome-shell", "extensions", uuid, "metadata.json"),
                        Path.build_filename ("/usr/share/gnome-shell/extensions", uuid, "metadata.json")
                    };
                    foreach (var location in locations) {
                        if (!FileUtils.test (location, FileTest.EXISTS))
                            continue;
                        var metadata = new Json.Parser ();
                        metadata.load_from_file (location);
                        var versions = metadata.get_root ().get_object ().get_array_member ("shell-version");
                        foreach (var version in versions.get_elements ()) {
                            if (version.get_string ().split (".")[0] == shell_version)
                                return new Assessment (OptionState.MATCHING, "A compatible extension is installed.", "Log out and back in after changing extension code.");
                        }
                        break;
                    }
                    var extensions = manifest.get_object_member ("extensions");
                    if (!extensions.has_member (uuid) || !extensions.get_object_member (uuid).has_member (shell_version))
                        return new Assessment (OptionState.UNAVAILABLE,
                            "No verified upstream release is available for GNOME Shell %s.".printf (shell_version));
                    break;
                case "rustup":
                    program = "rustup";
                    installed_path = Path.build_filename (home, ".cargo", "bin", "rustup");
                    break;
                case "starship": case "mise": case "easyvenv": case "fetch":
                    program = upstream;
                    installed_path = Path.build_filename (home, ".local", "bin", upstream);
                    break;
                default:
                    return new Assessment (OptionState.UNAVAILABLE, "This upstream installer is not supported.");
            }
            bool executable_install = program != null || upstream == "qview";
            if ((installed_path != null && FileUtils.test (installed_path, executable_install ? FileTest.IS_EXECUTABLE : FileTest.EXISTS)) ||
                (program != null && Environment.find_program_in_path (program) != null))
                return new Assessment (OptionState.MATCHING, "Already installed.");
            if (upstream == "qview" || upstream == "starship" || upstream == "mise" || upstream == "easyvenv" || upstream == "rustup") {
                var architecture = (yield run_process ({ "uname", "-m" }, cancellable)).strip ();
                if (architecture != "x86_64")
                    return new Assessment (OptionState.UNAVAILABLE, "This verified binary release supports x86-64 systems.");
            }
            if (Environment.find_program_in_path ("curl") == null || Environment.find_program_in_path ("tar") == null)
                return new Assessment (OptionState.PARTIAL, "Installation tools must be installed first.", "The prerequisite will be included in Review.", true);
            return new Assessment (OptionState.DIFFERENT, "Not installed.",
                "Downloads an official upstream artifact and checks its SHA-256 before installation. Existing installations are preserved.");
        }

        public override async void apply (Cancellable? cancellable) throws Error {
            var data = Environment.get_user_data_dir ();
            if (upstream == "fluent-icons") {
                bool icons_installed = FileUtils.test ("/usr/share/icons/Fluent-dark/index.theme", FileTest.EXISTS) ||
                    FileUtils.test (Path.build_filename (data, "icons", "Fluent-dark", "index.theme"), FileTest.EXISTS);
                var dark = Path.build_filename (data, "icons", "fluent-dark");
                var light = Path.build_filename (data, "icons", "fluent");
                bool dark_installed = FileUtils.test (Path.build_filename (
                    FileUtils.test (dark, FileTest.EXISTS) ? dark : "/usr/share/icons/fluent-dark", "cursors"), FileTest.IS_DIR);
                bool light_installed = FileUtils.test (Path.build_filename (
                    FileUtils.test (light, FileTest.EXISTS) ? light : "/usr/share/icons/fluent", "cursors"), FileTest.IS_DIR);
                if (icons_installed && dark_installed && light_installed) {
                    if (cursor_links != null && (yield cursor_links.inspect (cancellable)).state != OptionState.MATCHING)
                        yield cursor_links.apply (cancellable);
                    return;
                }
            }
            Json.Object artifact;
            if (upstream == "extension") {
                var uuid = specification.get_string_member ("uuid");
                artifact = manifest.get_object_member ("extensions").get_object_member (uuid).get_object_member (shell_version);
            } else {
                artifact = manifest.get_object_member ("artifacts").get_object_member (upstream);
            }
            var workspace = DirUtils.make_tmp ("miuutil-install-XXXXXX");
            var archive = Path.build_filename (workspace, "release");
            var source = Path.build_filename (workspace, "source");
            var home = Environment.get_home_dir ();
            var config = Environment.get_user_config_dir ();
            var bin = Path.build_filename (home, ".local", "bin");
            string? extension_staging = null;
            try {
                output ("Downloading the verified upstream release %s...".printf (artifact.get_string_member ("version")));
                yield run_process ({ "curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2",
                    "--output", archive, artifact.get_string_member ("url") }, cancellable);
                var checksum = new Checksum (ChecksumType.SHA256);
                var stream = yield File.new_for_path (archive).read_async (Priority.DEFAULT, cancellable);
                while (true) {
                    var block = yield stream.read_bytes_async (1024 * 1024, Priority.DEFAULT, cancellable);
                    if (block.get_size () == 0)
                        break;
                    checksum.update (block.get_data (), block.get_size ());
                }
                yield stream.close_async (Priority.DEFAULT, cancellable);
                if (checksum.get_string () != artifact.get_string_member ("sha256"))
                    throw new IOError.INVALID_DATA ("The downloaded release does not match its recorded SHA-256.");
                output ("Download verified.");
                DirUtils.create_with_parents (source, 0700);
                DirUtils.create_with_parents (bin, 0755);
                var format = artifact.get_string_member ("format");
                if (format == "tar-source" || format == "tar-prebuilt")
                    yield run_process ({ "tar", "--extract", "--file", archive, "--directory", source, "--strip-components=1" }, cancellable);
                else if (format == "tar-binary")
                    yield run_process ({ "tar", "--extract", "--file", archive, "--directory", source }, cancellable);
                else if (format == "zip")
                    yield run_process ({ "unzip", "-q", archive, "-d", source }, cancellable);

                switch (upstream) {
                    case "fluent-gtk":
                        var themes = Path.build_filename (data, "themes");
                        DirUtils.create_with_parents (themes, 0755);
                        yield run_process ({ "bash", Path.build_filename (source, "install.sh"), "--dest", themes,
                            "--color", "dark", "--size", "compact", "--tweaks", "round", "blur" }, cancellable);
                        break;
                    case "fluent-icons":
                        var icons = Path.build_filename (data, "icons");
                        DirUtils.create_with_parents (icons, 0755);
                        yield run_process ({ "bash", Path.build_filename (source, "install.sh"), "--dest", icons }, cancellable);
                        DirUtils.create_with_parents (Path.build_filename (icons, "fluent-dark"), 0755);
                        DirUtils.create_with_parents (Path.build_filename (icons, "fluent"), 0755);
                        yield run_process ({ "cp", "-a", Path.build_filename (source, "cursors", "dist-dark") + "/.", Path.build_filename (icons, "fluent-dark") }, cancellable);
                        yield run_process ({ "cp", "-a", Path.build_filename (source, "cursors", "dist") + "/.", Path.build_filename (icons, "fluent") }, cancellable);
                        if (cursor_links != null)
                            yield cursor_links.apply (cancellable);
                        break;
                    case "blesh":
                        var blesh = Path.build_filename (data, "blesh");
                        DirUtils.create_with_parents (blesh, 0755);
                        yield run_process ({ "cp", "-a", source + "/.", blesh }, cancellable);
                        break;
                    case "starship": case "easyvenv": case "mise":
                        var executable = upstream == "mise" ? Path.build_filename (source, "mise", "bin", "mise") : Path.build_filename (source, upstream);
                        var target = Path.build_filename (bin, upstream);
                        yield File.new_for_path (executable).copy_async (File.new_for_path (target), FileCopyFlags.OVERWRITE, Priority.DEFAULT, cancellable, null);
                        File.new_for_path (target).set_attribute_uint32 (FileAttribute.UNIX_MODE, 0755, FileQueryInfoFlags.NONE);
                        break;
                    case "qview":
                        var appimages = Path.build_filename (home, "AppImages");
                        DirUtils.create_with_parents (appimages, 0755);
                        var appimage = Path.build_filename (appimages, "qview.appimage");
                        yield File.new_for_path (archive).copy_async (File.new_for_path (appimage), FileCopyFlags.OVERWRITE, Priority.DEFAULT, cancellable, null);
                        File.new_for_path (appimage).set_attribute_uint32 (FileAttribute.UNIX_MODE, 0755, FileQueryInfoFlags.NONE);
                        var launchers = Path.build_filename (data, "applications");
                        DirUtils.create_with_parents (launchers, 0755);
                        var launcher = new KeyFile ();
                        launcher.set_string ("Desktop Entry", "Type", "Application");
                        launcher.set_string ("Desktop Entry", "Name", "qView");
                        launcher.set_string ("Desktop Entry", "Exec", "\"" + appimage.replace ("\\", "\\\\").replace ("\"", "\\\"").replace ("$", "\\$").replace ("`", "\\`") + "\" %F");
                        launcher.set_string ("Desktop Entry", "Icon", "image-x-generic");
                        launcher.set_string ("Desktop Entry", "Categories", "Graphics;Viewer;");
                        launcher.set_string ("Desktop Entry", "MimeType", "image/bmp;image/x-win-bitmap;image/gif;image/icns;image/x-icon;image/jpeg;image/jpg;image/x-portable-bitmap;image/x-portable-graymap;image/png;image/x-portable-pixmap;image/svg+xml;image/tiff;image/vnd.wap.wbmp;image/webp;image/x-xbitmap;image/x-xpixmap;application/x-navi-animation;image/apng;image/avif;image/avif-sequence;image/x-sgi-bw;image/aces;image/x-exr;image/vnd.radiance;image/heic;image/heif;image/jxl;application/x-krita;image/openraster;image/vnd.zbrush.pcx;image/x-pcx;image/x-pic;image/vnd.adobe.photoshop;application/x-photoshop;application/photoshop;application/psd;image/psd;image/x-sun-raster;image/x-rgb;image/x-sgi-rgba;image/sgi;image/x-tga;image/x-xcf;");
                        FileUtils.set_contents (Path.build_filename (launchers, "qview.desktop"), launcher.to_data ());
                        break;
                    case "uosc":
                        var mpv = Path.build_filename (config, "mpv");
                        DirUtils.create_with_parents (mpv, 0755);
                        foreach (var part in new string[] { "scripts", "fonts", "script-opts" }) {
                            var supplied = Path.build_filename (source, part);
                            if (FileUtils.test (supplied, FileTest.IS_DIR))
                                yield run_process ({ "cp", "-a", supplied, mpv }, cancellable);
                        }
                        break;
                    case "fetch":
                        yield run_process ({ "make", "-C", source, "-j2" }, cancellable);
                        yield run_process ({ "make", "-C", source, "PREFIX=" + Path.build_filename (home, ".local"), "install" }, cancellable);
                        break;
                    case "nautilus-actions":
                        var nautilus = Path.build_filename (data, "nautilus-python");
                        DirUtils.create_with_parents (nautilus, 0755);
                        yield run_process ({ "cp", "-a", Path.build_filename (source, "extensions"), nautilus }, cancellable);
                        output ("Restart Files to load Actions for Nautilus.");
                        break;
                    case "rustup":
                        File.new_for_path (archive).set_attribute_uint32 (FileAttribute.UNIX_MODE, 0755, FileQueryInfoFlags.NONE);
                        yield run_process ({ archive, "--yes", "--no-modify-path", "--profile", "minimal" }, cancellable);
                        break;
                    case "homebrew":
                        yield run_process ({ "pkexec", Config.HELPER_PATH, "--apply", identity }, null);
                        var prefix = "/home/linuxbrew/.linuxbrew";
                        var brew = Path.build_filename (prefix, "bin", "brew");
                        if (!FileUtils.test (brew, FileTest.IS_EXECUTABLE)) {
                            DirUtils.create_with_parents (Path.build_filename (prefix, "bin"), 0755);
                            var repository = Path.build_filename (prefix, "Homebrew");
                            var checkout = Path.build_filename (workspace, "Homebrew");
                            if (!FileUtils.test (repository, FileTest.IS_DIR)) {
                                yield run_process ({ "git", "clone", "--depth=1", "--branch", artifact.get_string_member ("version"),
                                    "https://github.com/Homebrew/brew.git", checkout }, cancellable);
                            } else {
                                checkout = repository;
                            }
                            var revision = (yield run_process ({ "git", "-C", checkout, "rev-parse", "HEAD" }, cancellable)).strip ();
                            if (revision != artifact.get_string_member ("commit"))
                                throw new IOError.INVALID_DATA ("The Homebrew checkout does not match its recorded commit.");
                            if (checkout != repository)
                                yield run_process ({ "mv", "--", checkout, repository }, cancellable);
                            File.new_for_path (brew).make_symbolic_link ("../Homebrew/bin/brew");
                        }
                        yield run_process ({ brew, "install", "gcc" }, null);
                        break;
                    case "extension":
                        var uuid = specification.get_string_member ("uuid");
                        var extension = Path.build_filename (data, "gnome-shell", "extensions", uuid);
                        var metadata = new Json.Parser ();
                        metadata.load_from_file (Path.build_filename (source, "metadata.json"));
                        var release = metadata.get_root ().get_object ();
                        if (release.get_string_member ("uuid") != uuid)
                            throw new IOError.INVALID_DATA ("The extension identity does not match its recorded UUID.");
                        bool compatible = false;
                        foreach (var version in release.get_array_member ("shell-version").get_elements ())
                            compatible = compatible || version.get_string ().split (".")[0] == shell_version;
                        if (!compatible)
                            throw new IOError.INVALID_DATA ("The extension release does not support the current GNOME Shell.");
                        var schemas = Path.build_filename (source, "schemas");
                        if (FileUtils.test (schemas, FileTest.IS_DIR))
                            yield run_process ({ "glib-compile-schemas", schemas }, cancellable);
                        var directory = Path.get_dirname (extension);
                        DirUtils.create_with_parents (directory, 0755);
                        extension_staging = Path.build_filename (directory, ".miuutil-" + Uuid.string_random ());
                        var staged = File.new_for_path (Path.build_filename (extension_staging, "new"));
                        staged.make_directory_with_parents (cancellable);
                        yield run_process ({ "cp", "-a", source + "/.", staged.get_path () }, cancellable);
                        var previous = File.new_for_path (Path.build_filename (extension_staging, "previous"));
                        var destination = File.new_for_path (extension);
                        if (FileUtils.test (extension, FileTest.EXISTS)) {
                            var backups = Path.build_filename (Environment.get_user_state_dir (), "miuutil", "backups", identity);
                            DirUtils.create_with_parents (backups, 0700);
                            yield run_process ({ "cp", "-a", extension, Path.build_filename (backups, new DateTime.now_utc ().format ("%Y%m%dT%H%M%S%f")) }, cancellable);
                            destination.move (previous, FileCopyFlags.NONE, null, null);
                        }
                        try {
                            staged.move (destination, FileCopyFlags.NONE, null, null);
                        } catch (Error error) {
                            if (previous.query_exists ()) {
                                previous.move (destination, FileCopyFlags.NONE, null, null);
                            }
                            throw error;
                        }
                        output ("Log out and back in to load newly installed extension code.");
                        break;
                }
            } finally {
                try {
                    string[] paths = { "rm", "-rf", "--", workspace };
                    if (extension_staging != null)
                        paths += extension_staging;
                    var cleanup = new Subprocess.newv (paths, SubprocessFlags.NONE);
                    cleanup.wait ();
                } catch (Error error) {
                    warning ("Could not remove installation staging %s: %s", workspace, error.message);
                }
            }
        }
    }
}
