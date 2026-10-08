These tests are completely AI-generated and have not been audited. Passing them does not establish that MiuUtil is correct.

| File | Behaviour covered |
| --- | --- |
| `options.vala` | Loading choices, detecting and applying preferences, preserving personal files and browser data, and reporting changes or failures. Includes menu positioning and desktop blur exclusions. |
| `desktop-settings.vala` | Applying panel layouts across monitors, enabling selected extensions and clearing tiling shortcuts while retaining unrelated settings and saved layouts. |
| `options-packages.vala` | Recognising installed software, finding available packages and distinguishing missing requirements from optional omissions. |
| `plan-tests.vala` | Applying prerequisites first, avoiding repeats, rejecting invalid plans and keeping unfinished choices selected after a failure. |
| `upstream-tests.vala` | Download records specifying exact versions and rejection of altered download contents before installation. |
| `helper-tests.vala` | Administrator permissions, approved system tasks, package and recovery previews, background services and useful failure messages. |
| `helper-script-tests.py` | Permission rules, terminal history and unusual filenames; supported monitor controls, zeroing, restoration and failures; and required snapshots before updates without extra snapshots during recovery previews. |
| `ui-tests.vala` | Searching, filtering, selection, review, applying and stopping changes, retrying unfinished choices and using narrow windows. |
| `upstream-smoke.vala` | Manual checks of real downloads and installations, followed by confirming the result. These use the network when needed and are not included in the default test run. |

`Containerfile` provides a separate test environment, and `meson.build` organises the test runs. These files contain no behaviour tests.
