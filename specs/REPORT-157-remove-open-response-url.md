# Remove Open Response URL Columns from the Student Answers Report

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-157

**Status**: **Closed**

## Overview

Adds a "Remove open response link columns (audio/report links)" checkbox to the report server's Student Answers form. When a researcher checks it, the report leaves out the link column that normally follows each open response question, which makes the report much shorter for resources with many open response questions. Reports made without the checkbox are unchanged.

In the Student Answers report, every open response question produces two columns: the student's text answer and a link to the portal report's single-question view, where an audio response can be heard. Research teams whose modules don't use audio get nothing from the link column, and in a long sequence it roughly doubles the number of open response columns. The ticket also asked that the teacher-facing downloadable CSV drop the column; CLASSDASH-116 in portal-report already gives each open response a single column there, so this story needs no work in portal-report.

## Requirements

- The Student Answers report's generation form shows a checkbox labeled "Remove open response link columns (audio/report links)". It sits on its own row, in the same stacked checkbox layout as "Hide names": directly below "Hide names" when that checkbox is shown, and directly below the date row when it isn't. Like "Hide names", it appears once the first filter is chosen.
- The checkbox is unchecked by default every time the report's form is opened. The form has no reset control; it starts from empty params on each visit (`handle_params/3`).
- The checkbox appears only on reports that opt in through `form_options`. Only Student Answers opts in, because it is the only report that emits per-question columns.
- The checkbox is available to every user who can run the report. It is not role-gated the way Hide names is.
- When the checkbox is checked, the generated Athena SQL contains no `res_<n>_<question_id>_url` column for any `open_response` question, in the header row or in the data rows.
- When the checkbox is checked, every other column is unchanged, including the open response `_text` and `_submitted` columns, and the `_url` columns of `iframe_interactive`, `clue_text_tile`, `clue_question` and `clue_tile` questions.
- When the checkbox is unchecked, the generated SQL is identical to what it was before this change.
- When the checkbox is checked, no column marks an audio-only open response answer, so it reads like a skipped question: its `_text` cell holds no answer text. That cell is usually empty. When the report-state placeholder is stored JSON-escaped, the cell holds the raw placeholder instead, in checked and unchecked reports alike. This is an accepted tradeoff: the `_url` column is the report's only sign of an audio answer, and researchers who check the box don't use audio. The `_text` column's content does not change. *(the JSON-escaped placeholder is a separate, existing bug tracked as REPORT-162)*
- The choice is saved with the report run, so the run's summary shows it as a "Remove Open Response Links: True" row next to "Hide Names", only when it is on, and duplicating the run keeps it.
- Report runs saved before this change load and behave as if the checkbox was unchecked.
- The report run JSON API accepts the option as an optional boolean in `report_filter` when a run is created. It defaults to `false` when absent and is rejected with the existing "must be true or false" error when it is not a boolean. Every run's returned filter JSON includes it, `false` for older runs.
- The option has the same effect on an API-created run as on a form-created one. `false` is accepted on every report, so a filter copied from any run's JSON can be sent back unchanged. `true` on a report that does not offer the checkbox is rejected with a 400 `BAD_REQUEST` and the message "This report does not support removing open response links.", the same way `FilterValidation.check_app_supported/2` rejects an application filter. The form path goes through the same validation.
- For a run made with the checkbox checked, the post-processing page does not offer the `HasAudio` or `TranscribeAudio` steps, since they depend on the removed column. The other steps are still offered.

## Technical Notes

- Column generation: `server/lib/report_server/reports/athena/shared_queries.ex`. `generate_resource_sql/4` passes `remove_open_response_urls` to `get_columns_for_question/6` as a trailing keyword option (default `[]`), and the `"open_response"` branch drops its `_url` column when it is set. Every row (prompt, correct-answer, data) is built from the one column list, so dropping it there removes it from all of them.
- Option storage: `remove_open_response_urls` is a boolean field on `%ReportFilter{}` (default `false`), read in `from_form/2` like `hide_names`. `EctoReportFilter.load/1` uses `struct!/2`, so stored runs without the key load with it off. `dump/1` writes every struct key, so every run saved after the deploy carries it, and a build without the field raises `KeyError` loading those runs. A rollback past this release needs those runs' filters cleaned up, or a forward fix. `exclude_internal` and `app` were added under the same constraint.
- Which reports offer it: `FilterValidation.offers_remove_open_response_urls?/1` reads `form_options` (`enable_remove_open_response_urls: true` on Student Answers in `tree.ex`). The form's `get_form_options/2` and `check_remove_open_response_urls_supported/2` both use it, so the checkbox and the rule can't drift. `validate/2` is called by the form's submit, the API create and duplicate.
- Form and summary: the checkbox is in `form.html.heex` after the Hide names block, without Hide names' `whitespace-nowrap` so the 55-character label can wrap. The summary row is in `custom_components.ex`.
- JSON API: `filter_params.ex` (`base/1`, `boolean/2`) parses it and `report_json.ex` (`report_filter_json/1`, `!!`) emits it. `FilterOptionsController`'s moduledoc lists it among the emitted keys that narrow nothing on that endpoint.
- Post-processing: `PostProcessingComponent.steps_for_run/1` drops `HasAudio` and `TranscribeAudio` (ids taken from the step modules) for runs with the option, and both `init/2` and `show_component?/2` use it. Those steps find each answer's `answersSourceKey` through the open response `_url` column (`Helpers.parse_res_answer_col/2`).
- Tests: `shared_queries_test.exs` pins the default open response `_text`/`_url` pair exactly, captured from the code before the change, as the guard for "unchanged when unchecked". The form test sets the checkbox through `form/3`, which raises when the rendered form has no input by that name, so a misnamed `field` fails it; params passed straight to `render_change/3` would not.
- cc-data-cli passes `report_filter` through as opaque JSON and reads no `_url` column, so it needs no change.
- The legacy JavaScript query-creator Lambda (`query-creator/create-query/steps/aws.js`) holds a parallel copy of the open response column code for the portal's older report flow. It is unchanged.

## Out of Scope

- The teacher downloadable CSV. CLASSDASH-116 in portal-report already puts each open response in a single column with no separate link column. The link appears in that column only for audio-only answers.
- Removing the column as a post-processing step. It is removed at query generation, per the product owner's direction.
- The legacy JavaScript query-creator Lambda used by the portal's older researcher report flow, and any matching checkbox in the portal.
- Removing `_url` columns of other question types.
- Detecting automatically whether a resource uses audio and dropping the column without being asked.
- Marking audio-only answers in the `_text` column when the link column is removed, either with a placeholder or by moving the link into the `_text` cell as the teacher CSV does.
- Two existing bugs found while working on this story, filed separately: REPORT-161 (a crafted post-processing submit naming a step the run doesn't offer crashes the handler, in both submit handlers) and REPORT-162 (an unanswered open response placeholder stored JSON-escaped leaks into the `_text` column).

## Decisions

### Should the option hide the audio post-processing steps, or make them work without the column?
**Context**: `HasAudio` and `TranscribeAudio` read the open response `_url` column to find each answer's `answersSourceKey`, so without it they fail for every row.
**Options considered**:
- A) Don't offer the two audio steps on runs made with the option.
- B) Derive the source key from `res_<n>_resource_url`, the same fallback the SQL uses, so the steps keep working.
- C) Leave them as they are and let them fail.

**Decision**: A. A researcher who removes the audio link column has said they don't use audio, and hiding the steps avoids a second source-key derivation that would have to stay in step with the SQL. B is the better choice only if people want to remove the column and still transcribe audio.

---

### Where should the option live?
**Context**: It is a report modifier, not a filter, but `%ReportFilter{}` is already where `hide_names` and `exclude_internal` are persisted, displayed and duplicated.
**Options considered**:
- A) A boolean field on `%ReportFilter{}`, following `hide_names`.
- B) A new column or embedded options map on `report_runs`.

**Decision**: A. It is saved, duplicated and shown in the run summary for free, with no migration. B would be cleaner if report options grow.

---

### Which reports show the checkbox, and who can see it?
**Context**: Only the `:answers` report type builds per-question columns, and Hide names is role-gated through `HideNames.allowed?/1`.
**Options considered**:
- A) Student Answers only, visible to everyone who can run it.
- B) Every Athena report, visible to everyone.
- C) Student Answers only, gated like Hide names.

**Decision**: A. On any other report the checkbox would do nothing, and removing a link column exposes no data, so it needs no role gate. Because most researchers don't get Hide names, the requirement places the checkbox below the date row when Hide names isn't shown; a browser check as a project researcher confirmed that layout.

---

### Is the legacy query-creator Lambda out of scope?
**Context**: The requester wrote "a checkbox to the portal reports", and the portal's older researcher report flow calls the Lambda, which has its own copy of the `_url` column code.
**Options considered**:
- A) Report server form only.
- B) Also add a query parameter to the Lambda, which needs a matching portal (rigse) change and so would be a separate story.

**Decision**: A. Researchers who want shorter reports use the report server's Student Answers report.

---

### What should the checkbox say?
**Context**: The direction was "something like 'Remove open response url'". Researchers call the column "the second column" or "the link column".
**Options considered**:
- A) "Remove open response URL"
- B) "Remove open response URL columns"
- C) "Remove open response link columns (audio/report links)"

**Decision**: C, because it tells researchers what they give up. Each checkbox has its own full-width row, so the longer label fits, and it drops `whitespace-nowrap` so it wraps on a narrow window (checked at 360px).

---

### Should the report run JSON API accept and return the option, and on which reports?
**Context**: cc-data and other API callers create Student Answers runs through `POST /api/v1/reports`. Accepting `true` everywhere would contradict how `check_app_supported/2` treats an application filter and would put a meaningless summary row on, say, a Student Actions run.
**Options considered**:
- A) Accept it as an optional boolean and return it on every run; reject `true` with a 400 on reports that don't offer it, and accept `false` everywhere.
- B) Return it but don't accept it on create.
- C) Leave the API alone.

**Decision**: A. API-created runs can use the option, API readers can see how any run was made, and a filter copied from any run's JSON can be sent back unchanged.

---

### Should the teacher downloadable CSV get a follow-up ticket?
**Context**: The ticket's second request, dropping the column from the teacher CSV, belongs in portal-report.
**Options considered**:
- A) File a follow-up ticket in portal-report.
- B) Note it as out of scope and let the requester decide.

**Decision**: Neither. CLASSDASH-116 already specifies the teacher CSV with one column per open response and no `_url` columns.

---

### How should audio-only answers look once the link column is removed?
**Context**: An audio-only answer has no answer text, which is why the `_url` link is always generated for open responses.
**Options considered**:
- A) Accept that it reads like a skipped question, and write down the tradeoff.
- B) Mark audio-only answers in the `_text` cell, with a placeholder or the link. Either needs SQL to detect an audio answer from the stored data, and moving the link in brings back what the researcher asked to remove.

**Decision**: A. Only researchers who don't use audio check the box, and the label names the audio links it removes. Testing against production showed the `_text` cell isn't always empty for an unanswered question, because a placeholder stored JSON-escaped slips past the existing blanking check. That bug predates this story, affects checked and unchecked reports alike, and is tracked as REPORT-162 rather than fixed here, so this PR keeps its "unchanged when unchecked" guarantee.

---

### How should the option reach `get_columns_for_question`?
**Context**: The builder took five positional arguments, and the CLUE tests call it with five.
**Options considered**:
- A) A trailing keyword `opts \\ []`.
- B) Pass the whole `%ReportFilter{}`.
- C) A sixth positional boolean.

**Decision**: A. The builder shouldn't depend on the whole filter for one flag, and a bare boolean at a call site doesn't say what it means. Existing five-argument callers keep working.

---

### Where does "which reports offer it" live?
**Context**: The form needs it to render the checkbox, and validation needs it to reject the option.
**Options considered**:
- A) One function, `FilterValidation.offers_remove_open_response_urls?/1`, used by both.
- B) Read `form_options` separately in each.

**Decision**: A, following `AthenaFailure.offers_app_filter?/1`, which the form and `check_app_supported/2` share.

---

### How is "unchanged when unchecked" guarded?
**Context**: A test comparing a default filter with one built without the key compares a struct with an identical struct and can't fail, and counting `_url` occurrences would miss a change to the column's value.
**Options considered**:
- A) Pin the full default open response column maps, captured from the code before the change.
- B) Weaken the requirement to match a weaker test.

**Decision**: A. The pinned maps were confirmed byte-identical between the old and new code, and the SQL test counts the `_url` alias in each row with the option on and off.

---

### How does the form test prove the checkbox reaches the run?
**Context**: Injecting `"remove_open_response_urls" => "true"` into `render_change/3` sends the params as they are, so a misnamed `field` in the template passed both the render and the submit test while a browser would send a key `from_form/2` ignores.
**Options considered**:
- A) Set the box through the rendered form with `form/3`, which raises on an unknown input name.
- B) Keep the injected params.

**Decision**: A. A mutation renaming the field fails only the `form/3` test. "Unchecked by default" is checked against the element (`#remove_open_response_urls[checked]`), not the whole page.

---

### Can a hidden post-processing step still be submitted?
**Context**: The submit handler resolves step ids with `Enum.find/2` and keeps the `nil` for an id that isn't offered, so a crafted submit raises `KeyError` in the LiveView or in the run's `JobServer`. Any unknown id does the same in existing code, in both submit handlers.
**Options considered**:
- A) Leave the handler alone and say only that a hidden step can never run.
- B) Drop unresolved ids in this component's handler.
- C) B, plus the legacy page's handler.

**Decision**: A, decided by Doug. The crash predates this story and isn't made easier to reach by it, so the fix for both handlers is tracked as REPORT-161.

---

### Does duplicating a run keep the option?
**Context**: It does, because `duplicate_api_report_run/3` copies the whole filter, but nothing tested it.
**Options considered**:
- A) Add a test.
- B) Drop the claim from the requirements.

**Decision**: A, decided by Doug. `reports_api_runs_test.exs` duplicates a run with the option on and checks the stored copy.
