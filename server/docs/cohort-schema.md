# Cohort Schema

This documents the various ways cohorts are joined with other tables. Cohorts are defined in the `admin_cohorts` table
and are joined with other tables using the polymorphic `admin_cohort_items` table.

Here is the simplified Rails schema for each table:

```
create_table "admin_cohort_items"
  t.integer "admin_cohort_id"
  t.integer "item_id"
  t.string "item_type"
end

create_table "admin_cohorts"
  t.integer "project_id"
  t.string "name"
  t.boolean "email_notifications_enabled", default: false
end
```

The production `admin_cohort_items` has the following distinct `item_type`s:

- `ExternalActivity`
- `Investigation`
- `Portal::Teacher`

There are seven `Investigation` items but they don't seem to exist anymore in the database.

