# reportservice
Report Service. Ingest student runs and activity structure in order to run
report queries later.


### One way to develop this:
This command should start up a firestore emulator, and compile typescript
in the background from the `src` directory.

`npm run serve`


### Some routes:
`importRun` -- used to ingest learner runs.
`importStructure` -- used to ingest activity structure.
