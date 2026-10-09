These tests are completely AI-generated and have not been audited. Passing them does not establish that MiuUtil is correct.

| File | Behaviour covered |
| --- | --- |
| `options.vala` | Loading choices, detecting and applying preferences, preserving personal files and browser data, and reporting changes or failures. Includes menu positioning, blur artefact handling and desktop exclusions, and consistent cursors across applications, while preserving existing themes. |
| `desktop-settings.vala` | Applying panel layouts across monitors, enabling selected extensions and clearing tiling shortcuts while retaining unrelated settings and saved layouts. |
| `options-packages.vala` | Recognising installed software, finding available packages and distinguishing missing requirements from optional omissions. |
| `plan-tests.vala` | Applying prerequisites first, avoiding repeats, rejecting invalid plans and keeping unfinished choices selected after a failure. |
| `upstream-tests.vala` | Download records specifying exact versions and rejection of altered download contents before installation. |
| `helper-tests.vala` | Administrator permissions, approved system tasks, package and recovery previews, background services and useful failure messages. |
| `helper-script-tests.py` | Permission rules, terminal history and unusual filenames; supported monitor controls, zeroing, restoration and failures; and required snapshots before updates without extra snapshots during recovery previews. |
| `ui-tests.vala` | Searching, filtering, selection, review, applying and stopping changes, retrying unfinished choices and using narrow windows. |
| `ci-build-tests.py` | Packages and launchers record their exact source and checksums. Tags retain their releases, failed drafts can be retried, and older builds cannot replace either latest channel. |
| `launcher-tests.py` | Both latest channels verify the selected package, preserve existing installations, clean up after closure or interruptions, and retain recovery files if cleanup fails. Tagged downloads stay together while the release alias changes. Package and application commands are simulated. |
| `upstream-smoke.vala` | Manual checks of real downloads and installations, followed by confirming the result. These use the network when needed and are not included in the default test run. |

`Containerfile` provides a separate test environment, and `meson.build` organises the test runs. These files contain no behaviour tests.
