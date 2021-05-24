# Running the export-answers script

This script finds all student answers in a Firetore report-service database, collects all the answers for a single
user's assignment into a single Parquet file, and uploads all the files to S3 for querying by the Athena database.

```
// build the shared library
cd functions
npm install
npm run build:shared

// build the scripts
cd scripts
npm install
```

Copy the `config.json.sample` file to `config.json` and fill in the AWS credentials for the S3 bucket. This should
be available in 1Password as one of the report-service AWS accounts.

Download the `credentials.json` file for the appropriate Firebase project from e.g.
https://console.cloud.google.com/apis/credentials?project=report-service-pro&organizationId=264971417743

Run the script by passing in the destination S3 bucket and the source key for the Firestore database. e.g.

```
node export-answers.js concordqa-report-data authoring.staging.concord.org
```

the script accepts up to three arguments:

```
export-answers.js [s3-bucket] [source-key] [created-timestamp-regex]
```

* s3-bucket: the name of the s3 bucket we're going to put the answers in
* source-key: the Firestore answers collection
* created-timestamp-regex: (optional) a regex as a string, e.g. `2021-*`

  if this is included we will gain a slight speed-up by not uploading answers whose `created` property does not match
  the regex. Note that this is conservative: if an answer does not have a `created` field it will be uploaded, and it
  only takes one answer in a user's session that matches the regex (or has `created` missing) to upload the entire
  learner-assignment collection.

## Running on Lightsail

In order to run the script on production, it is useful to run it on a Lightsail server, which should keep running for as long as needed, and may be slightly faster.

1. Log into AWS Lightsail
2. Select Linux/Unix and a Node.js blueprint
3. Select a price tier. For the entire DB dump we used one of the more expensive options ($40/mo, over 2 days =~ < $3), but for smaller dumps smaller tiers may be sufficient
4. Name the instance e.g. `export-answers-to-s3` and create it
5. Select the instance once it has booted up (~5 mins) and take note of the ssh username and ip
6. To connect to it, you need a valid private key, which you can download from https://lightsail.aws.amazon.com/ls/webapp/account/keys, and you could save in e.g. ~/.aws/LightsailDefaultKey-us-east-1.pem (and chmod 600)
7. ssh into the server with `ssh -i ~/.aws/LightsailDefaultKey-us-east-1.pem [username]@[ip]`
8. git clone the repo `git clone https://github.com/concord-consortium/report-service.git && cd report-service`
9. npm install and build the shared scripts
    ```
    cd functions
    npm install
    npm run build:shared
    cd ../scripts
    npm install
   ```
10. In a different terminal window, from the /scripts folder, scp the credentials and config files
    ```
    scp -i ~/.aws/LightsailDefaultKey-us-east-1.pem config.json [username]@[ip]:~/report-service/scripts
    scp -i ~/.aws/LightsailDefaultKey-us-east-1.pem credentials.json [username]@[ip]:~/report-service/scripts
    ```
11. Use `screen` to start a session that won't be terminated when you log out
    ```
    screen        # start a new screen session
    ctrl-a d      # exit the session (without terminating it)
    screen -ls    # view running screens
    screen -r [processname]   # return to a screen
    ```
12. Run the `node export-answers.js` as in the section above
