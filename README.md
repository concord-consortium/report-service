# Report Service
Ingest student runs and activity structure in order to run
report queries later.

### One way to develop this:
This command should start up a firestore emulator, and compile typescript
in the background from the `src` directory.

`npm run serve`

### Some routes:
- `api/` -- json based documentation of routes
- `api/import_run` -- used to ingest learner runs, requires bearer token
- `api/import_structure` -- used to ingest activity structure, requires bearer token

# Bearer Tokens

All api endpoints except for the root (`api/`) require a bearer token.
The code looks for the bearer token in the `bearer` query parameter first,
then the post body and finally falls back to the `Bearer` HTTP header.

The value of the bearer token is set with the `firebase` cli using the following
command:

`firebase functions:config:set auth.bearer_token=<VALUE>`

for local development the current Firebase environment config must be saved in
`.runtimeconfig.json`, a special file that the emulator looks for to set the
environment variables.  To create that file use:

`firebase functions:config:get > .runtimeconfig.json`

The `.runtimeconfig.json` file is present in the `.gitignore` so it won't be committed.
