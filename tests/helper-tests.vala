void rejects_untrusted_identifiers () {
    foreach (var id in new string[] {"../../etc/sudoers", "apps-copyq;touch /tmp/miuutil-test", "--shell", "not-an-option"}) {
        bool rejected = false;
        try {
            new MiuUtil.PrivilegedChange (id);
        } catch (Error error) {
            rejected = true;
        }
        assert (rejected);
    }
}

void rejects_user_operations () {
    bool rejected = false;
    try {
        var bytes = resources_lookup_data ("/com/rispeng/MiuUtil/catalogue.json", ResourceLookupFlags.NONE);
        var parser = new Json.Parser ();
        parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
        foreach (var node in parser.get_root ().get_object ().get_array_member ("options").get_elements ()) {
            var definition = node.get_object ();
            if (definition.get_object_member ("operation").get_string_member ("kind") == "settings") {
                try {
                    new MiuUtil.PrivilegedChange (definition.get_string_member ("id"));
                } catch (IOError.PERMISSION_DENIED error) {
                    rejected = true;
                }
                break;
            }
        }
    } catch (Error error) {
        critical ("%s", error.message);
    }
    assert (rejected);
}

void describes_fixed_package_install () {
    try {
        var change = new MiuUtil.PrivilegedChange ("apps-copyq");
        var plan = change.plan ();
        assert (plan.get_boolean_member ("requires_admin"));
        assert (plan.get_array_member ("requested_packages").get_string_element (0) == "copyq");
        var packages = plan.get_array_member ("packages");
        var omissions = plan.get_array_member ("omitted_packages");
        assert (packages.get_length () + omissions.get_length () == plan.get_array_member ("requested_packages").get_length ());
        var assessment = change.inspect ();
        assert (plan.get_string_member ("state") == assessment.get_string_member ("state"));
        assert (plan.get_string_member ("details") == assessment.get_string_member ("details"));
        assert (plan.get_array_member ("files").get_length () == 0);
    } catch (Error error) {
        critical ("%s", error.message);
    }
}

void describes_recovery_without_mutation () {
    try {
        var plan = new MiuUtil.PrivilegedChange ("recovery-timeshift").plan ();
        assert (plan.get_array_member ("packages").get_string_element (0) == "timeshift");
        assert (plan.get_array_member ("files").get_string_element (0) == "/etc/timeshift/timeshift.json");
        var preview = new MiuUtil.PrivilegedChange ("recovery-grub-snapshots").plan ();
        assert (preview.get_array_member ("packages").get_string_element (0) == "overlayroot");
    } catch (Error error) {
        critical ("%s", error.message);
    }
}

void private_assessments_require_authorisation () {
    if (Posix.geteuid () == 0)
        return;
    foreach (var id in new string[] {"system-passwordless-admin", "system-root-mc-skin"}) {
        bool rejected = false;
        try {
            new MiuUtil.PrivilegedChange (id).inspect ();
        } catch (IOError.PERMISSION_DENIED error) {
            rejected = true;
        } catch (Error error) {
            critical ("%s", error.message);
        }
        assert (rejected);
    }
}

void package_queries_preserve_stdout_and_drain_stderr () {
    try {
        var output = MiuUtil.PrivilegedChange.execute ({"/usr/bin/python3", "-c",
            "import os; os.write(1, b'fonts-test'); os.write(2, b'diagnostic' * 20000 + b'\\n'); os.write(1, b'\\tinstalled\\n')"}, false, true);
        assert (output == "fonts-test\tinstalled\n");
        output = MiuUtil.PrivilegedChange.execute ({"/usr/bin/dpkg-query", "--show", "--showformat=${binary:Package}\t${db:Status-Status}\n",
            "dpkg", "miuutil-regression-package-does-not-exist"}, false, false);
        assert (output == "dpkg\tinstalled\n");
        assert (!output.contains ("no packages found"));
    } catch (Error error) {
        critical ("%s", error.message);
    }
}

void failed_commands_keep_bounded_diagnostics () {
    bool rejected = false;
    try {
        MiuUtil.PrivilegedChange.execute ({"/usr/bin/python3", "-c",
            "import os; os.write(1, b'o' * 200000 + b'\\n'); os.write(2, b'e' * 200000 + b'\\n'); raise SystemExit(1)"}, false, true);
    } catch (IOError.FAILED error) {
        rejected = true;
        assert (error.message.length < 131200);
        assert (error.message.contains ("ooo"));
        assert (error.message.contains ("eee"));
    } catch (Error error) {
        critical ("%s", error.message);
    }
    assert (rejected);
}

void running_services_require_persistent_enablement_and_activity () {
    try {
        foreach (var properties in new string[] {
            "LoadState=loaded\nUnitFileState=enabled\nActiveState=inactive\n",
            "LoadState=loaded\nUnitFileState=enabled\nActiveState=failed\n",
            "LoadState=loaded\nUnitFileState=disabled\nActiveState=active\n",
            "LoadState=masked\nUnitFileState=masked\nActiveState=inactive\n",
            "LoadState=not-found\nUnitFileState=\nActiveState=inactive\n"
        }) {
            assert (!MiuUtil.PrivilegedChange.services_ready ({"cron.service"}, {"cron.service"}, (arguments, report, require_success) => {
                assert (arguments[0] == "/usr/bin/systemctl");
                assert (arguments[3] == "cron.service");
                assert (!report && !require_success);
                return properties;
            }));
        }
        assert (MiuUtil.PrivilegedChange.services_ready ({"miuutil-grub-btrfsd.service"}, {"miuutil-grub-btrfsd.service"}, (arguments, report, require_success) => {
            return "LoadState=loaded\nUnitFileState=enabled\nActiveState=active\n";
        }));
    } catch (Error error) {
        critical ("%s", error.message);
    }
}

void boot_oneshot_requires_enablement_without_running_immediately () {
    try {
        assert (MiuUtil.PrivilegedChange.services_ready ({"miuutil-recovery-start.service"}, {}, (arguments, report, require_success) => {
            return "LoadState=loaded\nUnitFileState=enabled\nActiveState=inactive\n";
        }));
        assert (!MiuUtil.PrivilegedChange.services_ready ({"miuutil-recovery-start.service"}, {}, (arguments, report, require_success) => {
            return "LoadState=loaded\nUnitFileState=disabled\nActiveState=inactive\n";
        }));
    } catch (Error error) {
        critical ("%s", error.message);
    }
}

void time_sync_requires_ntp_enabled_without_waiting_for_network_sync () {
    try {
        assert (!MiuUtil.PrivilegedChange.time_synchronisation_ready ((arguments, report, require_success) => {
            return arguments[0] == "/usr/bin/systemctl" ? "LoadState=loaded\nUnitFileState=enabled\nActiveState=active\n" : "NTP=no\n";
        }));
        assert (MiuUtil.PrivilegedChange.time_synchronisation_ready ((arguments, report, require_success) => {
            if (arguments[0] == "/usr/bin/systemctl")
                return "LoadState=loaded\nUnitFileState=enabled\nActiveState=active\n";
            assert (arguments[0] == "/usr/bin/timedatectl");
            assert (arguments[2] == "--property=NTP");
            return "NTP=yes\n";
        }));
    } catch (Error error) {
        critical ("%s", error.message);
    }
}

int main (string[] arguments) {
    Test.init (ref arguments);
    Test.add_func ("/helper/rejects-untrusted-identifiers", rejects_untrusted_identifiers);
    Test.add_func ("/helper/rejects-user-operations", rejects_user_operations);
    Test.add_func ("/helper/describes-fixed-package-install", describes_fixed_package_install);
    Test.add_func ("/helper/describes-recovery-without-mutation", describes_recovery_without_mutation);
    Test.add_func ("/helper/private-assessments-require-authorisation", private_assessments_require_authorisation);
    Test.add_func ("/helper/package-queries-preserve-stdout-and-drain-stderr", package_queries_preserve_stdout_and_drain_stderr);
    Test.add_func ("/helper/failed-commands-keep-bounded-diagnostics", failed_commands_keep_bounded_diagnostics);
    Test.add_func ("/helper/running-services-require-enablement-and-activity", running_services_require_persistent_enablement_and_activity);
    Test.add_func ("/helper/boot-oneshot-requires-enablement-without-running", boot_oneshot_requires_enablement_without_running_immediately);
    Test.add_func ("/helper/time-sync-requires-ntp-enabled", time_sync_requires_ntp_enabled_without_waiting_for_network_sync);
    return Test.run ();
}
