# Deployment

Two things are deployed: the **data** (static files) and the **app**.

## 1. Publish the data

The workflow `.github/workflows/publish-data.yml` runs every Sunday at 03:17 UTC
on GitHub's machines. It fetches the D-TRO data, rebuilds the tiles and publishes them
to GitHub Pages. It can also be run by hand from the Actions tab.

It is weekly while the app is unreleased. To make it daily, change the `cron` line to
`"17 3 * * *"`. Daily matters for temporary restrictions: on the data of 2 October
2026, about one in ten orders published ahead of time appeared less than a week
before they started.

The phone is not involved in this. The app downloads data only when it is opened,
only for the area on screen, and only tiles that changed since it last had them.

### One-time setup

1. **Put the repository on GitHub.**
2. **Add the credentials.** Repository → Settings → Secrets and variables → Actions →
   New repository secret. Add `DTRO_CLIENT_ID` and `DTRO_CLIENT_SECRET`.
3. **Enable Pages.** Repository → Settings → Pages → Source: **GitHub Actions**.
4. **Run it once.** Actions → "Publish parking data" → Run workflow, with "full
   import" ticked.
5. Note the Pages URL it prints, for example `https://<user>.github.io/<repo>/`.
   `https://<user>.github.io/<repo>/manifest.json` should open in a browser.

This project's data is published at <https://gourgey.github.io/Locis/>.

GitHub Pages is free for public repositories. For a private repository it needs a
paid plan; the alternatives are to make the repository public (it contains no
secrets), or to upload `pipeline/dist` to any static host (Cloudflare Pages,
Netlify, an S3-compatible bucket). The app only needs HTTPS and the folder layout.

### How the job keeps state

The pipeline's SQLite database (raw records and the sync checkpoint) is saved in the
Actions cache between runs, so most days only changes are fetched. If the cache has
expired the job runs a full import. A full import also runs every Sunday to
reconcile anything the event feed missed.

A failed update never publishes: the previous data stays live.

### Limits on the free plan

Checked against GitHub's documentation on 1 October 2026.

- **Public repository:** standard runners are free with no minute limit.
- **Private repository:** 2,000 minutes a month are included. The data job
  runs on Linux and should use a small fraction of that. The macOS job in
  `ci.yml` is billed at about ten times the Linux rate, so in a private repository
  remove it or run it only by hand.
- **If the allowance runs out** and no payment method is on file, jobs are blocked
  until the next month. Nothing is charged. The app keeps working on the last
  published data, which gets older until the job runs again.
- **Inactivity:** GitHub disables scheduled workflows in a public repository after
  60 days without repository activity. The job re-enables itself on every run to
  reset that timer; if it is ever disabled anyway, press "Enable workflow" on the
  Actions tab.
- **Measured:** the first full run (2 October 2026: download, import of 146,202
  records, tile build, deploy) took about two minutes.

### Running it yourself instead

```bash
pipeline/.venv/bin/locis publish
```

writes the same files to `pipeline/dist`.

## 2. Point the app at the data

In `ios/Config/Locis.xcconfig`:

```
LOCIS_DATA_BASE_URL = https:/$()/<user>.github.io/<repo>
```

The `/$()/` is needed because xcconfig files treat `//` as a comment. The URL must
be HTTPS. With it empty, the app uses the built-in demo data, which is for
development only. With it set, the app uses the published data and the demo
streets are never shown.

For a value you do not want to commit, put it in `ios/Config/Local.xcconfig`
(git-ignored).

## 3. App Store

Already in the project:

- Bundle id `studio.curateddesign.Locis`, team `5865Y52YG7`, automatic signing.
- iOS 18.0 minimum, iPhone only.
- Location usage description (when in use only).
- Privacy manifest (`ios/Locis/Resources/PrivacyInfo.xcprivacy`): no tracking, no
  data collected, required-reason entries for UserDefaults and file timestamps.
- `ITSAppUsesNonExemptEncryption = NO` (only HTTPS).
- About / Data Sources screen with the OGL attribution and the parking disclaimer.
- No third-party SDKs, no private APIs, no embedded secrets.

Still to do before submitting:

| Item | Where |
|---|---|
| Privacy policy URL | `LOCIS_PRIVACY_POLICY_URL` in the xcconfig, and App Store Connect |
| Live data URL | `LOCIS_DATA_BASE_URL`; do not ship a demo-only build |
| App Privacy answers | "Data Not Collected" matches the app as built |
| Category, screenshots, description | App Store Connect. The description should say the app gives guidance and does not show free spaces |
| Review notes | Say that coverage depends on which authorities have published to D-TRO |

To archive: in Xcode choose **Any iOS Device**, then Product → Archive, then
Distribute App → App Store Connect.

## Updating the rules engine safely

If a pipeline change publishes data that older app versions would misread:

1. Raise `engineVersion` in `ParkingRulesEngine.swift` and ship the app update.
2. Only once that version is out, raise `MIN_ENGINE_VERSION` in
   `pipeline/src/locis_pipeline/__init__.py`.

Apps older than that then show "Update the app to read the latest parking data" and
draw nothing, instead of showing colours they cannot justify.
