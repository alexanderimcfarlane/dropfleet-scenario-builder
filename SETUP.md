# Cloud library setup (Supabase, free plan)

The builder works without any of this: scenarios save in each person's browser. These steps add sign-in,
a cloud library, groups (clubs / events) and share links. Allow about 15 minutes.

Replace `YOURNAME` with your GitHub username and `dropfleet-scenario-builder` with your repo name throughout.

## 1. Create the Supabase project

1. Sign up at <https://supabase.com> (signing in with GitHub is fine) and click **New project**.
2. Pick a name (e.g. `dropfleet`), a strong database password (save it somewhere), and the region nearest you.
   The Free plan is selected by default.
3. When it's ready, open **SQL Editor → New query**, paste the whole of `supabase/schema.sql`, and click **Run**.
   It should finish with "Success. No rows returned". Running it again later is safe.

## 2. Email and password accounts

Email sign-up is switched on in new Supabase projects. In **Authentication → Sign In / Providers → Email**:

- **Minimum password length**: set it to `8`, to match the builder.
- **Confirm email**: choose one.
  - **Off (simplest)**: accounts work the moment they're created and no email is ever sent. Addresses aren't
    checked, and "Forgot password?" can't work, so you reset forgotten passwords yourself
    (you can set a temporary one for them, see *Moderation*).
  - **On**: people get a confirmation link, and you can turn on password resets. This needs your own email
    sender, because Supabase's built-in one only reaches your own team's addresses and a few per hour. A free
    [Resend](https://resend.com) account works: add its SMTP details under **Authentication → Emails → SMTP
    Settings**, then set `email: true` in step 4 so the builder shows "Forgot password?".

### Optional: sign in with GitHub, Discord or Google

1. In Supabase: **Authentication → Sign In / Providers → GitHub**. Copy the **Callback URL** shown there
   (it looks like `https://abcdefghijkl.supabase.co/auth/v1/callback`).
2. On GitHub: **Settings → Developer settings → OAuth Apps → New OAuth App**. Use
   `https://YOURNAME.github.io/dropfleet-scenario-builder/` as the Homepage URL and the Callback URL from step 1,
   then **Register application** and **Generate a new client secret**.
3. Back in Supabase, switch GitHub on, paste the **Client ID** and **Client secret**, and save.
4. Add `"github"` to `providers` in step 4. Discord and Google work the same way, through their own developer consoles.

## 3. Tell Supabase where the site lives

**Authentication → URL Configuration**
- Site URL: `https://YOURNAME.github.io/dropfleet-scenario-builder/`
- Redirect URLs: add `https://YOURNAME.github.io/dropfleet-scenario-builder/**`

## 4. Connect the builder

1. In Supabase: **Project Settings → API Keys**. Copy the **Project URL** and the **Publishable key**
   (starts `sb_publishable_`). Never use the *secret* key in the page.
2. In `index.html`, find `const CLOUD = {` and fill in:
   ```js
   url: "https://abcdefghijkl.supabase.co",
   key: "sb_publishable_…",
   ```
   The publishable key is meant to be public: the rules in `schema.sql` decide who can read or change what.
   Leave `password: true`. Set `email: true` only if you set up an email sender in step 2, and list any extra
   sign-in buttons in `providers`, e.g. `providers: ["github"]`.
3. Upload the new `index.html` to the GitHub repo. Open the site and you should see **Account & sharing**
   with **Sign in** and **Create account**.

## 5. Keep the free project awake (optional)

Free projects pause after about a week with no activity; you can resume them from the Supabase dashboard
with one click, and nothing is lost. To stop the pausing, add the file
`.github/workflows/keepalive.yml` to the repo (GitHub → **Add file → Create new file**, type that path):

```yaml
name: Keep Supabase awake
on:
  schedule: [{ cron: "17 6 */3 * *" }]   # every 3 days
  workflow_dispatch:
jobs:
  ping:
    runs-on: ubuntu-latest
    steps:
      - run: >
          curl -fsS "https://abcdefghijkl.supabase.co/rest/v1/scenarios?select=id&limit=1"
          -H "apikey: sb_publishable_…"
```

GitHub switches off scheduled workflows after 60 days without any commits to the repo; it emails you first,
and one click re-enables it.

## How sharing works

| | Who can see it | Who can change it |
|---|---|---|
| Only me | you | you |
| Group | members of that group | you, plus the group's owners and editors |
| Everyone | anyone, listed under **Public** | you |

- **Save** puts the scenario on the table into the cloud. Saving someone else's scenario that you can't edit makes your own copy.
- **Copy link** gives a `?s=…` link that opens the scenario directly.
- **Groups**: create one, then **Copy invite link** (`?join=…`). Owners choose whether newcomers can edit or only view,
  change roles, remove people, make a new invite link (the old one stops working), or delete the group
  (its scenarios are kept, private to whoever made them).
- Limits: 500 scenarios per person, 20 groups created per person, 200 members per group.

## Moderation

As the project owner you can fix anything in **Table Editor** or **SQL Editor**, e.g. to un-publish a scenario:

```sql
update scenarios set visibility = 'private' where id = '…';
```

- **Someone forgot their password** (with Confirm email off): give them a temporary one in the **SQL Editor**,
  then ask them to sign in and use **Change password**:
  ```sql
  update auth.users set encrypted_password = extensions.crypt('a-temporary-password', extensions.gen_salt('bf'))
  where email = 'their@email.com';
  ```
- **Stop new sign-ups**: switch off **Allow new users to sign up** under **Authentication → Sign In / Providers**.
- **Bots signing up**: turn on CAPTCHA under **Authentication → Attack Protection**. The builder would need a small
  addition to show the CAPTCHA, so ask for it if you need it.

Email addresses are only visible to you in the dashboard. Other people only ever see display names.
