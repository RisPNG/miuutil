using MiuUtil;

private Json.Object packages_specification (string[] names, bool available_only = false, string[]? remove_names = null) {
    var specification = new Json.Object ();
    var packages = new Json.Array ();
    foreach (var name in names)
        packages.add_string_element (name);
    specification.set_array_member ("packages", packages);
    specification.set_boolean_member ("available_only", available_only);
    if (remove_names != null) {
        var removals = new Json.Array ();
        foreach (var name in remove_names)
            removals.add_string_element (name);
        specification.set_array_member ("remove_packages", removals);
    }
    return specification;
}

int main (string[] arguments) {
    Test.init (ref arguments);
    Test.add_func ("/packages/installed-multiarch-without-candidate", () => {
        try {
            uint queries = 0;
            var selection = new DebianPackages (packages_specification ({ "fonts-installed" }), (command, report, require_success) => {
                queries++;
                assert_cmpstr (command[0], CompareOperator.EQ, "/usr/bin/dpkg-query");
                return "fonts-installed:amd64\tinstalled\n";
            });
            assert_cmpuint (queries, CompareOperator.EQ, 1);
            assert_cmpstr (selection.state, CompareOperator.EQ, "matching");
            assert_cmpuint (selection.supported.length, CompareOperator.EQ, 1);
            assert_cmpuint (selection.missing.length, CompareOperator.EQ, 0);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/available-font-subset-lists-omissions", () => {
        try {
            var selection = new DebianPackages (packages_specification ({ "fonts-installed", "fonts-ready", "fonts-unavailable" }, true), (command, report, require_success) => {
                return command[0] == "/usr/bin/dpkg-query" ? "fonts-installed\tinstalled\n" :
                    "fonts-ready:\n  Installed: (none)\n  Candidate: 1.2\nfonts-unavailable:\n  Installed: (none)\n  Candidate: (none)\n";
            });
            assert_cmpstr (selection.state, CompareOperator.EQ, "partial");
            assert_cmpuint (selection.requested.length, CompareOperator.EQ, 3);
            assert_cmpuint (selection.supported.length, CompareOperator.EQ, 2);
            assert_cmpuint (selection.omitted.length, CompareOperator.EQ, 1);
            assert_cmpstr (selection.missing[0], CompareOperator.EQ, "fonts-ready");
            assert (selection.current.contains ("1 unavailable"));
            assert (selection.details.contains ("fonts-unavailable"));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/required-missing-candidate-is-unavailable", () => {
        try {
            var selection = new DebianPackages (packages_specification ({ "native-present", "native-required" }), (command, report, require_success) => {
                return command[0] == "/usr/bin/dpkg-query" ? "native-present\tinstalled\n" : "";
            });
            assert_cmpstr (selection.state, CompareOperator.EQ, "unavailable");
            assert_cmpstr (selection.omitted[0], CompareOperator.EQ, "native-required");
            assert (selection.details.contains ("native-required"));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/no-supported-fonts-is-unavailable", () => {
        try {
            var selection = new DebianPackages (packages_specification ({ "fonts-unavailable" }, true), (command, report, require_success) => {
                return "";
            });
            assert_cmpstr (selection.state, CompareOperator.EQ, "unavailable");
            assert_cmpuint (selection.supported.length, CompareOperator.EQ, 0);
            assert_cmpuint (selection.omitted.length, CompareOperator.EQ, 1);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/candidate-queries-are-batched", () => {
        try {
            string[] names = {};
            for (uint index = 0; index < 65; index++)
                names += "fonts-example-%u".printf (index);
            uint candidate_queries = 0;
            var selection = new DebianPackages (packages_specification (names, true), (command, report, require_success) => {
                if (command[0] == "/usr/bin/dpkg-query")
                    return "";
                assert_cmpstr (command[0], CompareOperator.EQ, "/usr/bin/env");
                assert_cmpstr (command[1], CompareOperator.EQ, "LC_ALL=C");
                assert_cmpstr (command[2], CompareOperator.EQ, "/usr/bin/apt-cache");
                assert_cmpstr (command[3], CompareOperator.EQ, "policy");
                assert_cmpuint (command.length, CompareOperator.LE, 36);
                candidate_queries++;
                var response = new StringBuilder ();
                for (int index = 4; index < command.length; index++)
                    response.append (command[index] + ":amd64:\n  Installed: (none)\n  Candidate: 1.0\n");
                return response.str;
            });
            assert_cmpuint (candidate_queries, CompareOperator.EQ, 3);
            assert_cmpstr (selection.state, CompareOperator.EQ, "different");
            assert_cmpuint (selection.supported.length, CompareOperator.EQ, 65);
            assert_cmpuint (selection.missing.length, CompareOperator.EQ, 65);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/config-files-state-needs-installation", () => {
        try {
            var selection = new DebianPackages (packages_specification ({ "native-required" }), (command, report, require_success) => {
                return command[0] == "/usr/bin/dpkg-query" ? "native-required\tconfig-files\n" :
                    "native-required:\n  Installed: (none)\n  Candidate: 1.0\n";
            });
            assert_cmpstr (selection.state, CompareOperator.EQ, "different");
            assert_cmpuint (selection.installed_count, CompareOperator.EQ, 0);
            assert_cmpstr (selection.missing[0], CompareOperator.EQ, "native-required");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/invalid-name-never-runs-package-tools", () => {
        bool queried = false;
        try {
            new DebianPackages (packages_specification ({ "--arbitrary-option" }), (command, report, require_success) => {
                queried = true;
                return "";
            });
            Test.fail ();
        } catch (IOError.INVALID_DATA error) {
            assert (!queried);
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/removal-only-batches-multiarch-without-candidates", () => {
        try {
            uint queries = 0;
            var specification = packages_specification ({}, false, { "nautilus-extension-gnome-terminal" });
            specification.remove_member ("packages");
            var selection = new DebianPackages (specification, (command, report, require_success) => {
                queries++;
                assert (!report);
                if (command[0] == "/usr/bin/dpkg-query") {
                    assert (!require_success);
                    assert_cmpuint (command.length, CompareOperator.EQ, 4);
                    assert_cmpstr (command[3], CompareOperator.EQ, "nautilus-extension-gnome-terminal");
                    return "nautilus-extension-gnome-terminal:amd64\tinstalled\nnautilus-extension-gnome-terminal:i386\tinstalled\n";
                }
                assert (require_success);
                assert_cmpstr (string.joinv (" ", command), CompareOperator.EQ,
                    "/usr/bin/apt-get --simulate --yes --no-auto-remove remove nautilus-extension-gnome-terminal:amd64 nautilus-extension-gnome-terminal:i386");
                return "Reading package lists...\nRemv nautilus-extension-gnome-terminal [3.56.2-2]\nRemv nautilus-extension-gnome-terminal:i386 [3.56.2-2]\n";
            });
            assert_cmpuint (queries, CompareOperator.EQ, 2);
            assert_cmpstr (selection.state, CompareOperator.EQ, "different");
            assert_cmpuint (selection.requested.length, CompareOperator.EQ, 0);
            assert_cmpuint (selection.requested_removals.length, CompareOperator.EQ, 1);
            assert_cmpuint (selection.installed_removals.length, CompareOperator.EQ, 2);
            assert_cmpstr (selection.installed_removals[1], CompareOperator.EQ, "nautilus-extension-gnome-terminal:i386");
            assert_cmpstr (selection.current, CompareOperator.EQ, "0 of 1 conflicting packages absent");
            assert (selection.details.contains ("Packages to remove:"));
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/removed-and-config-files-conflicts-are-already-absent", () => {
        foreach (var response in new string[] { "", "nautilus-extension-gnome-terminal\tconfig-files\n" }) {
            try {
                uint queries = 0;
                var selection = new DebianPackages (packages_specification ({}, false, { "nautilus-extension-gnome-terminal" }),
                    (command, report, require_success) => {
                        queries++;
                        assert_cmpstr (command[0], CompareOperator.EQ, "/usr/bin/dpkg-query");
                        return response;
                    });
                assert_cmpuint (queries, CompareOperator.EQ, 1);
                assert_cmpstr (selection.state, CompareOperator.EQ, "matching");
                assert_cmpuint (selection.installed_removals.length, CompareOperator.EQ, 0);
                assert_cmpstr (selection.current, CompareOperator.EQ, "1 of 1 conflicting packages absent");
                assert_cmpstr (selection.details, CompareOperator.EQ, "");
            } catch (Error error) {
                Test.message (error.message);
                Test.fail ();
            }
        }
    });

    Test.add_func ("/packages/installed-requirement-with-conflict-is-partial", () => {
        try {
            var selection = new DebianPackages (packages_specification ({ "blackbox-terminal" }, false,
                { "nautilus-extension-gnome-terminal" }), (command, report, require_success) => {
                if (command[0] == "/usr/bin/dpkg-query") {
                    assert_cmpuint (command.length, CompareOperator.EQ, 5);
                    return "blackbox-terminal\tinstalled\nnautilus-extension-gnome-terminal\tinstalled\n";
                }
                assert_cmpstr (command[0], CompareOperator.EQ, "/usr/bin/apt-get");
                return "Remv nautilus-extension-gnome-terminal [3.56.2-2]\n";
            });
            assert_cmpstr (selection.state, CompareOperator.EQ, "partial");
            assert_cmpuint (selection.missing.length, CompareOperator.EQ, 0);
            assert_cmpuint (selection.installed_removals.length, CompareOperator.EQ, 1);
            assert_cmpstr (selection.current, CompareOperator.EQ, "1 of 1 supported packages installed; 0 of 1 conflicting packages absent");
        } catch (Error error) {
            Test.message (error.message);
            Test.fail ();
        }
    });

    Test.add_func ("/packages/invalid-removal-never-runs-package-tools", () => {
        foreach (var removal in new string[] { "--purge", "nautilus-extension-gnome-terminal;true", "blackbox-terminal" }) {
            bool queried = false;
            try {
                new DebianPackages (packages_specification ({ "blackbox-terminal" }, false, { removal }),
                    (command, report, require_success) => {
                        queried = true;
                        return "";
                    });
                Test.fail ();
            } catch (IOError.INVALID_DATA error) {
                assert (!queried);
            } catch (Error error) {
                Test.message (error.message);
                Test.fail ();
            }
        }
    });

    Test.add_func ("/packages/removal-plan-cannot-broaden-package-changes", () => {
        foreach (var response in new string[] {
            "Remv nautilus-extension-gnome-terminal [3.56.2-2]\nRemv gnome-terminal [3.56.2-2]\n",
            "Remv nautilus-extension-gnome-terminal [3.56.2-2]\nInst gnome-terminal [3.56.2-2]\n",
            "Remv nautilus-extension-gnome-terminal [3.56.2-2]\nConf gnome-terminal (3.56.2-2)\n",
            "Remv nautilus-extension-gnome-terminal:i386 [3.56.2-2]\n",
            "Reading package lists...\n"
        }) {
            uint queries = 0;
            try {
                new DebianPackages (packages_specification ({}, false, { "nautilus-extension-gnome-terminal" }),
                    (command, report, require_success) => {
                        queries++;
                        return command[0] == "/usr/bin/dpkg-query" ?
                            "nautilus-extension-gnome-terminal:amd64\tinstalled\n" : response;
                    });
                Test.fail ();
            } catch (IOError.NOT_SUPPORTED error) {
                assert_cmpuint (queries, CompareOperator.EQ, 2);
            } catch (Error error) {
                Test.message (error.message);
                Test.fail ();
            }
        }
    });
    return Test.run ();
}
