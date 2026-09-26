# Implementation Plan: Remove Open Response URL Columns from the Student Answers Report

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-157
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

The option is one boolean, `remove_open_response_urls`, on `%ReportFilter{}`. Each step below threads it one layer further: the SQL, then the form and its validation, then the JSON API, then post-processing. All paths are relative to `server/`.

### Leave the open response link column out of the answers SQL when the filter asks for it

**Summary**: Adds the filter field and makes the Athena column builder honour it. After this step the option works end to end for anything that builds a `%ReportFilter{}` with the field set, but nothing in the UI or the API sets it yet. That keeps the SQL change reviewable on its own.

**Files affected**:
- `lib/report_server/reports/report_filter.ex`: new struct field, read in `from_form/2`
- `lib/report_server/reports/athena/shared_queries.ex`: pass the option from `generate_resource_sql/4` into `get_columns_for_question`
- `test/report_server/reports/athena/shared_queries_test.exs`: open response column cases, and a moduledoc that covers them
- `test/report_server/report_filter_test.exs`: `from_form/2` and the stored-row default

**Estimated diff size**: ~130 lines

`lib/report_server/reports/report_filter.ex`, the struct:

```elixir
  defstruct filters: [], cohort: nil, school: nil, teacher: nil, assignment: nil, class: nil, student: nil,
    permission_form: nil, country: nil, state: nil, subject_area: nil, start_date: nil, end_date: nil,
    hide_names: false, exclude_internal: false, app: nil, remove_open_response_urls: false
```

and in `from_form/2`, after the `exclude_internal` line:

```elixir
    |> Map.put(:remove_open_response_urls, form.params["remove_open_response_urls"] == "true")
```

`lib/report_server/reports/athena/shared_queries.ex`, the head of `generate_resource_sql/4`:

```elixir
  def generate_resource_sql(report_type, %ReportFilter{hide_names: hide_names} = report_filter, resource_data, auth_domain) do
    column_opts = [remove_open_response_urls: report_filter.remove_open_response_urls]
```

The call inside the `:answers` branch:

```elixir
              question_columns = get_columns_for_question(question_id, question, denormalized_resource, auth_domain, activity_index, column_opts)
```

The builder gains an options argument that defaults to `[]`, so the existing `/5` callers and tests keep working unchanged:

```elixir
  def get_columns_for_question(question_id, question, denormalized_resource, auth_domain, activity_index, opts \\ []) do
    remove_open_response_urls = Keyword.get(opts, :remove_open_response_urls, false)
```

The `"open_response"` branch. The comment is extended, and the `_url` entry becomes conditional:

```elixir
        "open_response" ->
          # When there is no answer to an open_response question the report state JSON is saved as the answer in Firebase.
          # This detects if the answer looks like the report state JSON and if so returns an empty string to show there was
          # no answer to the question.
          # note: conditional_model_url.() is not used here as students can answer with only audio responses and in that
          # case the answer does not exist as open response answers are only the text of the answer due to the
          # question type being ported from the legacy LARA built in open response questions which only saved the text.
          # The url is left out when the report filter asks for it, which also leaves an audio-only answer looking unanswered.
          text_column = %{name: "#{column_prefix}_text", value: "CASE WHEN starts_with(#{answer}, '\"{\"mode\":\"report\"') THEN '' ELSE (#{answer}) END", header: prompt_header}
          url_column = %{name: "#{column_prefix}_url", value: model_url.(answers_source_key_with_no_answer_fallback), header: prompt_header}

          if remove_open_response_urls, do: [text_column], else: [text_column, url_column]
```

`generate_no_resource_sql/2` emits no question columns and is untouched.

Tests in `shared_queries_test.exs`: a new `describe "get_columns_for_question for open_response"` using the existing `columns/2` helper, extended with keyword options: `required:` sets the question's `required` flag (default `false`), and the rest pass through to `/6` as its `opts`. The moduledoc, which today pins only the CLUE types' column shape, is widened to say the file also pins the open response columns and the option that drops their `_url`:

- by default an open response emits exactly today's two column maps, compared with `==` against literal expected values: the name, the full `value` and the `header` of both `_text` and `_url`. With the file's existing setup (`source_key: "authoring.concord.org"`, `@auth_domain`, `@key`) the `_url` value is the full `CONCAT('https://portal-report.concord.org/branch/master/?auth-domain=https%3A%2F%2Flearn.concord.org&firebase-app=report-service-pro&sourceKey=authoring.concord.org&iframeQuestionId=<key>&class=...', ... '&answersSourceKey=', COALESCE(learners_and_answers_1.source_key['<key>'], IF(... 'activity-player-offline.concord.org', 'activity-player.concord.org', ...)))` string. The prototype captured it from the current code and confirmed the changed code produces byte-identical maps. This is the committed guard for the requirement that unchecked output is unchanged.
- with `remove_open_response_urls: true` it emits only `_text`, and a required one emits `_text` then `_submitted`
- with the option on, `iframe_interactive`, `clue_text_tile` and `clue_question` still emit their `_url` column
- a `generate_resource_sql/4` case, built like `resource_sql/1` in `shared_queries_completion_test.exs` but with one open response and one `iframe_interactive` question. With the option off, `res_1_<open response>_url` appears three times in `raw_sql`: in the Prompt row, the correct-answer row and the data row. With it on, it appears nowhere, and `res_1_<interactive>_url` still appears three times.

Tests in `report_filter_test.exs`, in the existing `from_form/2` describe:

- `"remove_open_response_urls" => "true"` sets the field, and `"false"` or no key leaves it `false`
- `EctoReportFilter.load(%{"hide_names" => true})` returns `remove_open_response_urls: false`. This pins the requirement that runs stored before the change behave as unchecked.

---

### Offer the checkbox on the Student Answers form and show it on the run

**Summary**: Puts the checkbox on the form of reports that opt in (only Student Answers), rejects the option on reports that don't, and adds the run-summary row. Validation lives in `FilterValidation.validate/2`, which the form, the API create and duplicate all call. That keeps the rule in one place before the API starts accepting the field in the next step.

**Files affected**:
- `lib/report_server/reports/filter_validation.ex`: `offers_remove_open_response_urls?/1`, a check in `validate/2`, and the modifier note in `check_constrains_anything/1`'s doc
- `lib/report_server/reports/tree.ex`: opt Student Answers in
- `lib/report_server_web/live/report_live/form.ex`: the form option
- `lib/report_server_web/live/report_live/form.html.heex`: the checkbox
- `lib/report_server_web/components/custom_components.ex`: the summary row
- `test/report_server/reports/filter_validation_test.exs`, `test/report_server_web/live/report_form_live_test.exs` (also the comment above `choose_first_filter/2`, which lists the controls that render once a first filter has a value), `test/report_server_web/components/custom_components_test.exs`

**Estimated diff size**: ~150 lines

`lib/report_server/reports/filter_validation.ex`:

```elixir
  def validate(report_filter = %ReportFilter{}, report = %Report{}) do
    with :ok <- check_app_supported(report_filter, report),
         :ok <- check_remove_open_response_urls_supported(report_filter, report) do
      check_dimensions_offered(report_filter, report)
    end
  end

  @doc "Whether the report's form offers the checkbox that drops the open response link columns."
  def offers_remove_open_response_urls?(%Report{form_options: form_options}),
    do: Keyword.get(form_options, :enable_remove_open_response_urls, false)

  # false is accepted everywhere, so a filter copied from any run's JSON can be sent back unchanged
  def check_remove_open_response_urls_supported(%ReportFilter{remove_open_response_urls: true}, report = %Report{}) do
    if offers_remove_open_response_urls?(report) do
      :ok
    else
      {:error, :invalid, "This report does not support removing open response links."}
    end
  end

  def check_remove_open_response_urls_supported(%ReportFilter{}, %Report{}), do: :ok
```

The `check_constrains_anything/1` doc names the new field alongside the other modifiers: "`hide_names`, `exclude_internal` and `remove_open_response_urls` are modifiers rather than constraints: none of them narrows anything on its own, ...". Its code is unchanged, so the option alone still doesn't satisfy an Athena create.

`lib/report_server/reports/tree.ex`, the Student Answers entry:

```elixir
          form_options: [enable_hide_names: true, enable_remove_open_response_urls: true]
```

`lib/report_server_web/live/report_live/form.ex`, `get_form_options/2`. It isn't role-gated:

```elixir
  defp get_form_options(report = %Report{form_options: form_options}, user = %User{}) do
    %{
      enable_hide_names: HideNames.allowed?(user) && Keyword.get(form_options, :enable_hide_names, false),
      enable_remove_open_response_urls: FilterValidation.offers_remove_open_response_urls?(report),
      enable_app_filter: AthenaFailure.offers_app_filter?(report)
    }
  end
```

(`FilterValidation` is added to the module's alias list if it isn't there already.)

`lib/report_server_web/live/report_live/form.html.heex`, directly after the Hide names `<div>`, in the same stacked layout:

```heex
      <div :if={@form_options.enable_remove_open_response_urls}>
        <div class="flex gap-2 items-center">
          <.input type="checkbox" id="remove_open_response_urls" field={@form["remove_open_response_urls"]} />
          <label for="remove_open_response_urls">Remove open response link columns (audio/report links)</label>
        </div>
      </div>
```

The label drops Hide names' `whitespace-nowrap`, because at 55 characters it has to be able to wrap on a narrow window. It sits inside the existing `<%= if !blank?(@form.params["filter1"]) do %>` block, so it appears when the Hide names checkbox does. The form starts from `to_form(%{})` on each visit, so the box starts unchecked. The existing `"form_updated"` handler already carries any non-filter field through `form_values`, so no handler change is needed.

`lib/report_server_web/components/custom_components.ex`, after the Hide Names row:

```heex
      <div class="table-row" :if={@report_filter.remove_open_response_urls}>
        <div class="table-cell capitalize font-bold">Remove Open Response Links</div>
        <div class="table-cell pl-3">True</div>
      </div>
```

Tests:

- `filter_validation_test.exs`, a new `describe "check_remove_open_response_urls_supported/2"`: `true` on `student-answers` is `:ok`; `true` on `student-actions` is `{:error, :invalid, message}` with the message above; `false` is `:ok` on both; `offers_remove_open_response_urls?/1` is true only for `student-answers` among the tree's reports.
- `report_form_live_test.exs`, a new `describe "the remove open response links checkbox"`:
  - After `choose_first_filter/2` on `student-answers` the HTML has `id="remove_open_response_urls"` and the label text, and `refute has_element?(view, "#remove_open_response_urls[checked]")` holds.
  - It renders for a project researcher too (`mount_form_as/3` with `portal_is_project_researcher: true`), where Hide names doesn't, which shows it isn't role-gated.
  - It doesn't render on `student-actions`.
  - Setting the box through the rendered form and submitting stores `run.report_filter.remove_open_response_urls == true`, and leaving it alone stores `false`. The value goes in through `form/3`, which raises when the rendered form has no input by that name, so a misnamed `field` fails the test. Params passed straight to `render_change/3` would not:

    ```elixir
    view
    |> form("form[phx-submit=submit_form]", filter_form: %{"remove_open_response_urls" => "true"})
    |> render_change(%{"_target" => ["filter_form", "remove_open_response_urls"]})
    ```
  - A crafted `"remove_open_response_urls" => "true"` on `teacher-actions` renders "does not support removing open response links" and creates no run. This mirrors the existing "refuses an application on a report that does not support one".
- `custom_components_test.exs`: the nil-filter test also refutes "Remove Open Response Links", and a new test renders the row for `%ReportFilter{remove_open_response_urls: true}`.

---

### Accept and return the option in the report runs API

**Summary**: Parses the field on create and emits it on every run's filter JSON, following `hide_names` and `exclude_internal`. Rejecting `true` on other reports already happens in `FilterValidation.validate/2` from the previous step, which `Reports.create_api_report_run/3` calls.

**Files affected**:
- `lib/report_server_web/api/v1/filter_params.ex`: parse the boolean in `base/1`
- `lib/report_server_web/api/v1/report_json.ex`: emit it in `report_filter_json/1`
- `lib/report_server_web/api/v1/filter_options_controller.ex`: name the new key in the moduledoc's list of emitted keys that narrow nothing on that endpoint
- `test/report_server_web/api/v1/filter_params_test.exs`, `test/report_server_web/api/v1/report_controller_test.exs`, `test/report_server_web/api/v1/report_create_test.exs`, `test/report_server/reports_api_runs_test.exs`

**Estimated diff size**: ~85 lines

`lib/report_server_web/api/v1/filter_params.ex`, `base/1`:

```elixir
  defp base(filter) do
    with {:ok, exclude_internal} <- boolean(filter, "exclude_internal"),
         {:ok, hide_names} <- boolean(filter, "hide_names"),
         {:ok, remove_open_response_urls} <- boolean(filter, "remove_open_response_urls"),
         {:ok, app} <- app(filter),
         {:ok, start_date} <- date(filter, "start_date"),
         {:ok, end_date} <- date(filter, "end_date") do
      check_dates(%ReportFilter{
        exclude_internal: exclude_internal,
        hide_names: hide_names,
        remove_open_response_urls: remove_open_response_urls,
        app: app,
        start_date: start_date,
        end_date: end_date
      })
    end
  end
```

`lib/report_server_web/api/v1/report_json.ex`, `report_filter_json/1`. `!!` turns a `nil` from any hand-built struct into `false`, and a stored run without the key already loads as `false`:

```elixir
      hide_names: !!report_filter.hide_names,
      exclude_internal: !!report_filter.exclude_internal,
      remove_open_response_urls: !!report_filter.remove_open_response_urls
```

Tests:

- `filter_params_test.exs`: extend "hide_names and exclude_internal are carried" (or add a sibling) so `"remove_open_response_urls" => true` parses to `true` and an empty map to `false`. `"remove_open_response_urls" => 1` returns `{:error, "remove_open_response_urls must be true or false"}`.
- `report_controller_test.exs`: add `remove_open_response_urls` to `@filter_keys`, since both key-set assertions compare against it exactly, and assert it is `false` in the empty-filter case at line ~303.
- `report_create_test.exs` (tagged `:portal_db`, like the rest of the file):
  - Creating `student-answers` with `%{"cohort" => [1], "remove_open_response_urls" => true}` answers 201, and `body["report_filter"]["remove_open_response_urls"] == true`.
  - Creating `student-actions` with the same filter answers 400 `BAD_REQUEST` with the "does not support removing open response links" message, and the run count is unchanged.
- `reports_api_runs_test.exs`, in the existing `describe "duplicate_api_report_run/3"`. It uses that block's `record_starts/0` setup, `admin/0`, `athena_report/0` and `create/3`, and is tagged `:portal_db` like the file. Create a Student Answers run with `%ReportFilter{cohort: [1], remove_open_response_urls: true}`, reload it with `Reports.get_report_run_with_user!/1`, and duplicate it. The copy, reloaded from the DB, has `remove_open_response_urls == true`. It sits in the API step because duplicate runs through the same `create_api_report_run/3` path, and the UI's duplicate action calls the same function.

---

### Stop offering the audio post-processing steps on runs without the link column

**Summary**: `HasAudio` and `TranscribeAudio` find each answer through the open response `_url` column, so a run made without it can't use them. The component builds its step list in one place per run, and `show_component?/2` and `init/2` both switch to it. The submit handler resolves step ids against the `@steps` assign, so a hidden step can never run: a crafted submit naming one fails the same way any unknown step id does today (REPORT-161).

**Files affected**:
- `lib/report_server_web/live/report_live/post_processing.ex`: `steps_for_run/1`
- a new `test/report_server_web/live/post_processing_steps_test.exs`

**Estimated diff size**: ~60 lines

`lib/report_server_web/live/report_live/post_processing.ex`:

```elixir
  alias ReportServer.PostProcessing.Steps.{HasAudio, TranscribeAudio}
  alias ReportServer.Reports.{Report, ReportFilter, ReportRun}

  # both steps find each answer through the open response _url column, which a run made with remove_open_response_urls leaves out
  @open_response_url_step_ids [HasAudio.step().id, TranscribeAudio.step().id]

  @doc "The post-processing steps this run's output supports."
  def steps_for_run(report_run = %ReportRun{}) do
    steps = JobServer.get_steps(get_report_type(report_run))

    case report_run.report_filter do
      %ReportFilter{remove_open_response_urls: true} -> Enum.reject(steps, &(&1.id in @open_response_url_step_ids))
      _ -> steps
    end
  end
```

The aliases join the module's existing alias block. The attribute and `steps_for_run/1` go below it. `HasAudio.step().id` is evaluated at compile time, and the prototype compiled it cleanly with `--warnings-as-errors`. Taking the ids from the step modules, rather than repeating the string literals, keeps them from drifting.

In `init/2`, `report_type = get_report_type(report_run)` and `steps = JobServer.get_steps(report_type)` become `steps = steps_for_run(report_run)`. In `show_component?/2`, the inner `report_type`/`steps` lines become `steps = steps_for_run(report_run)`. `GlossaryData` and `MergeToPrimaryUser` remain, so the component still shows for these runs.

Tests in `post_processing_steps_test.exs` (`use ExUnit.Case, async: true`, no DB, since `steps_for_run/1` is pure over a `%ReportRun{}`):

- a `student-answers` run with a default filter offers `has_audio` and `transcribe_audio`
- one with `remove_open_response_urls: true` offers neither, and still offers the glossary and merge steps
- a run whose `report_filter` is `nil` (a legacy row) offers the full list
- a `student-actions` run's steps are unchanged by the option

## Deploy note

The PR description carries the rollback caveat from the requirements' Technical Notes. Every run saved after this deploy stores `remove_open_response_urls`, and `EctoReportFilter.load/1` in an older build raises `KeyError` on it. So a rollback past this release breaks loading those runs, and a forward fix is the way out.

## Verification

The whole plan was applied to the working tree as throwaway code, exercised, and then reverted. None of it is committed.

- `MIX_ENV=test mix compile --warnings-as-errors` is clean with all four steps applied.
- **The SQL.** With the option off, the generated answers SQL is byte-identical to the current code's (`cmp`). With it on, the open response `_url` is gone from every UNION ALL part, the `iframe_interactive` `_url` stays, and all parts keep the same 15 `res_1_*` aliases in the same order.
- **Columns.** `get_columns_for_question/6`: an open response emits `[_text, _url]` by default and `[_text, _submitted]` when required with the option on. `iframe_interactive` and `clue_text_tile` keep `_url` with the option on. The `/5` form still works.
- **The filter.** `from_form/2` reads `"true"`, `"false"` and a missing key correctly. `EctoReportFilter` round-trips `true`, and loads a stored map without the key as `false`.
- **The form** (LiveView, as a project researcher). The checkbox renders on Student Answers with the full label and no `checked`, and doesn't render on Student Actions. Toggling it through `"form_updated"` keeps it checked, and submitting stores `true` on the run. A crafted `true` on Teacher Actions renders the rejection and creates no run.
- **The API** (`:portal_db`, against the local fixture). Student Answers with `true` answers 201, returning and storing `true`. Student Actions with `true` answers 400 `BAD_REQUEST`, "This report does not support removing open response links.", and creates no run. Student Actions with `false` answers 201.
- **Post-processing.** For Student Answers, `steps_for_run/1` offers `transcribe_audio`, `glossary_data`, `has_audio` and `merge_to_primary_user` by default, and only `glossary_data` and `merge_to_primary_user` with the option on. A `nil` filter gets the full list.
- **The two stage 8 tests.** The pinned default open response columns captured from the current code are byte-identical to what the changed code produces (`cmp` of the two dumps). The duplicate test passed against the prototype, with the copy stored as `true`.
- **Existing suites.** `test/report_server/reports/athena`, `report_filter_test.exs`, `filter_validation_test.exs`, `test/report_server_web/{live,components,api}` and `reports_api_runs_test.exs` ran: 432 tests, and the only 2 failures were the `@filter_keys` exact-set assertions in `report_controller_test.exs`. The API step updates those.

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

### RESOLVED: Judgment call: How should the option reach `get_columns_for_question`?
**Context**: The builder takes five positional arguments, and the CLUE tests call it as `/5`.
**Options considered**:
- A) A trailing keyword `opts \\ []`, so the existing callers and tests don't change.
- B) Pass the whole `%ReportFilter{}`.
- C) A sixth positional boolean.

**Decision**: A. The builder shouldn't depend on the whole filter when it needs one flag, and a bare boolean at a call site doesn't say what it means. The throwaway prototype used exactly this shape and produced identical SQL with the option off.

### RESOLVED: Judgment call: Where does "which reports offer it" live?
**Context**: The form needs it to render the checkbox, and validation needs it to reject the option on other reports.
**Options considered**:
- A) `FilterValidation.offers_remove_open_response_urls?/1`, read from `form_options`, used by both.
- B) Read `form_options` separately in the form and in validation.

**Decision**: A. It follows `AthenaFailure.offers_app_filter?/1`, which the form and `check_app_supported/2` share, so the checkbox and the rule can't drift apart.

### RESOLVED: Judgment call: Four commits, or fold the API into the form step?
**Context**: Each of the API and form steps is small.
**Options considered**:
- A) Four steps: SQL, form and validation, API, post-processing.
- B) Three steps, with the API folded into the form step.

**Decision**: A. The API step touches a contract cc-data consumes (`@filter_keys`), and keeping it separate lets a reviewer check that change on its own. Each step is well under the size limit.

### RESOLVED: Stage 8: Duplicating a run had no test
**Context**: The requirements say duplicating keeps the option. It works because `duplicate_api_report_run/3` copies the whole filter, but no step tested it.
**Options considered**:
- A) Add a test.
- B) Drop the claim from the requirements.

**Decision**: A, decided by Doug. The test is in the API step, in `reports_api_runs_test.exs`.

### RESOLVED: Stage 8: "Unchanged when unchecked" had only a weak committed guard
**Context**: The prototype proved the unchecked SQL byte-identical once, but the committed tests only counted `_url` occurrences, which would miss a change to the column's value.
**Options considered**:
- A) Pin the full default open response column maps.
- B) Weaken the requirement to match the test.

**Decision**: A, decided by Doug. The first step's tests pin both column maps exactly.

## Self-Review

Stage 7 review (Senior Engineer, the commit reviewer, the test runner, the operator, WCAG Accessibility Expert). Each finding was checked against the prototype described under Verification.

### Senior Engineer

#### RESOLVED: The step list's attribute was hedged instead of settled
The draft said to fall back to string literals "if the compiler rejects" `HasAudio.step().id` in a module attribute. The prototype compiled it cleanly with warnings as errors. **Fix**: the hedge is gone, and the plan takes the ids from the step modules.

### Test runner

#### RESOLVED: An SQL test compared the code against itself
"With it off, the SQL equals the SQL from a filter built without the key" compared one struct with another identical struct, because the field is always present, so it could never fail. **Fix**: the test now asserts that the open response `_url` appears three times with the option off and never with it on. The byte-identical check against today's code was a one-off, done by the prototype, and is recorded under Verification.

### WCAG Accessibility Expert

#### RESOLVED: The long label couldn't wrap
Copying Hide names' `whitespace-nowrap` onto a 55-character label forces horizontal overflow on a narrow window. **Fix**: the new label drops the class. The accessible name was confirmed in the prototype's HTML: the `<input>` carries `id="remove_open_response_urls"` and the `<label for>` names it.

### Operator

#### RESOLVED: The rollback caveat had no home in the implementation
The requirements recorded that a rollback breaks loading runs saved after the deploy, but nothing in the plan told the person deploying. **Fix**: a Deploy note section says the PR description carries it.

### Verified without a finding

- **Each commit stands alone.** Steps 1 and 2 don't touch `report_filter_json/1`, so `@filter_keys` stays correct until the API step, which updates it in the same commit. The post-processing step depends only on the field from step 1. The API step's 400 test depends on the validation from step 2, which comes before it.
- **The tests can be written with existing harnesses.** Form tests use `ReportFormLiveTest`'s `mount_form_as/3` and `choose_first_filter/2`. API create tests use `ReportCreateTest`'s `:athena_run_starter` stub and the portal fixture. The `steps_for_run/1` tests need no DB. All of these ran in the prototype.

## Self-Review: second round

Reviewed as Product Manager, QA Engineer, Senior Engineer, Education Researcher and WCAG Accessibility Expert, across both files. Each finding was checked against the code on `7aa8bda`, and three were confirmed with throwaway tests run against a prototype of the plan, since reverted. Findings that didn't survive the check were dropped.

### Product Manager

#### RESOLVED: Most researchers won't see the checkbox "directly below Hide names"
The requirement places the checkbox on its own row directly below "Hide names". But `get_form_options/2` shows Hide names only to portal admins and project admins (`HideNames.allowed?/1`). A throwaway LiveView test mounting Student Answers as a project researcher confirmed that Hide names doesn't render for them and the new checkbox does. For them, it sits directly below the date row. Project researchers are the requester's audience, so the requirement as written describes a layout most of its users never see. The plan's markup is already right, so only the requirement's wording is wrong. **Suggested resolution**: reword it to say the checkbox follows Hide names when Hide names is shown, and otherwise sits directly below the date row.

**Decision**: Applied: the requirement now places it below Hide names when that is shown, and below the date row otherwise. The project researcher form test also checks that Hide names is absent.

### QA Engineer

#### RESOLVED: The form tests can't catch a misnamed checkbox field
The plan's "submitting stores true" test puts `"remove_open_response_urls" => "true"` into the params through `choose_first_filter/2`. `render_change/3` sends those params as they are, without checking them against the rendered form. The render test checks only `id="remove_open_response_urls"` and the label text. A throwaway mutation changed the template to `field={@form["remove_open_response_url"]}`. That makes a browser send a key `from_form/2` ignores, so the option silently does nothing. Both of the plan's tests stayed green. A test that sets the value through the rendered form failed on the mutation with "could not find non-disabled input ... with name \"filter_form[remove_open_response_urls]\"":

```elixir
view
|> form("form[phx-submit=submit_form]", filter_form: %{"remove_open_response_urls" => "true"})
|> render_change(%{"_target" => ["filter_form", "remove_open_response_urls"]})
```

**Suggested resolution**: write the submit test this way. Check "unchecked by default" against the element (`refute has_element?(view, "#remove_open_response_urls[checked]")`), not against the whole page's HTML.

**Decision**: Applied: the submit test sets the box through `form/3`, and the unchecked check targets the element.

#### RESOLVED: The `columns/2` test helper can't build a required question
The plan says the open response tests use "the existing `columns/2` helper, extended with an `opts` argument". But the helper hardcodes `required: false`, so the planned case "a required one emits `_text` then `_submitted`" can't be built through it as described. **Suggested resolution**: have the plan say the helper also takes the question's `required` flag, for example as a keyword next to the column options.

**Decision**: Applied: the helper takes a `required:` keyword alongside the column options.

### Senior Engineer

#### RESOLVED: "A hidden step can't be submitted" overstates what the submit handler does
The post-processing step says the submit handler resolves step ids against `@steps`, "so a hidden step can't be submitted either". In fact `Enum.find/2` returns `nil` for an id that isn't in `@steps`, and the `nil` is kept. A throwaway test called `handle_event("submit_form", %{"has_audio" => "true", "glossary_data" => "true"}, socket)` with the reduced step list, and it raised `KeyError` (`key :label not found in: nil`) in `sort_steps/1`. With the hidden id alone, `[nil]` reaches `JobServer.add_job/4`, whose `Enum.map(steps, &(&1.label))` raises in the GenServer. Only a crafted event can do this, today's code does the same for any unknown id, and no hidden step ever runs. So the plan's outcome holds, but its stated reason doesn't. **Suggested resolution**: reword the claim to "a hidden step can never run: a crafted submit naming one fails as any unknown step id does today". Leave the handler alone, since hardening it is unrelated to this story.

**Decision**: A, decided by Doug. The claim is reworded, and the handler is left unchanged, because the crash already exists for any unknown step id and this story doesn't make it easier to reach. The fix for both submit handlers is tracked separately as REPORT-161, a low-priority bug in the backlog.

#### RESOLVED: Prose and comments the change leaves stale or unclear
Reading the files the plan touches, and the ones that describe their contracts, turned up four:
- The `shared_queries_test.exs` moduledoc reads "Pins the answer-column shape the CLUE question types depend on." Once the open response cases land in that file, the header describes only part of it.
- The `FilterOptionsController` moduledoc lists the keys that `GET /api/v1/reports/:id` emits on every run and that narrow nothing (`start_date`, `end_date`, `hide_names`). `FilterParams.parse/1` will parse and type-check the new key on that endpoint too, so it belongs in that list.
- The comment above `choose_first_filter/2` in `report_form_live_test.exs` names "the date, hide-names and application controls" as the ones that render once a first filter has a value. The new checkbox is one of them.
- The planned comment above `@open_response_url_step_ids` ends "which this run left out". At module level there is no "this run", so the comment should say "which a run made with `remove_open_response_urls` leaves out".

**Suggested resolution**: add the three files to the steps that change their subject (the SQL step, the API step and the form step), and reword the planned comment.

**Decision**: Applied: the three files are listed in the steps that change their subject, and the planned comment is reworded.

### Education Researcher

No new findings. The cost of losing audio-only answers is stated as a requirement and accepted, and nothing in this round changes it.

### WCAG Accessibility Expert

No new findings. The core `<.input type="checkbox">` wraps the input in a label with no text of its own. The explicit `<label for>` supplies the accessible name, the same way Hide names gets its name.

### Verified without a finding

- **The SQL claims still hold on this commit.** With the plan's `shared_queries.ex` change applied, a required open response alongside an `iframe_interactive` question produced `res_1_<or>_url` 3 times with the option off and 0 times with it on. `_text` and `_submitted` stayed at 3 each, and the interactive `_url` stayed at 3. The existing `test/report_server/reports/athena` suite stayed green (41 tests).
- **Every harness the plan names exists as described**: `mount_form_as/3` and `choose_first_filter/2`, the `report_controller_test.exs` `@filter_keys` with its two exact-set assertions at lines 279 and 303, `reports_api_runs_test.exs`'s `record_starts/0`, `admin/0`, `athena_report/0` and `create/3`, `report_create_test.exs`'s `:athena_run_starter` stub, and the nil-filter test in `custom_components_test.exs`.
- **No run is reused based on its filter.** Learner uploads use fresh UUIDs (`LearnerData`), so a run with the option on can't be served an earlier run's output without it.
- **Duplicating stays within the report.** `duplicate_api_report_run/3` runs the copied filter through `create_api_report_run/3`, and so through `FilterValidation.validate/2`.
- **cc-data needs no change.** At `58c9172` it passes `report_filter` through as `json.RawMessage` and reads no `_url` column.
